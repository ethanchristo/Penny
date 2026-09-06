//
//  FinanceKitClient.swift
//  Penny
//
//  Talks to Apple's FinanceKit (the on-device Wallet finance store):
//  1. Requests authorization to read financial data.
//  2. Fetches accounts, live balances, and transactions.
//  3. Enables background delivery so the PennyFinanceMonitor extension is woken
//     when Wallet data changes.
//
//  This is the only file that imports FinanceKit. Because FinanceKit exposes its
//  own `Account`/`Transaction` types that collide with Penny's SwiftData models,
//  everything here is expressed in terms of neutral `FinanceKit…Snapshot` value
//  types (below). The importer/config in FinanceKitImporter.swift then works
//  purely on those snapshots and Penny's models, never importing FinanceKit — so
//  the two type families never clash. Both files are shared with the extension.
//

import FinanceKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.opal.Penny", category: "financeKit")

// MARK: - Snapshots (the bridge between FinanceKit and Penny)

/// A neutral, `Sendable` copy of a FinanceKit account plus its live balance and
/// the transactions fetched for it. Mirrors the role `SimpleFINAccount` plays for
/// the SimpleFIN path.
struct FinanceKitAccountSnapshot: Identifiable, Sendable {
    /// FinanceKit's raw account UUID.
    let rawID: UUID
    let displayName: String
    let institutionName: String?
    let currencyCode: String
    /// Signed balance: positive for assets, negative for owed liabilities
    /// (derived from FinanceKit's credit/debit indicator), matching the sign
    /// convention `SimpleFINAccount.balanceValue` uses.
    let balanceValue: Decimal
    let balanceDate: Date
    let isLiability: Bool
    var transactions: [FinanceKitTransactionSnapshot]

    /// Namespaced external id stored on Penny's `Account.externalID` and used as
    /// the key in the balances dictionary. The `financekit-` prefix keeps it from
    /// ever colliding with a SimpleFIN account id.
    var id: String { "financekit-\(rawID.uuidString)" }

    /// "1234.56" + "USD" -> "$1,234.56". Falls back to the raw amount for
    /// non-ISO currency codes.
    var balanceFormatted: String {
        guard currencyCode.count == 3 else { return "\(balanceValue)" }
        return balanceValue.formatted(.currency(code: currencyCode))
    }
}

/// A neutral, `Sendable` copy of a FinanceKit transaction. Mirrors `SimpleFINTransaction`.
struct FinanceKitTransactionSnapshot: Identifiable, Sendable {
    let rawID: UUID
    let posted: Date
    /// Signed amount: positive = money in, negative = money out.
    let amount: Decimal
    let description: String
    let pending: Bool

    /// Namespaced external id used for dedup on Penny's `Transaction.externalID`.
    var id: String { "financekit-\(rawID.uuidString)" }
}

/// Plain authorization result so views never need to import FinanceKit.
enum FinanceKitAuthState: Sendable {
    case authorized
    case denied
    case notDetermined
}

// MARK: - Client

/// Thin async wrapper over `FinanceStore`. No credentials or Keychain — FinanceKit
/// authorization is managed by the system.
struct FinanceKitClient {

    static func authorizationState() async -> FinanceKitAuthState {
        guard let status = try? await FinanceStore.shared.authorizationStatus() else { return .denied }
        return map(status)
    }

    /// Prompts for access if needed (safe to call repeatedly).
    static func requestAuthorization() async -> FinanceKitAuthState {
        guard let status = try? await FinanceStore.shared.requestAuthorization() else { return .denied }
        return map(status)
    }

    private static func map(_ status: FinanceKit.AuthorizationStatus) -> FinanceKitAuthState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Fetches every account with its live balance and the transactions posted
    /// after `since` (nil ⇒ a 90-day lookback used for first-connection mapping).
    static func fetchAccounts(since: Date? = nil) async throws -> [FinanceKitAccountSnapshot] {
        let store = FinanceStore.shared
        let cutoff = since ?? Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast

        let accounts = try await store.accounts(query: FinanceKit.AccountQuery(sortDescriptors: []))
        let balances = try await store.accountBalances(query: FinanceKit.AccountBalanceQuery(sortDescriptors: []))

        var balanceByAccount: [UUID: FinanceKit.AccountBalance] = [:]
        for balance in balances { balanceByAccount[balance.accountID] = balance }

        var snapshots: [FinanceKitAccountSnapshot] = []
        for account in accounts {
            let isLiability = account.liabilityAccount != nil
            let creditLimit = account.liabilityAccount?.creditInformation.creditLimit?.amount
            let rawBalance = balanceByAccount[account.id]
            let (value, date) = signedBalance(rawBalance, isLiability: isLiability, creditLimit: creditLimit)
            logBalanceDecoding(displayName: account.displayName, isLiability: isLiability,
                               creditLimit: creditLimit, rawBalance: rawBalance, decoded: value)
            let transactions = try await fetchTransactions(forAccountID: account.id, since: cutoff)
            snapshots.append(
                FinanceKitAccountSnapshot(
                    rawID: account.id,
                    displayName: account.displayName,
                    institutionName: account.institutionName,
                    currencyCode: account.currencyCode,
                    balanceValue: value,
                    balanceDate: date,
                    isLiability: isLiability,
                    transactions: transactions
                )
            )
        }
        return snapshots
    }

