//
//  PennyFinanceMonitor.swift
//  PennyFinanceMonitor
//
//  Created by Ethan Christo on 10/25/26.
//
//  Woken by FinanceKit (at most hourly, see `FinanceKitClient.enableBackgroundDelivery`)
//  when Wallet data changes, so new transactions and balances land in Penny's
//  shared store without the app being opened. Mirrors `BankSync.syncFinanceKit`,
//  but categorises with rules only — the extension's memory budget doesn't leave
//  room for the on-device foundation model.
//

import ExtensionFoundation
import FinanceKit
import OSLog
import SwiftData
import WidgetKit

private let log = Logger(subsystem: "com.opal.Penny", category: "financeMonitor")

@main
class PennyFinanceMonitorExtension: BackgroundDeliveryExtension {
    required init() {}

    func didReceiveData(for types: [FinanceStore.BackgroundDataType]) async {
        await Self.sync()
    }

    func willTerminate() async {
        // Persist whatever was inserted before the system cuts the run short.
        await MainActor.run {
            try? SharedDatabase.shared.container.mainContext.save()
        }
    }

    @MainActor
    private static func sync() async {
        // Setup (and adopting a synced connection) only happens in the app, which
        // also owns the account mapping — nothing to do until then.
        guard FinanceKitConfig.isConfigured else { return }

        let context = SharedDatabase.shared.container.mainContext
        let floor = FinanceKitConfig.accountCutoffs.values.min()
            ?? FinanceKitConfig.connectedDate

        do {
            let accounts = try await FinanceKitClient.fetchAccounts(since: floor)
            let result = await FinanceKitImporter.importNewTransactions(
                accounts,
                into: context,
                categorize: FinanceKitImporter.rulesOnlyCategorize
            )
            FinanceKitConfig.lastSyncDate = .now
            // Balances are recorded even when nothing new imported, so always refresh.
            WidgetCenter.shared.reloadAllTimelines()
            log.info("Background delivery imported \(result.imported) transactions (\(result.skipped) skipped)")
        } catch {
            log.error("Background delivery sync failed: \(error.localizedDescription)")
        }
    }
}
