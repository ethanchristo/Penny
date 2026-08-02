//
//  SimpleFINClient.swift
//  Penny
//
//  Talks to the SimpleFIN Bridge:
//  1. Claims a one-time Setup Token in exchange for a permanent Access URL.
//  2. Fetches accounts + transactions using HTTP Basic auth.
//  Also stores the Access URL in the Keychain (it contains credentials,
//  so it must never go in UserDefaults / @AppStorage).
//
//  Note: the wire-format types below are prefixed `SimpleFIN…` so they don't
//  collide with Penny's SwiftData `Account` / `Transaction` @Model classes.
//

import Foundation
import Security
import SwiftData

// MARK: - Models (SimpleFIN protocol)

struct SimpleFINAccountSet: Decodable {
    let errors: [String]
    let accounts: [SimpleFINAccount]

    enum CodingKeys: String, CodingKey { case errors, accounts }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
        accounts = try container.decodeIfPresent([SimpleFINAccount].self, forKey: .accounts) ?? []
    }
}

struct SimpleFINOrganization: Decodable {
    let name: String?
    let domain: String?
    let sfinURL: String?

    enum CodingKeys: String, CodingKey {
        case name, domain
        case sfinURL = "sfin-url"
    }
}

struct SimpleFINAccount: Decodable, Identifiable {
    let org: SimpleFINOrganization?
    let id: String
    let name: String
    let currency: String
    let balance: String          // SimpleFIN sends amounts as strings, e.g. "-1234.56"
    let availableBalance: String?
    let balanceDate: Date
    let transactions: [SimpleFINTransaction]

    enum CodingKeys: String, CodingKey {
        case org, id, name, currency, balance, transactions
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        org = try container.decodeIfPresent(SimpleFINOrganization.self, forKey: .org)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        currency = try container.decode(String.self, forKey: .currency)
        balance = try container.decode(String.self, forKey: .balance)
        availableBalance = try container.decodeIfPresent(String.self, forKey: .availableBalance)
        balanceDate = try container.decode(Date.self, forKey: .balanceDate)
        transactions = try container.decodeIfPresent([SimpleFINTransaction].self, forKey: .transactions) ?? []
    }

    /// Signed numeric balance for the net total: the bank's *available* balance
    /// (posted minus pending holds) when reported, falling back to the posted
    /// balance. e.g. "-1234.56" -> -1234.56.
    var balanceValue: Decimal { Decimal(string: availableBalance ?? balance) ?? 0 }

    /// "1234.56" + "USD" -> "$1,234.56". Falls back to the raw string for
    /// non-ISO currencies (SimpleFIN allows custom currencies as URLs).
    var balanceFormatted: String {
        guard currency.count == 3 else { return balance }
        return balanceValue.formatted(.currency(code: currency))
    }
}

struct SimpleFINTransaction: Decodable, Identifiable {
    let id: String
    let posted: Date
    let amount: String
    let description: String
    let payee: String?
    let memo: String?
    let pending: Bool?

    var amountDecimal: Decimal { Decimal(string: amount) ?? 0 }
}

// MARK: - Errors

enum SimpleFINError: LocalizedError {
    case invalidSetupToken
    case claimFailed(status: Int, message: String)
    case invalidAccessURL
    case requestFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidSetupToken:
            return "That doesn't look like a SimpleFIN Setup Token. Copy the whole token from the Bridge and paste it again."
        case .claimFailed(let status, let message):
            return "Couldn't exchange the Setup Token (HTTP \(status)). \(message) Setup Tokens are one-time use, so generate a fresh one if this one was already claimed."
        case .invalidAccessURL:
            return "The saved SimpleFIN connection is invalid. Disconnect, then connect again with a new Setup Token."
        case .requestFailed(let status):
            return "SimpleFIN request failed (HTTP \(status)). Try again in a bit — heavy polling can disable the connection."
        }
    }
}

// MARK: - Client

struct SimpleFINClient {

