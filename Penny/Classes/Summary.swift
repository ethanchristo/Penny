//
//  Summary.swift
//  Penny
//
//  Created by Ethan Christo on 9/14/26.
//

import SwiftData
import SwiftUI

/// What a summary row points at, so the card can turn a row into a destination
/// without re-deriving which kind of budget the row came from.
enum SummaryTarget: Hashable {
    case categoryBudget(Category)
    case freestandingBudget(Budget)

    /// The id the row's zoom transition animates from — matching the `sourceID` its
    /// destination (`BudgetInsightsView` / `FreestandingBudgetInsightsView`) expects.
    var transitionID: UUID {
        switch self {
        case .categoryBudget(let category): return category.id
        case .freestandingBudget(let budget): return budget.id
        }
    }
}

/// One budget row: how far past its limit the budget is, as a positive magnitude,
/// with its name/symbol and where it leads.
struct SummaryBudgetStat: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let amount: Double
    let target: SummaryTarget
}

/// One expense that hasn't happened yet: the next occurrence of a recurring
/// transaction, or a future-dated one-time transaction.
struct SummaryUpcomingExpense: Identifiable {
    let transaction: Transaction
    /// When it's next due — the recurrence's next occurrence, or the transaction's
    /// own (future) date.
    let date: Date

    var id: UUID { transaction.id }
    var amount: Double { transaction.amount }

    /// The user's note wins, falling back to the tagged category/budget name.
    var name: String {
        if !transaction.notes.isEmpty { return transaction.notes }
        return transaction.category?.name ?? transaction.budget?.displayName ?? "Expense"
    }

    var symbol: String {
        transaction.category?.symbol ?? transaction.budget?.displaySymbol ?? "🗓️"
    }
}

/// The aggregation behind Home's summary card: what's overspent, what's due next,
/// and where the money went.
///
/// This is a cache, not a set of computed properties, and that's the whole point.
/// Every section here is O(categories × transactions) with a recurrence expansion
/// inside (`occurrenceCount`), which is far too heavy to re-run on every SwiftUI body
/// pass. `HomeView` owns the instance and calls `refresh` only when the inputs
/// actually change, keyed by the same fingerprints that drive the net total — see
/// `summaryTaskID` there, and `HomeStats` for the equivalent treatment of the totals.
///
/// Rows hold live SwiftData models (the card navigates to them), so this stays on the
/// main actor rather than following `StatsCalculator` onto a background ModelActor.
@MainActor
@Observable
final class Summary {
    /// Budgets spent past their limit, biggest overage first.
    private(set) var overspent: [SummaryBudgetStat] = []
    /// The next expenses due, soonest first.
    private(set) var upcoming: [SummaryUpcomingExpense] = []
    /// The window's biggest spending categories, largest first.
    private(set) var topSpending: [CategorySlice] = []
    /// Windowed spend against the overall budget. The limit itself is read live from
    /// `OverallBudget` by the card, since changing it doesn't change what was spent.
    private(set) var overallSpent: Double = 0

    /// True when there's nothing to summarize — the card hides itself (unless the
    /// overall budget is on, which it renders regardless).
    var isEmpty: Bool {
        overspent.isEmpty && upcoming.isEmpty && topSpending.isEmpty
    }

    /// How many rows each capped section keeps. The card is a summary, not a list —
    /// its section headers lead to the full views. Upcoming is the tightest since it
    /// has no horizon: the further down the list, the further out the due date.
    private let upcomingLimit = 2
    private let topSpendingLimit = 4

    /// The share of the window's total spending a category has to reach to earn a row
    /// in Top Spending, so the section shows where the money actually went instead of
    /// padding itself out with rounding errors.
    private let topSpendingShareFloor = 0.05

    /// The store contents one refresh reads from, bundled so each section builder
    /// doesn't take the same four parameters.
    private struct Inputs {
        let categories: [Category]
        let budgets: [Budget]
        let transactions: [Transaction]
        let selectedTimeRange: HomeTimeRange
    }

    /// Recomputes every section. Call this only when the underlying data changes;
    /// see the type's documentation for why it isn't a set of computed properties.
    func refresh(categories: [Category],
                 budgets: [Budget],
                 transactions: [Transaction],
                 selectedTimeRange: HomeTimeRange,
                 overallBudget: OverallBudget) {
        let inputs = Inputs(categories: categories,
                            budgets: budgets,
                            transactions: transactions,
                            selectedTimeRange: selectedTimeRange)

        let overspentRows = overspentBudgets(inputs)

        overspent = overspentRows
        upcoming = Array(upcomingExpenses(inputs).prefix(upcomingLimit))
        topSpending = Array(topSpendingCategories(inputs, excluding: overspentRows).prefix(topSpendingLimit))
        overallSpent = overallBudgetTotal(for: overallBudget, in: transactions, by: 0)
    }

