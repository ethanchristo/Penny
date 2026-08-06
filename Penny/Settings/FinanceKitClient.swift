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
            let (value, date) = signedBalance(balanceByAccount[account.id])
            let transactions = try await fetchTransactions(forAccountID: account.id, since: cutoff)
            snapshots.append(
                FinanceKitAccountSnapshot(
                    rawID: account.id,
                    displayName: account.displayName,
                    institutionName: account.institutionName,
                    currencyCode: account.currencyCode,
                    balanceValue: value,
                    balanceDate: date,
                    isLiability: account.liabilityAccount != nil,
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
    /// liability negative) and its as-of date. Prefers the available balance,
    /// falling back to the booked balance.
    private static func signedBalance(_ balance: FinanceKit.AccountBalance?) -> (Decimal, Date) {
        guard let balance else { return (0, .now) }
        let picked: FinanceKit.Balance
        switch balance.currentBalance {
        case .available(let b): picked = b
        case .booked(let b): picked = b
        case .availableAndBooked(let available, _): picked = available
        @unknown default: return (0, .now)
        }
        let magnitude = picked.amount.amount
        let signed = picked.creditDebitIndicator == .credit ? magnitude : -magnitude
        return (signed, picked.asOfDate)
    }
}