    /// Exchange a one-time Setup Token for a permanent Access URL.
    /// The Setup Token is a base64-encoded "claim" URL; POSTing to it once
    /// returns the Access URL. After this call the Setup Token is dead.
    static func claim(setupToken: String) async throws -> String {
        var token = setupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        while token.count % 4 != 0 { token += "=" }   // repair stripped base64 padding

        guard let decoded = Data(base64Encoded: token),
              let claimString = String(data: decoded, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              claimString.hasPrefix("https://"),
              let claimURL = URL(string: claimString)
        else { throw SimpleFINError.invalidSetupToken }

        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard status == 200, body.hasPrefix("http") else {
            throw SimpleFINError.claimFailed(status: status, message: body)
        }
        return body
    }

    /// Fetch all accounts (and transactions since `startDate`).
    /// Note the date range is capped at 90 days per request, and you're
    /// expected to call this at most ~once a day per the Bridge's limits.
    static func fetchAccounts(accessURL: String, startDate: Date? = nil) async throws -> SimpleFINAccountSet {
        // The Access URL embeds Basic Auth credentials (https://user:pass@host/...).
        // URLSession doesn't reliably send in-URL credentials, so pull them out
        // and send an explicit Authorization header instead.
        guard var components = URLComponents(string: accessURL),
              let user = components.user,
              let password = components.password
        else { throw SimpleFINError.invalidAccessURL }

        components.user = nil
        components.password = nil
        if components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/accounts"

        var queryItems = [URLQueryItem(name: "version", value: "2")]
        if let startDate {
            queryItems.append(URLQueryItem(name: "start-date",
                                           value: String(Int(startDate.timeIntervalSince1970))))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw SimpleFINError.invalidAccessURL }

        var request = URLRequest(url: url)
        let basic = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SimpleFINError.requestFailed(status: status) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SimpleFINAccountSet.self, from: data)
    }
}

// MARK: - Connection state (mapping + sync cutoff)

/// Lightweight, non-sensitive bookkeeping for the SimpleFIN connection — which
/// account is the user's checking, when setup finished, and which accounts they
/// chose not to sync. The Access URL itself (which carries credentials) stays in
/// the Keychain via `SimpleFINStore`. Kept in the shared App Group so it lives
/// alongside the database.
enum SimpleFINConfig {
    private static let defaults = UserDefaults.group

    private enum Key {
        static let checkingID = "simplefin_checking_id"
        static let connectedDate = "simplefin_connected_date"
        static let skippedIDs = "simplefin_skipped_ids"
        static let lastSyncDate = "simplefin_last_sync_date"
        static let skipRecurringDuplicates = "simplefin_skip_recurring_duplicates"
        static let accountCutoffs = "simplefin_account_cutoffs"
        static let dismissedIDs = "simplefin_dismissed_ids"
        static let accountBalances = "simplefin_account_balances"
    }

