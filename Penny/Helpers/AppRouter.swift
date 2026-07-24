//
//  AppRouter.swift
//  Penny
//
//  Created by Ethan Christo on 6/15/26.
//

import Foundation
import Observation

/// The top-level tabs, used to drive `TabView` selection for deep links.
enum AppTab: Hashable {
    case home
    case budgets
    case insights
    case funds
    case transactions
}

/// Shared navigation state for deep links coming from outside the view tree
/// (Spotlight / Siri via the Open intents). The intents mutate `AppRouter.shared`
/// and the tab views observe it to switch tabs and push/present the destination.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: AppTab = .home

    /// Pending deep-link targets, keyed by the entity's stable `id`. Each tab
    /// view consumes its value (resolving the model and navigating) then clears it.
    var fundToOpen: UUID?
    var budgetToOpen: UUID?
    var transactionToOpen: UUID?

    private init() {}

    func openFund(id: UUID) {
        selectedTab = .funds
        fundToOpen = id
    }

    func openBudget(id: UUID) {
        selectedTab = .budgets
        budgetToOpen = id
    }

    func openTransaction(id: UUID) {
        selectedTab = .transactions
        transactionToOpen = id
    }
}
