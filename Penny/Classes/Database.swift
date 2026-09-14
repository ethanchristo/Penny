//
//  Database.swift
//  Penny
//
//  Created by Ethan Christo on 3/24/26.
//

import Foundation
import SwiftData

@MainActor
class SharedDatabase {
    static let shared = SharedDatabase()

    /// Shared App Group container that backs the SwiftData store and the group
    /// `UserDefaults`. `nonisolated` so the background net-total actor and the
    /// widget can read it off the main actor.
    nonisolated static let appGroup = "group.com.ethanchristo.Penny"

    /// Private CloudKit container that mirrors the SwiftData store.
    nonisolated static let cloudKitContainer = "iCloud.com.ethanchristo.Penny"

    let container: ModelContainer

    private init() {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else {
            fatalError("App Group '\(Self.appGroup)' is not configured. Check entitlements.")
        }
        let databaseURL = groupURL.appendingPathComponent("default.store")
        let configuration = ModelConfiguration(url: databaseURL, cloudKitDatabase: .private(Self.cloudKitContainer))

        do {
            container = try ModelContainer(
                for: Transaction.self, Account.self, Category.self, Budget.self, CategoryRules.self, Housing.self,
                configurations: configuration
            )
        } catch {
            fatalError("Failed to create shared ModelContainer: \(error)")
        }
    }
}


/// The all-time net total (and its income/expense breakdown), computed off the main
/// thread. Plain `Double`s so the result is `Sendable` and can cross back to the UI.
struct NetTotals: Sendable {
    var income: Double = 0
    var expenses: Double = 0
    var total: Double = 0
}

/// Background actor that computes the home-tab net totals off the main thread.
///
/// SwiftData model objects are bound to their context's actor and are not `Sendable`,
/// so we can't hand the UI's `@Query` results to a background thread. Instead this
/// actor fetches its OWN copies through its own `ModelContext` (on a background
/// executor via `@ModelActor`), runs the heavy all-time aggregation there, and returns
/// only plain numbers — the model objects never leave this actor.
@ModelActor
actor StatsCalculator {
    func allTimeNetTotals() -> NetTotals {
        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        // Only freestanding budgets reserve against the net total; category budgets
        // don't, so the reserve helpers filter on `isFreestanding` anyway.
        let budgets = (try? modelContext.fetch(FetchDescriptor<Budget>())) ?? []
        let housings = (try? modelContext.fetch(FetchDescriptor<Housing>())) ?? []

        return NetTotals(
            income: netTotalAllTime(for: transactions, isIncome: true, budgets: budgets, housings: housings),
            expenses: netTotalAllTime(for: transactions, isIncome: false, budgets: budgets, housings: housings),
            total: netTotalAggregate(for: transactions, budgets: budgets, housings: housings)
        )
    }
}