    /// External ids of imported transactions the user has deleted. The importer
    /// skips these on every sync so a deleted bank transaction doesn't reappear —
    /// without a tombstone, dedup (which only looks at transactions still in the
    /// database) would see it as brand-new and re-import it.
    static var dismissedExternalIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.dismissedIDs) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.dismissedIDs) }
    }

    /// Tombstone one external id so future syncs won't re-import it.
    static func dismissExternalID(_ id: String) {
        var ids = dismissedExternalIDs
        ids.insert(id)
        dismissedExternalIDs = ids
    }

    /// When on, a fetched transaction whose notes and amount exactly match an
    /// existing recurring transaction is skipped on import — the recurring entry
    /// already represents it, so it would otherwise double-count. Defaults to on.
    static var skipRecurringDuplicates: Bool {
        get {
            // `bool(forKey:)` returns false for an unset key, but this feature
            // should default to on, so treat "never set" as true.
            guard defaults.object(forKey: Key.skipRecurringDuplicates) != nil else { return true }
            return defaults.bool(forKey: Key.skipRecurringDuplicates)
        }
        set { defaults.set(newValue, forKey: Key.skipRecurringDuplicates) }
    }

    /// SimpleFIN account id the user designated as their primary checking.
    /// Its transactions import with `account == nil` (Penny's "main checking").
    static var checkingID: String? {
        get { defaults.string(forKey: Key.checkingID) }
        set { defaults.set(newValue, forKey: Key.checkingID) }
    }

    /// When the user finished setup. Future syncs only import transactions posted
    /// after this, so they never double-count the seeded opening balances.
    /// A non-nil value also means "setup is done" (skip the mapping wizard).
    static var connectedDate: Date? {
        get {
            let stamp = defaults.double(forKey: Key.connectedDate)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.connectedDate) }
    }

    /// SimpleFIN account ids the user explicitly chose not to sync.
    static var skippedIDs: [String] {
        get { defaults.stringArray(forKey: Key.skippedIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.skippedIDs) }
    }

    /// When the last sync (foreground or background) actually fetched from the
    /// Bridge. Used to throttle silent background syncs — SimpleFIN refreshes
    /// about once a day and heavy polling can disable the connection.
    static var lastSyncDate: Date? {
        get {
            let stamp = defaults.double(forKey: Key.lastSyncDate)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.lastSyncDate) }
    }

    /// Per-account import cutoffs, keyed by SimpleFIN account id. A fetched
    /// transaction imports only if it posted strictly after its account's
    /// cutoff. Seeded at setup from the most recent transaction visible at the
    /// time (not "now"), so transactions that were still pending then — and so
    /// weren't part of the seeded opening balance — still import once they post.
    static var accountCutoffs: [String: Date] {
        get {
            let raw = defaults.dictionary(forKey: Key.accountCutoffs) as? [String: Double] ?? [:]
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            defaults.set(newValue.mapValues { $0.timeIntervalSince1970 }, forKey: Key.accountCutoffs)
        }
    }

    static func cutoff(for accountID: String) -> Date? { accountCutoffs[accountID] }

    static func setCutoff(_ date: Date, for accountID: String) {
        var cutoffs = accountCutoffs
        cutoffs[accountID] = date
        accountCutoffs = cutoffs
    }

    /// Latest balance SimpleFIN reported for each account, keyed by SimpleFIN
    /// account id, stored as a positive magnitude (the account type decides asset
    /// vs. debt, matching `SimpleFINImporter.seedOpeningBalance`). Read by the net
    /// total so a card's live balance is the source of truth over replaying its
    /// transactions. Lives in the App Group so the app, widget, and Siri intent all
    /// resolve the same numbers.
    static var accountBalances: [String: Double] {
        get { defaults.dictionary(forKey: Key.accountBalances) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Key.accountBalances) }
    }

    /// Records each fetched account's reported balance so the net total can use the
    /// bank's live figure. Called on every sync from the feed's `SimpleFINAccount`s.
    static func recordBalances(from remoteAccounts: [SimpleFINAccount]) {
        var balances = accountBalances
        for remote in remoteAccounts {
            balances[remote.id] = abs((remote.balanceValue as NSDecimalNumber).doubleValue)
        }
        accountBalances = balances
    }

    static var isConfigured: Bool { connectedDate != nil }

    static func markSkipped(_ id: String) {
        var ids = skippedIDs
        guard !ids.contains(id) else { return }
        ids.append(id)
        skippedIDs = ids
    }

    static func reset() {
        defaults.removeObject(forKey: Key.checkingID)
        defaults.removeObject(forKey: Key.connectedDate)
        defaults.removeObject(forKey: Key.skippedIDs)
        defaults.removeObject(forKey: Key.lastSyncDate)
        defaults.removeObject(forKey: Key.accountCutoffs)
        defaults.removeObject(forKey: Key.dismissedIDs)
        defaults.removeObject(forKey: Key.accountBalances)
    }
}

// MARK: - Persistence (SimpleFIN -> SwiftData)

enum SimpleFINImporter {

    /// Outcome of an ongoing sync, surfaced to the user.
    struct Result {
        var imported = 0   // brand-new transactions written
        var skipped = 0    // transactions already saved (matched by externalID)
    }

    /// Stable externalID for an account's seeded opening-balance transaction,
    /// so re-running setup can't create a second one for the same account.
    private static func openingBalanceID(for accountID: String) -> String {
        "simplefin-opening-balance-\(accountID)"
    }

