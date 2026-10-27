//
//  BankSync.swift
//  Penny
//
//  Silent SimpleFIN / FinanceKit syncs shared by the foreground pass in HomeView
//  and the background app-refresh task. Each no-ops when its source isn't
//  connected and swallows errors — a failed fetch doesn't mean a dead connection.
//

import BackgroundTasks
import Foundation
import SwiftData
import WidgetKit

enum BankSync {
    /// `BGTaskSchedulerPermittedIdentifiers` entry for the background refresh.
    static let refreshTaskIdentifier = "com.ethanchristo.Penny.bank-refresh"

    /// Minimum gap between SimpleFIN fetches. The Bridge only refreshes about once
    /// a day and heavy polling can disable the connection.
    static let simpleFINThrottle: TimeInterval = 6 * 60 * 60

    /// Runs both syncs and reloads widgets if anything new was imported.
    @MainActor
    static func syncAll(in context: ModelContext) async {
        let simpleFIN = await syncSimpleFIN(in: context)
        let financeKit = await syncFinanceKit(in: context)
        if simpleFIN || financeKit {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Pulls new SimpleFIN transactions since the earliest per-account cutoff and
    /// imports them (dedup + categorisation handled by `SimpleFINImporter`).
    /// Throttled by `simpleFINThrottle`. Returns whether a fetch completed.
    @MainActor
    @discardableResult
    static func syncSimpleFIN(in context: ModelContext) async -> Bool {
        guard let accessURL = SimpleFINStore.loadAccessURL() else { return false }

        // A credential without local bookkeeping means iCloud Keychain brought
        // the connection over from another device; rebuild it from the synced
        // data so syncing resumes without a trip through Settings.
        guard SimpleFINConfig.isConfigured
                || SimpleFINConfig.adoptSyncedConnection(in: context)
        else { return false }

        if let last = SimpleFINConfig.lastSyncDate,
           Date.now.timeIntervalSince(last) < simpleFINThrottle { return false }

        // Fetch back to the earliest per-account cutoff so transactions that
        // were pending at setup and have since posted (possibly with a date
        // before the connection date) are returned — but never reach past the
        // Bridge's 90-day window.
        let earliest = Calendar.current.date(byAdding: .day, value: -89, to: .now)
        let cutoffFloor = SimpleFINConfig.accountCutoffs.values.min()
            ?? SimpleFINConfig.connectedDate
            ?? earliest ?? .now
        let startDate = max(cutoffFloor, earliest ?? .distantPast)

        do {
            let result = try await SimpleFINClient.fetchAccounts(accessURL: accessURL,
                                                                 startDate: startDate)
            await SimpleFINImporter.importNewTransactions(result.accounts, into: context)
            SimpleFINConfig.lastSyncDate = .now
            return true
        } catch {
            return false
        }
    }

    /// Pulls new Wallet transactions since each mapped account's cutoff and
    /// imports them (dedup + categorisation handled by `FinanceKitImporter`).
    /// On-device data, so there's no API limit to throttle against. Returns
    /// whether a fetch completed.
    @MainActor
    @discardableResult
    static func syncFinanceKit(in context: ModelContext) async -> Bool {
        if !FinanceKitConfig.isConfigured {
            // Bookkeeping missing but the mapping already synced (new device or
            // reinstall) — rebuild it so syncing resumes without a trip through
            // Settings. Only once Wallet access is granted, so the connection is
            // never marked live while authorization is denied.
            guard await FinanceKitClient.authorizationState() == .authorized,
                  FinanceKitConfig.adoptSyncedConnection(in: context)
            else { return false }
        }

        let floor = FinanceKitConfig.accountCutoffs.values.min()
            ?? FinanceKitConfig.connectedDate

        do {
            let accounts = try await FinanceKitClient.fetchAccounts(since: floor)
            await FinanceKitImporter.importNewTransactions(accounts,
                                                           into: context,
                                                           categorize: financeKitHybridCategorize)
            FinanceKitConfig.lastSyncDate = .now
            return true
        } catch {
            return false
        }
    }

    // MARK: Background refresh scheduling

    /// Asks the system to wake Penny for a bank refresh once the SimpleFIN
    /// throttle window has passed. iOS decides the actual run time based on
    /// usage; resubmitting replaces any pending request.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date.now.addingTimeInterval(simpleFINThrottle)
        try? BGTaskScheduler.shared.submit(request)
    }
}
