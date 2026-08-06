//
//  FinanceKitImporter.swift
//  Penny
//
//  Non-sensitive bookkeeping + persistence for the FinanceKit connection.
//  Deliberately does NOT import FinanceKit — it works only on the neutral
//  `FinanceKit…Snapshot` value types (from FinanceKitClient.swift) and Penny's
//  SwiftData models, so this compiles cleanly in both the app and the
//  PennyFinanceMonitor extension without the two `Account`/`Transaction` type
//  families colliding.
//
//  Mirrors SimpleFINConfig / SimpleFINImporter so both bank-sync sources behave
//  the same. FinanceKit balances live under their own `financekit_*` keys and are
//  merged with SimpleFIN's in `netTotalAggregate`.
//

import Foundation
import SwiftData

// MARK: - Connection state (mapping + sync cutoff)

/// Lightweight, non-sensitive bookkeeping for the FinanceKit connection, stored in
/// the shared App Group alongside the database. Keys are namespaced `financekit_*`
/// so they never collide with `SimpleFINConfig`.
enum FinanceKitConfig {
    // Opens the App Group suite directly (the same suite as `UserDefaults.group`)
    // rather than via the app's `UserDefaults.group` helper, so this file compiles
    // in the PennyFinanceMonitor extension without dragging in SharedDatabase and,
    // through it, the whole net-total helper chain. The id mirrors
    // `SharedDatabase.appGroup`.
    private static let defaults = UserDefaults(suiteName: "group.com.ethanchristo.Penny") ?? .standard

    private enum Key {
        static let checkingID = "financekit_checking_id"
        static let connectedDate = "financekit_connected_date"
        static let skippedIDs = "financekit_skipped_ids"
        static let lastSyncDate = "financekit_last_sync_date"
        static let skipRecurringDuplicates = "financekit_skip_recurring_duplicates"
        static let accountCutoffs = "financekit_account_cutoffs"
        static let dismissedIDs = "financekit_dismissed_ids"
        static let accountBalances = "financekit_account_balances"
    }

