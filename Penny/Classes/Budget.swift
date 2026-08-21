//
//  Budget.swift
//  Penny
//
//  Created by Ethan Christo on 1/24/26.
//

import SwiftData
import SwiftUI
import Observation

// MARK: - Budget
/// The unified "envelope" model. A budget is a pot of money with an amount, a
/// period, and tracked spending. It spans what used to be two separate concepts:
///
///  • **Category budget** — `category != nil`. Spending is pulled from that
///    category's transactions. Always recurring; never accepts contributions.
///  • **Freestanding budget** (formerly "Fund") — `category == nil`. Spending is
///    pulled from transactions tagged directly to it (`Transaction.budgetValue`).
///    May be recurring or one-time, and may be pre-funded or contributed toward.
///
/// Three orthogonal options describe every budget:
///  1. **Scope** — category-linked vs. freestanding (`category`).
///  2. **Period** — recurring window vs. one-time span (`isRecurring` + `budgetWindow`
///     for recurring, `start`/`end` for one-time). Category budgets are forced recurring.
///  3. **Pre-Funding** — `preFunding` on = amount reserved up front, spend down;
///     off = contribute income toward the amount (freestanding only).
@Model
class Budget {
    // Stable, store-independent identifier. Used as the `id` for BudgetEntity
    // so App Intents / Spotlight can resolve a budget across the process
    // boundary, where PersistentIdentifier isn't usable as an entity id.
    var id: UUID = UUID()

    // MARK: Legacy category-budget fields (kept intact for existing data + CloudKit)
    /// Whether a *category* budget is active. Freestanding budgets are always active
    /// (their existence is the budget); they set this `true` on creation.
    var hasBudget: Bool = false
    /// The budget/goal amount. Named `budget` for backwards compatibility with the
    /// original category-budget schema; prefer the `amount` computed accessor.
    var budget: Double? = nil
    /// Recurring window (used when `isRecurring`). Category budgets always have one.
    var budgetWindow: BudgetWindow? = nil

    /// Optional category link. `nil` == freestanding. The inverse lives on
    /// `Category.budget` (cascade delete), so deleting a category removes its budget.
    var category: Category?

    // MARK: Unified fields (added additively — all optional/defaulted for CloudKit)
    /// Display name. Freestanding budgets use this; category budgets fall back to
    /// the category's name via `displayName`.
    var name: String = ""
    var symbol: String = "💰"
    var hexColor: String = "#32D74B"
    var notes: String = ""

    /// Recurring (resets each `budgetWindow`) vs. one-time (`start`→`end`).
    /// Category budgets are always recurring.
    var isRecurring: Bool = true
    var start: Date? = nil
    var end: Date? = nil

    /// On = the amount is reserved up front and spent down. Off = contribute income
    /// toward the amount. Only freestanding budgets support contributions (off).
    var preFunding: Bool = false

    /// Transactions tagged directly to this (freestanding) budget. Category budgets
    /// leave this nil and derive spending from the category's transactions instead.
    /// The inverse is `Transaction.budgetValue`. Deleting a transaction detaches it
    /// (nullify) rather than deleting the budget.
    @Relationship(deleteRule: .nullify, inverse: \Transaction.budgetValue)
    var transactions: [Transaction]? = nil

    // MARK: - Convenience

    /// `true` when this budget is a freestanding envelope (no category link).
    @Transient
    var isFreestanding: Bool { category == nil }

    /// The budget/goal amount as a non-optional.
    @Transient
    var amount: Double {
        get { budget ?? 0.0 }
        set { budget = newValue }
    }

    /// Name to show in the UI: the category's name for category budgets, otherwise
    /// the budget's own `name`.
    @Transient
    var displayName: String { category?.name ?? name }

    /// Symbol to show: the category's for category budgets, otherwise the budget's own.
    @Transient
    var displaySymbol: String { category?.symbol ?? symbol }

    // MARK: - Spending math (freestanding budgets)
    // These mirror the retired Fund model. Category budgets don't use these — their
    // spend is computed from the category's transactions windowed by `budgetWindow`.

    /// Sum of income transactions tagged to this budget (contributions).
    @Transient
    var contributed: Double {
        (transactions ?? []).reduce(0) { $1.isIncome ? $0 + $1.amount : $0 }
    }

    /// Sum of expense transactions tagged to this budget (uses).
    @Transient
    var used: Double {
        (transactions ?? []).reduce(0) { !$1.isIncome ? $0 + $1.amount : $0 }
    }

    /// Progress toward the amount for a contribute-toward budget.
    @Transient
    var progress: Double { amount - contributed }

    /// What's left. Pre-funded budgets spend down from the amount; contribute-toward
    /// budgets spend down from what's been contributed.
    @Transient
    var remaining: Double {
        preFunding ? amount - used : contributed - used
    }

    @Transient
    var color: Color {
        get { Color(hex: hexColor) ?? .green }
        set { hexColor = newValue.toHex() ?? "#00FF00" }
    }

    // MARK: - Init

    /// Category-budget initializer (backwards compatible with the original schema).
    init(hasBudget: Bool = false, budget: Double? = nil, budgetWindow: BudgetWindow? = nil) {
        self.hasBudget = hasBudget
        self.budget = budget
        self.budgetWindow = budgetWindow
        self.isRecurring = true
    }

    /// Freestanding-budget initializer (formerly `Fund`).
    init(
        name: String,
        amount: Double,
        preFunding: Bool = false,
        isRecurring: Bool = false,
        budgetWindow: BudgetWindow? = nil,
        start: Date? = nil,
        end: Date? = nil,
        symbol: String = "✈️",
        hexColor: String = "#32D74B",
        notes: String = ""
    ) {
        self.hasBudget = true
        self.budget = amount
        self.name = name
        self.preFunding = preFunding
        self.isRecurring = isRecurring
        self.budgetWindow = budgetWindow
        self.start = start
        self.end = end
        self.symbol = symbol
        self.hexColor = hexColor
        self.notes = notes
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
