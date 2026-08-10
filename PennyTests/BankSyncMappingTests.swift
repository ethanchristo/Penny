//
//  BankSyncMappingTests.swift
//  PennyTests
//
//  Verifies that reassigning a bank-synced account (a card or the primary
//  checking) is fully reversible: a feed's id designation and its bank-imported
//  transactions always travel together, so remapping then reverting restores the
//  exact prior state. Regression coverage for the "remap default checking then
//  revert breaks the net total" bug.
//
//  These tests mutate the shared App Group defaults that SimpleFINConfig /
//  FinanceKitConfig read, so each runs against a clean snapshot and restores the
//  real values afterward (via `withCleanConfig`). The suite is serialized because
//  that global state is shared.
//

import Foundation
import SwiftData
import Testing
@testable import Penny

@MainActor
@Suite(.serialized)
struct BankSyncMappingTests {

    /// Every key the two bank-sync configs manage in the App Group suite.
    private static let groupKeys = [
        "simplefin_checking_id", "simplefin_connected_date", "simplefin_skipped_ids",
        "simplefin_last_sync_date", "simplefin_skip_recurring_duplicates",
        "simplefin_account_cutoffs", "simplefin_dismissed_ids",
        "simplefin_account_balances", "simplefin_account_names",
        "default_checking_use_available_balance",
        "financekit_checking_id", "financekit_connected_date", "financekit_skipped_ids",
        "financekit_last_sync_date", "financekit_skip_recurring_duplicates",
        "financekit_account_cutoffs", "financekit_dismissed_ids",
        "financekit_account_balances", "financekit_account_names"
    ]

    /// Snapshots the App Group config, clears it, hands the body a fresh in-memory
    /// store, then restores the real config no matter what.
    private func withCleanConfig(_ body: (ModelContext) -> Void) {
        let defaults = UserDefaults(suiteName: "group.com.ethanchristo.Penny")!
        var backup: [String: Any] = [:]
        for key in Self.groupKeys where defaults.object(forKey: key) != nil {
            backup[key] = defaults.object(forKey: key)
        }
        for key in Self.groupKeys { defaults.removeObject(forKey: key) }
        defer {
            for key in Self.groupKeys {
                if let value = backup[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        // An on-disk temp store with no CloudKit. An in-memory store fails with
        // "No eligible connection available" here, because the host app stands up a
        // CloudKit-backed SwiftData stack and the two interact badly in-process.
        let storeURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let container = try! ModelContainer(
            for: Account.self, Transaction.self,
            configurations: ModelConfiguration(url: storeURL))
        body(container.mainContext)
    }

    private func accounts(_ context: ModelContext) -> [Account] {
        (try? context.fetch(FetchDescriptor<Account>())) ?? []
    }

    private func transaction(_ externalID: String, in context: ModelContext) -> Transaction? {
        (try? context.fetch(FetchDescriptor<Transaction>()))?.first { $0.externalID == externalID }
    }

    // MARK: - The reported bug

    @Test("Remapping the primary checking and reverting restores the original mapping")
    func checkingRemapThenRevertIsReversible() {
        withCleanConfig { context in
            let checkingFeed = "checking-C"
            let cardFeed = "card-X"

            SimpleFINConfig.checkingID = checkingFeed

            let card = Account(name: "Visa", accountType: .credit, externalID: cardFeed)
            context.insert(card)
            context.insert(Transaction(amount: 1000, isIncome: true, account: nil,
                                       notes: "Opening balance", externalID: "op-C"))
            context.insert(Transaction(amount: 250, isIncome: false, account: card,
                                       notes: "Opening balance", externalID: "op-X"))
            try? context.save()

            // Accidentally remap the primary checking to the card's feed.
            BankSyncMapping.setPrimaryChecking(cardFeed, among: accounts(context), in: context)
            #expect(SimpleFINConfig.checkingID == cardFeed)
            #expect(card.externalID == checkingFeed)                 // feeds swapped, not lost
            #expect(transaction("op-C", in: context)?.account == card)
            #expect(transaction("op-X", in: context)?.account == nil)

            // Revert.
            BankSyncMapping.setPrimaryChecking(checkingFeed, among: accounts(context), in: context)
            #expect(SimpleFINConfig.checkingID == checkingFeed)
            #expect(card.externalID == cardFeed)
            #expect(transaction("op-C", in: context)?.account == nil)   // back on checking
            #expect(transaction("op-X", in: context)?.account == card)  // back on the card
            #expect(SimpleFINConfig.skippedIDs.isEmpty)                 // nothing stranded
        }
    }

    // MARK: - Card-to-card swap, one card at a time

    @Test("Swapping two cards' feeds one at a time lands each feed on the right card")
    func cardSwapOneAtATimeIsReversible() {
        withCleanConfig { context in
            let feedX = "card-X"
            let feedY = "card-Y"

            let cardA = Account(name: "A", accountType: .credit, externalID: feedX)
            let cardB = Account(name: "B", accountType: .credit, externalID: feedY)
            context.insert(cardA)
            context.insert(cardB)
            context.insert(Transaction(amount: 10, isIncome: false, account: cardA,
                                       notes: "x", externalID: "tx-X"))
            context.insert(Transaction(amount: 20, isIncome: false, account: cardB,
                                       notes: "y", externalID: "tx-Y"))
            try? context.save()

            // Point B at X (steals from A); A backfills with B's old feed Y.
            BankSyncMapping.link(feedX, to: cardB, among: accounts(context), in: context)
            #expect(cardB.externalID == feedX)
            #expect(cardA.externalID == feedY)
            #expect(transaction("tx-X", in: context)?.account == cardB)
            #expect(transaction("tx-Y", in: context)?.account == cardA)

            // Finish the swap by pointing A at Y — already there, stays consistent.
            BankSyncMapping.link(feedY, to: cardA, among: accounts(context), in: context)
            #expect(cardA.externalID == feedY)
            #expect(cardB.externalID == feedX)
            #expect(transaction("tx-X", in: context)?.account == cardB)
            #expect(transaction("tx-Y", in: context)?.account == cardA)
            #expect(SimpleFINConfig.skippedIDs.isEmpty)
        }
    }

    // MARK: - Unlink

    @Test("Unlinking a card keeps its transactions and stops syncing")
    func unlinkKeepsTransactionsAndSkips() {
        withCleanConfig { context in
            let feedX = "card-X"
            let card = Account(name: "A", accountType: .credit, externalID: feedX)
            context.insert(card)
            context.insert(Transaction(amount: 10, isIncome: false, account: card,
                                       notes: "x", externalID: "tx-X"))
            try? context.save()

            BankSyncMapping.link(nil, to: card, among: accounts(context), in: context)
            #expect(card.externalID == nil)
            #expect(transaction("tx-X", in: context)?.account == card)  // history stays
            #expect(SimpleFINConfig.skippedIDs.contains(feedX))         // won't nag as unmapped
        }
    }
}