    /// External ids of imported transactions the user has deleted, so future syncs
    /// don't re-import them (dedup only sees transactions still in the database).
    static var dismissedExternalIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.dismissedIDs) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.dismissedIDs) }
    }

    static func dismissExternalID(_ id: String) {
        var ids = dismissedExternalIDs
        ids.insert(id)
        dismissedExternalIDs = ids
    }

    /// When on, a fetched transaction whose notes and amount exactly match an
    /// existing recurring transaction is skipped so it isn't double-counted.
    static var skipRecurringDuplicates: Bool {
        get {
            guard defaults.object(forKey: Key.skipRecurringDuplicates) != nil else { return true }
            return defaults.bool(forKey: Key.skipRecurringDuplicates)
        }
        set { defaults.set(newValue, forKey: Key.skipRecurringDuplicates) }
    }

    /// FinanceKit account id the user designated as their primary checking.
    /// Its transactions import with `account == nil` (Penny's "main checking").
    static var checkingID: String? {
        get { defaults.string(forKey: Key.checkingID) }
        set { defaults.set(newValue, forKey: Key.checkingID) }
    }

    /// When the user finished setup. Also means "setup is done" (skip the wizard).
    static var connectedDate: Date? {
        get {
            let stamp = defaults.double(forKey: Key.connectedDate)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.connectedDate) }
    }

    /// FinanceKit account ids the user explicitly chose not to sync.
    static var skippedIDs: [String] {
        get { defaults.stringArray(forKey: Key.skippedIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.skippedIDs) }
    }

    static var lastSyncDate: Date? {
        get {
            let stamp = defaults.double(forKey: Key.lastSyncDate)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.lastSyncDate) }
    }

    /// Per-account import cutoffs, keyed by FinanceKit external id. A fetched
    /// transaction imports only if it posted strictly after its account's cutoff.
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

    /// Latest balance FinanceKit reported for each account, stored as a positive
    /// magnitude keyed by the namespaced external id. Read by `netTotalAggregate`
    /// (merged with SimpleFIN's) so a card's live balance is the source of truth.
    static var accountBalances: [String: Double] {
        get { defaults.dictionary(forKey: Key.accountBalances) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Key.accountBalances) }
    }

    /// Records each fetched account's reported balance. Called on every sync.
    static func recordBalances(from remoteAccounts: [FinanceKitAccountSnapshot]) {
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

// MARK: - Persistence (FinanceKit -> SwiftData)

enum FinanceKitImporter {

    /// Categorises an imported transaction from its notes. The app passes a hybrid
    /// path (rules → on-device model → fallback); the memory-limited background
    /// extension passes `rulesOnlyCategorize` (rules → fallback).
    typealias Categorizer = (_ notes: String, _ categories: [Category], _ fallback: Category?) async -> Category?

    struct Result {
        var imported = 0
        var skipped = 0
    }

    /// Stable externalID for an account's seeded opening-balance transaction. The
    /// `financekit-opening-balance-` prefix mirrors SimpleFIN's and is excluded from
    /// the credit-card statement window in `creditCardOwed`.
    static func openingBalanceID(for rawID: UUID) -> String {
        "financekit-opening-balance-\(rawID.uuidString)"
    }

    /// The import cutoff to record at setup: the most recent posted transaction
    /// currently visible, capped at the balance date. Everything at or before it is
    /// already baked into the seeded opening balance.
    static func importCutoff(for remote: FinanceKitAccountSnapshot) -> Date {
        let mostRecentPosted = remote.transactions
            .filter { !$0.pending }
            .map(\.posted)
            .max()
        guard let mostRecentPosted else { return remote.balanceDate }
        return min(mostRecentPosted, remote.balanceDate)
    }

    // MARK: First connection — seed opening balances

    /// Inserts a single "Opening balance" transaction so Penny's totals start from
    /// the real balance instead of replaying history. Checking/savings seed as
    /// income, credit as expense (the account type decides, not the raw sign).
    /// `account` is nil for the primary checking. No-ops if already seeded.
    @MainActor
    static func seedOpeningBalance(for remote: FinanceKitAccountSnapshot,
                                   type: AccountType,
                                   account: Account?,
                                   into context: ModelContext) {
        let magnitude = abs((remote.balanceValue as NSDecimalNumber).doubleValue)
        guard magnitude > 0 else { return }

        let externalID: String? = openingBalanceID(for: remote.rawID)
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

        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if let misc = categories.first(where: { $0.name == "Miscellaneous" }) {
            txn.category = misc
        }

        context.insert(txn)
    }

    // MARK: Ongoing syncs — import only new transactions

    /// Imports transactions posted after each mapped account's cutoff. The
    /// designated checking maps to `account == nil`; mapped cards map to their
    /// matched account; skipped/unknown accounts are ignored. Dedup by externalID,
    /// pending transactions skipped, categorisation via the injected `categorize`.
    @MainActor
    @discardableResult
    static func importNewTransactions(_ remoteAccounts: [FinanceKitAccountSnapshot],
                                      into context: ModelContext,
                                      categorize: Categorizer) async -> Result {
        FinanceKitConfig.recordBalances(from: remoteAccounts)

        guard let connectedDate = FinanceKitConfig.connectedDate else { return Result() }
        let checkingID = FinanceKitConfig.checkingID

        let localAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var accountsByExternalID: [String: Account] = [:]
        for account in localAccounts {
            if let externalID = account.externalID { accountsByExternalID[externalID] = account }
        }

        let allTransactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let existingTxnIDs = Set(allTransactions.compactMap(\.externalID))
        let dismissedTxnIDs = FinanceKitConfig.dismissedExternalIDs

        let recurringSignatures: Set<String> = FinanceKitConfig.skipRecurringDuplicates
            ? Set(allTransactions
                .filter { $0.recurrence != .none }
                .map { recurringSignature(notes: $0.notes, amount: $0.amount) })
            : []

        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let misc = categories.first { $0.name == "Miscellaneous" }

        var result = Result()

        for remote in remoteAccounts {
            let isChecking = (remote.id == checkingID)
            let matched = accountsByExternalID[remote.id]
            guard isChecking || matched != nil else { continue }
            let target = matched   // nil for the primary checking

            let cutoff = FinanceKitConfig.cutoff(for: remote.id) ?? connectedDate

            for txn in remote.transactions {
                if txn.pending { continue }
                if txn.posted <= cutoff { continue }
                guard !existingTxnIDs.contains(txn.id),
                      !dismissedTxnIDs.contains(txn.id) else {
                    result.skipped += 1
                    continue
                }

                let value = txn.amount
                let magnitude = abs((value as NSDecimalNumber).doubleValue)
                let notes = txn.description

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
                newTransaction.category = await categorize(notes, categories, misc)

                context.insert(newTransaction)
                result.imported += 1
            }
        }

        try? context.save()
        return result
    }

    /// Accounts in the feed that Penny isn't tracking yet: not the designated
    /// checking, not mapped (by `externalID`), and not skipped.
    @MainActor
    static func unmappedAccounts(_ remoteAccounts: [FinanceKitAccountSnapshot],
                                 in context: ModelContext) -> [FinanceKitAccountSnapshot] {
        let checkingID = FinanceKitConfig.checkingID
        let skipped = Set(FinanceKitConfig.skippedIDs)
        let localAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let mappedIDs = Set(localAccounts.compactMap(\.externalID))

        return remoteAccounts.filter { account in
            account.id != checkingID
                && !mappedIDs.contains(account.id)
                && !skipped.contains(account.id)
        }
    }

    // MARK: Categorisation

    /// Rules-only categoriser (used by the background extension): the user's
    /// category rules win, otherwise the fallback. Self-contained so the extension
    /// doesn't need to compile the app's FoundationModels helpers.
    @MainActor
    static func rulesOnlyCategorize(_ notes: String,
                                    categories: [Category],
                                    fallback: Category?) async -> Category? {
        ruleCategory(notes: notes, categories: categories) ?? fallback
    }

    /// The first category whose rules contain a keyword found in `notes`.
    @MainActor
    static func ruleCategory(notes: String, categories: [Category]) -> Category? {
        for category in categories {
            guard let rules = category.rules else { continue }
            for rule in rules {
                if let keyword = rule.inputNotes, !keyword.isEmpty,
                   notes.localizedCaseInsensitiveContains(keyword) {
                    return category
                }
            }
        }
        return nil
    }

    /// A notes+amount fingerprint matching a fetched transaction against a
    /// recurring one. Amount rounded to cents so float noise doesn't break matches.
    private static func recurringSignature(notes: String, amount: Double) -> String {
        "\(notes)|\(String(format: "%.2f", amount))"
    }
}