    // MARK: - Overspent

    /// Budgets currently spent past their limit, biggest overage first. A pre-funded
    /// one-time budget is dropped once today is past the end of the selected-range
    /// window that follows its end date, so a closed envelope stops nagging while its
    /// late-posting transactions still have time to land.
    private func overspentBudgets(_ input: Inputs) -> [SummaryBudgetStat] {
        var results: [SummaryBudgetStat] = []

        // Category budgets — windowed spend vs. the category's limit.
        for category in input.categories {
            guard let budget = category.budget, budget.hasBudget, !budget.isFreestanding else { continue }
            let limit = budget.amount
            guard limit > 0 else { continue }
            let spent = budgetTotal(for: category, in: input.transactions, by: 0)
            if spent > limit {
                results.append(.init(id: "cat-\(category.id)",
                                     symbol: category.symbol,
                                     name: category.name,
                                     amount: spent - limit,
                                     target: .categoryBudget(category)))
            }
        }

        // Freestanding budgets track their own remaining balance.
        for budget in input.budgets where budget.hasBudget && budget.isFreestanding {
            guard budget.remaining < 0 else { continue }
            // Skip pre-funded one-time budgets whose grace window has passed.
            if budget.preFunding, !budget.isRecurring, let end = budget.end,
               Date.now > windowEnd(after: end, in: input.selectedTimeRange) {
                continue
            }
            results.append(.init(id: "budget-\(budget.id)",
                                 symbol: budget.displaySymbol,
                                 name: budget.displayName,
                                 amount: -budget.remaining,
                                 target: .freestandingBudget(budget)))
        }

        return results.sorted { $0.amount > $1.amount }
    }

    /// The end of the selected-range window that `date` falls in — the first window
    /// boundary on or after it. `allTime` has no boundary, so nothing ever ages out.
    private func windowEnd(after date: Date, in selectedTimeRange: HomeTimeRange) -> Date {
        switch selectedTimeRange {
        case .daily:     return date.endOfDay
        case .weekly:    return date.endOfWeek
        case .monthly:   return date.endOfMonth
        case .yearly:    return date.endOfYear
        case .payPeriod: return payPeriodBounds(containing: date, offset: 0).end
        case .allTime:   return .distantFuture
        }
    }

    // MARK: - Upcoming expenses

    /// The next expenses due, soonest first. A recurring transaction contributes its
    /// next occurrence (`nextOccurrence` is nil once the recurrence has ended), and a
    /// one-time transaction only counts while it's still dated in the future — the
    /// same split the transactions tab's Upcoming section makes.
    private func upcomingExpenses(_ input: Inputs) -> [SummaryUpcomingExpense] {
        let now = Date.now
        return input.transactions
            .filter { !$0.isIncome }
            .compactMap { transaction -> SummaryUpcomingExpense? in
                if let next = transaction.nextOccurrence {
                    return SummaryUpcomingExpense(transaction: transaction, date: next)
                }
                guard transaction.date > now else { return nil }
                return SummaryUpcomingExpense(transaction: transaction, date: transaction.date)
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Top spending categories

    /// The biggest spending categories in the selected window, largest first, keeping
    /// only those worth at least `topSpendingShareFloor` of the window's spending.
    /// Anything already called out as overspent is left out — those have their own
    /// section, and repeating them here would just be the same bad news twice.
    private func topSpendingCategories(_ input: Inputs, excluding overspent: [SummaryBudgetStat]) -> [CategorySlice] {
        let overspentIDs = Set(overspent.map(\.id))
        let slices = categorySpendData(transactions: input.transactions,
                                       categories: input.categories,
                                       window: windowBounds(for: input.selectedTimeRange, offset: 0))

        // The share is measured against ALL of the window's category spending — the
        // overspent categories included. They're dropped from the rows below, but
        // taking them out of the denominator would inflate everyone else's share.
        let windowSpending = slices.reduce(0) { $0 + $1.amount }
        guard windowSpending > 0 else { return [] }
        let floor = windowSpending * topSpendingShareFloor

        return slices.filter { $0.amount >= floor && !overspentIDs.contains("cat-\($0.category.id)") }
    }
}