    private static func fetchTransactions(forAccountID accountID: UUID,
                                          since cutoff: Date) async throws -> [FinanceKitTransactionSnapshot] {
        let predicate = #Predicate<FinanceKit.Transaction> { $0.accountID == accountID }
        let query = FinanceKit.TransactionQuery(
            sortDescriptors: [SortDescriptor(\.transactionDate, order: .reverse)],
            predicate: predicate
        )
        let transactions = try await FinanceStore.shared.transactions(query: query)

        return transactions.compactMap { txn -> FinanceKitTransactionSnapshot? in
            let posted = txn.postedDate ?? txn.transactionDate
            guard posted > cutoff else { return nil }

            // FinanceKit reports a positive magnitude plus a credit/debit indicator:
            // credit = money in (asset increase), debit = money out.
            let magnitude = txn.transactionAmount.amount
            let signed = txn.creditDebitIndicator == .credit ? magnitude : -magnitude
            let name = txn.merchantName ?? txn.transactionDescription

            return FinanceKitTransactionSnapshot(
                rawID: txn.id,
                posted: posted,
                amount: signed,
                description: name,
                pending: txn.status == .pending
            )
        }
    }

    /// Decodes an `AccountBalance` into a signed amount (asset positive, owed
    /// liability negative) and its as-of date.
    ///
    /// For assets (checking/savings) the available balance — posted minus pending
    /// holds — is the most useful spendable figure, so it's preferred. For liabilities
    /// (credit cards) the "available" balance can be available *credit* (limit − owed)
    /// on some cards rather than the amount owed; using it raw would make a card look
    /// like a large asset. So liabilities prefer the booked balance, which is
    /// unambiguously the outstanding balance, whenever it's present.
    ///
    /// Some Wallet-linked cards (Apple Card among them) only ever report the single
    /// `.available` case — never `.booked` or `.availableAndBooked` — so the
    /// liability/booked preference above never gets a chance to apply. For that case,
    /// recover the amount owed from the card's credit limit (owed = limit − available
    /// credit) when the limit is known and sane; otherwise trust the balance's own
    /// `creditDebitIndicator` directly rather than reporting no balance at all — Apple's
    /// documented rule is that a liability's indicator is `.debit` when it has a spent
    /// (owed) balance and `.credit` when it's paid off/in-credit, which applies
    /// regardless of whether the number itself is "available" or "booked".
    private static func signedBalance(_ balance: FinanceKit.AccountBalance?,
                                      isLiability: Bool,
                                      creditLimit: Decimal?) -> (Decimal, Date) {
        guard let balance else { return (0, .now) }
        switch balance.currentBalance {
        case .available(let b):
            return (liabilityAwareMagnitude(b, isLiability: isLiability, creditLimit: creditLimit), b.asOfDate)
        case .booked(let b):
            return (signedMagnitude(b), b.asOfDate)
        case .availableAndBooked(let available, let booked):
            let picked = isLiability ? booked : available
            return (signedMagnitude(picked), picked.asOfDate)
        @unknown default:
            return (0, .now)
        }
    }

    /// A `Balance`'s amount, signed by its credit/debit indicator (credit positive,
    /// debit negative). Only meaningful for a balance actually being reported as this
    /// account's real balance (not for a liability's "available credit" figure, whose
    /// magnitude means something different — see `liabilityAwareMagnitude`).
    private static func signedMagnitude(_ b: FinanceKit.Balance) -> Decimal {
        b.creditDebitIndicator == .credit ? b.amount.amount : -b.amount.amount
    }

    /// `signedMagnitude`, but for a liability's "available" figure, which some cards
    /// report as available credit rather than the amount owed. Prefers deriving owed
    /// from the credit limit when it's known and the numbers are plausible (limit
    /// positive and at least as large as the reported figure); falls back to trusting
    /// the indicator directly otherwise, so a missing/odd credit limit never silently
    /// produces a $0 balance.
    private static func liabilityAwareMagnitude(_ b: FinanceKit.Balance, isLiability: Bool, creditLimit: Decimal?) -> Decimal {
        guard isLiability else { return signedMagnitude(b) }
        if let creditLimit, creditLimit > 0, b.amount.amount <= creditLimit {
            return b.amount.amount - creditLimit
        }
        return signedMagnitude(b)
    }

    /// Logs the raw FinanceKit balance alongside Penny's decoded figure for every
    /// account on each sync, so a wrong balance can be diagnosed from Console (filter
    /// by subsystem "com.opal.Penny", category "financeKit") without guesswork about
    /// which `CurrentBalance` case or credit/debit indicator Wallet actually reported.
    private static func logBalanceDecoding(displayName: String, isLiability: Bool, creditLimit: Decimal?,
                                           rawBalance: FinanceKit.AccountBalance?, decoded: Decimal) {
        guard let rawBalance else {
            log.info("FinanceKit balance for \(displayName, privacy: .public): no AccountBalance record at all")
            return
        }
        let caseDescription: String
        switch rawBalance.currentBalance {
        case .available(let b):
            caseDescription = "available(amount: \(b.amount.amount), indicator: \(String(describing: b.creditDebitIndicator)))"
        case .booked(let b):
            caseDescription = "booked(amount: \(b.amount.amount), indicator: \(String(describing: b.creditDebitIndicator)))"
        case .availableAndBooked(let available, let booked):
            caseDescription = "availableAndBooked(available: \(available.amount.amount)/\(String(describing: available.creditDebitIndicator)), booked: \(booked.amount.amount)/\(String(describing: booked.creditDebitIndicator)))"
        @unknown default:
            caseDescription = "unknown"
        }
        log.info("""
            FinanceKit balance for \(displayName, privacy: .public): isLiability=\(isLiability), \
            creditLimit=\(creditLimit.map(String.init(describing:)) ?? "nil", privacy: .public), \
            currentBalance=\(caseDescription, privacy: .public) -> decoded=\(String(describing: decoded), privacy: .public)
            """)
    }
}