    /// The import cutoff to record for an account at setup time: the most recent
    /// *posted* transaction currently visible. Everything at or before this is
    /// already baked into the seeded opening balance, so only newer transactions
    /// — including ones pending right now that post later — should import. Capped
    /// at the balance date (and falling back to it when nothing is visible) so a
    /// stale balance can never hide a more recent posted transaction.
    static func importCutoff(for remote: SimpleFINAccount) -> Date {
        let mostRecentPosted = remote.transactions
            .filter { $0.pending != true }
            .map(\.posted)
            .max()
        guard let mostRecentPosted else { return remote.balanceDate }
        return min(mostRecentPosted, remote.balanceDate)
    }

    // MARK: First connection — seed opening balances

    /// Inserts a single "Opening balance" transaction for one mapped account so
    /// Penny's totals start from the real balance instead of replaying history.
    /// Checking/savings seed as income, credit as expense (the sign of the raw
    /// balance is ignored — the account type decides). `account` is nil for the
    /// primary checking. No-ops if a balance was already seeded for this account.
    @MainActor
    static func seedOpeningBalance(for remote: SimpleFINAccount,
                                   type: AccountType,
                                   account: Account?,
                                   into context: ModelContext) {
        let magnitude = abs((remote.balanceValue as NSDecimalNumber).doubleValue)
        guard magnitude > 0 else { return }

        let externalID: String? = openingBalanceID(for: remote.id)
        var descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.externalID == externalID })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor), !existing.isEmpty { return }

        let txn = Transaction(
            amount: magnitude,
            isIncome: type != .credit,
            date: remote.balanceDate,
            account: account,
            notes: "Opening balance",
            externalID: externalID
        )

        // File the opening balance under Miscellaneous, like the other importers.
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if let misc = categories.first(where: { $0.name == "Miscellaneous" }) {
            txn.category = misc
        }

        context.insert(txn)
    }

    // MARK: Ongoing syncs — import only new transactions

    /// Imports transactions posted after the connection date for accounts the
    /// user mapped during setup. The designated checking account maps to
    /// `account == nil`; mapped cards map to their matched account; skipped or
    /// unknown accounts are ignored. Dedup is by externalID, pending transactions
    /// are skipped, and categorisation mirrors the email importer (rules first,
    /// then the on-device foundation model, then Miscellaneous).
    @MainActor
    @discardableResult
    static func importNewTransactions(_ remoteAccounts: [SimpleFINAccount],
                                      into context: ModelContext) async -> Result {
        // Snapshot the bank's live balances so the net total can prefer them over
        // replaying transactions. Recorded even before setup completes below.
        SimpleFINConfig.recordBalances(from: remoteAccounts)

        guard let connectedDate = SimpleFINConfig.connectedDate else { return Result() }
        let checkingID = SimpleFINConfig.checkingID

        // Index existing accounts by their SimpleFIN id for O(1) lookup.
        let localAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var accountsByExternalID: [String: Account] = [:]
        for account in localAccounts {
            if let externalID = account.externalID { accountsByExternalID[externalID] = account }
        }

        let allTransactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let existingTxnIDs = Set(allTransactions.compactMap(\.externalID))

        // External ids the user deleted. Skipped on import so a transaction the
        // user removed doesn't come back the next time the feed still includes it.
        let dismissedTxnIDs = SimpleFINConfig.dismissedExternalIDs

        // Signatures (notes + amount) of existing recurring transactions, used to
        // skip importing a fetched transaction the user already tracks as recurring.
        // Empty when the feature is disabled, so the contains-check below is a no-op.
        let recurringSignatures: Set<String> = SimpleFINConfig.skipRecurringDuplicates
            ? Set(allTransactions
                .filter { $0.recurrence != .none }
                .map { recurringSignature(notes: $0.notes, amount: $0.amount) })
            : []

        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let categoryNames = categories.map(\.name)
        let misc = categories.first { $0.name == "Miscellaneous" }

        var result = Result()

        for remote in remoteAccounts {
            let isChecking = (remote.id == checkingID)
            let matched = accountsByExternalID[remote.id]
            // Only sync the checking account or accounts the user mapped to a card.
            guard isChecking || matched != nil else { continue }
            let target = matched   // nil for the primary checking

            // Per-account cutoff: transactions at or before it are already in the
            // seeded opening balance. Falls back to the global connection date for
            // accounts linked before per-account cutoffs were recorded.
            let cutoff = SimpleFINConfig.cutoff(for: remote.id) ?? connectedDate

            for txn in remote.transactions {
                if txn.pending == true { continue }
                if txn.posted <= cutoff { continue }
                guard !existingTxnIDs.contains(txn.id),
                      !dismissedTxnIDs.contains(txn.id) else {
                    result.skipped += 1
                    continue
                }

                // SimpleFIN amounts are signed: negative = money out, positive = money in.
                // Penny stores a positive magnitude plus an `isIncome` flag.
                let value = txn.amountDecimal
                let magnitude = abs((value as NSDecimalNumber).doubleValue)
                let notes = txn.description.isEmpty ? (txn.payee ?? "") : txn.description

                // Don't import what the user already tracks as a recurring
                // transaction with the same notes and amount.
                if recurringSignatures.contains(recurringSignature(notes: notes, amount: magnitude)) {
                    result.skipped += 1
                    continue
                }

                let newTransaction = Transaction(
                    amount: magnitude,
                    isIncome: value >= 0,
                    date: txn.posted,
                    account: target,
                    notes: notes,
                    externalID: txn.id
                )
                newTransaction.category = await category(forNotes: notes,
                                                         accountName: remote.name,
                                                         amount: magnitude,
                                                         categories: categories,
                                                         categoryNames: categoryNames,
                                                         fallback: misc)

                context.insert(newTransaction)
                result.imported += 1
            }
        }

        try? context.save()
        return result
    }

    /// Accounts present in the feed that Penny isn't tracking yet: not the
    /// designated checking, not mapped to a local account (by `externalID`), and
    /// not explicitly skipped. These are typically cards the user added on the
    /// SimpleFIN portal after first setup, surfaced so they can be mapped without
    /// disconnecting and reconnecting from scratch.
    @MainActor
    static func unmappedAccounts(_ remoteAccounts: [SimpleFINAccount],
                                 in context: ModelContext) -> [SimpleFINAccount] {
        let checkingID = SimpleFINConfig.checkingID
        let skipped = Set(SimpleFINConfig.skippedIDs)
        let localAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let mappedIDs = Set(localAccounts.compactMap(\.externalID))

        return remoteAccounts.filter { account in
            account.id != checkingID
                && !mappedIDs.contains(account.id)
                && !skipped.contains(account.id)
        }
    }

    /// A notes+amount fingerprint used to match a fetched transaction against an
    /// existing recurring one. Amount is rounded to cents so floating-point noise
    /// doesn't break otherwise-identical matches.
    private static func recurringSignature(notes: String, amount: Double) -> String {
        "\(notes)|\(String(format: "%.2f", amount))"
    }

    // MARK: Shared categorisation

    /// Hybrid categorisation mirroring the email importer: the user's category
    /// rules win first, then the on-device Apple foundation model, and finally
    /// Miscellaneous as a last resort.
    @MainActor
    private static func category(forNotes notes: String,
                                 accountName: String,
                                 amount: Double,
                                 categories: [Category],
                                 categoryNames: [String],
                                 fallback: Category?) async -> Category? {
        let dto = TransactionDTO(name: notes, amount: amount, date: "", account: accountName)
        if let ruled = findCategoryByRule(for: dto, categories: categories) { return ruled }
        if let predicted = await autoCategorize(text: notes, categories: categoryNames),
           let matched = categories.first(where: { $0.name == predicted }) {
            return matched
        }
        return fallback
    }
}

// MARK: - Keychain storage for the Access URL

enum SimpleFINStore {
    private static let service = "com.penny.simplefin"
    private static let account = "access-url"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func saveAccessURL(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func loadAccessURL() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAccessURL() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
