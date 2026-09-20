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

/// One budget row: a magnitude (always positive here — the card decides whether to
/// show it as an overage or as headroom) with its name/symbol, what it has spent of
/// what it's allowed, and where it leads.
struct SummaryBudgetStat: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let amount: Double
    /// Spend and limit for the row's subtitle. Carried separately from `amount`
    /// because headroom isn't always `limit - spent`: a contribute-toward freestanding
    /// budget measures what's left against what's been contributed so far.
    let spent: Double
    let limit: Double
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
/// where the money went, and what still has headroom.
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
    /// Recurring budgets still under their limit, most room first.
    private(set) var underspent: [SummaryBudgetStat] = []
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
        overspent.isEmpty && underspent.isEmpty && upcoming.isEmpty && topSpending.isEmpty
    }

    /// How many rows the upcoming/top-spending sections keep. The card is a summary,
    /// not a list — its section headers lead to the full views.
    private let rowLimit = 4

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
        underspent = underspentBudgets(inputs)
        upcoming = Array(upcomingExpenses(inputs).prefix(rowLimit))
        topSpending = Array(topSpendingCategories(inputs, excluding: overspentRows).prefix(rowLimit))
        overallSpent = overallBudgetTotal(for: overallBudget, in: transactions, by: 0)
    }

    // MARK: - Overspent / underspent

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
                                     spent: spent,
                                     limit: limit,
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
                                 spent: budget.used,
                                 limit: budget.amount,
                                 target: .freestandingBudget(budget)))
        }

        return results.sorted { $0.amount > $1.amount }
    }

    /// Recurring budgets still under their limit, most room first. One-time budgets are
    /// intentionally skipped — an ended envelope isn't "underspent", it's just done.
    private func underspentBudgets(_ input: Inputs) -> [SummaryBudgetStat] {
        var results: [SummaryBudgetStat] = []

        // Category budgets are always recurring.
        for category in input.categories {
            guard let budget = category.budget, budget.hasBudget, !budget.isFreestanding else { continue }
            let limit = budget.amount
            guard limit > 0 else { continue }
            let spent = budgetTotal(for: category, in: input.transactions, by: 0)
            if spent < limit {
                results.append(.init(id: "cat-\(category.id)",
                                     symbol: category.symbol,
                                     name: category.name,
                                     amount: limit - spent,
                                     spent: spent,
                                     limit: limit,
                                     target: .categoryBudget(category)))
            }
        }

        // Recurring freestanding budgets only.
        for budget in input.budgets where budget.hasBudget && budget.isFreestanding && budget.isRecurring {
            if budget.remaining > 0 {
                results.append(.init(id: "budget-\(budget.id)",
                                     symbol: budget.displaySymbol,
                                     name: budget.displayName,
                                     amount: budget.remaining,
                                     spent: budget.used,
                                     limit: budget.amount,
                                     target: .freestandingBudget(budget)))
            }
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

    /// The biggest spending categories in the selected window, largest first. Anything
    /// already called out as overspent is left out — those have their own section, and
    /// repeating them here would just be the same bad news twice.
    private func topSpendingCategories(_ input: Inputs, excluding overspent: [SummaryBudgetStat]) -> [CategorySlice] {
        let overspentIDs = Set(overspent.map(\.id))
        return categorySpendData(transactions: input.transactions,
                                 categories: input.categories,
                                 window: windowBounds(for: input.selectedTimeRange, offset: 0))
            .filter { !overspentIDs.contains("cat-\($0.category.id)") }
    }
}
