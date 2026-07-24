//
//  Budget.swift
//  Penny
//
//  Created by Ethan Christo on 1/24/26.
//

import SwiftData
import SwiftUI
import Observation

@Model
class Budget {
    // Stable, store-independent identifier. Used as the `id` for BudgetEntity
    // so App Intents / Spotlight can resolve a budget across the process
    // boundary, where PersistentIdentifier isn't usable as an entity id.
    var id: UUID = UUID()

    var hasBudget: Bool = false
    var budget: Double? = nil
    var budgetWindow: BudgetWindow? = nil
    
    var category: Category?
    
    init(hasBudget: Bool = false, budget: Double? = nil, budgetWindow: BudgetWindow? = nil) {
        self.hasBudget = hasBudget
        self.budget = budget
        self.budgetWindow = budgetWindow
    }
}

@Observable
class OverallBudget {
    private let defaults = UserDefaults.standard

    // Backing keys
    private let enabledKey = "overallBudgetEnabled"
    private let amountKey = "overallBudgetAmount"
    private let windowKey = "overallBudgetWindow"

    // Observable properties
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: enabledKey) }
    }

    var budget: Double {
        didSet { defaults.set(budget, forKey: amountKey) }
    }

    var budgetWindow: BudgetWindow {
        didSet { defaults.set(budgetWindow.rawValue, forKey: windowKey) }
    }

    init() {
        // Load from UserDefaults with sensible defaults
        self.isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? false
        self.budget = defaults.object(forKey: amountKey) as? Double ?? 0.0
        if let raw = defaults.string(forKey: windowKey), let window = BudgetWindow(rawValue: raw) {
            self.budgetWindow = window
        } else {
            self.budgetWindow = .monthly
        }
    }
}
