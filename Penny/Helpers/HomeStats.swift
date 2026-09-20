//
//  HomeStats.swift
//  Penny
//
//  Created by Ethan Christo on 6/5/26.
//

import Foundation
import SwiftData
import AppIntents

@Observable
final class HomeStats {
    var netIncome: Double = 0
    var netExpenses: Double = 0
    var netTotal: Double = 0

    /// Applies totals computed off the main thread by `StatsCalculator`.
    ///
    /// The net total is decoupled from the home time range: it is always ALL-TIME
    /// (optionally extended to the next payday for recurring transactions via the
    /// `net_total_include_upcoming` toggle). The heavy aggregation now runs on a
    /// background actor; this just publishes the result to the UI.
    @MainActor func apply(_ totals: NetTotals) {
        netIncome = totals.income
        netExpenses = totals.expenses
        netTotal = totals.total
    }
}

/// Computes a cheap fingerprint of a transactions array to drive `.onChange`/`.task(id:)`.
/// Catches insert/delete (count) and the in-place edits every dependent recompute reads:
/// amount, date, isIncome, category, recurrence + endDate, and notes.
///
/// Category is folded in so re-categorizing a transaction to Payroll re-fires the
/// recompute that syncs the payday-anchored pay period. Recurrence and endDate drive
/// `occurrenceCount`/`nextOccurrence`, so without them changing a transaction from
/// monthly to weekly (or ending a recurrence) would leave every windowed total — and
/// Home's Upcoming summary — stale. Notes are the name that summary shows.
func transactionsFingerprint(_ transactions: [Transaction]) -> Int {
    var hasher = Hasher()
    hasher.combine(transactions.count)
    for tx in transactions {
        hasher.combine(tx.amount)
        hasher.combine(tx.date)
        hasher.combine(tx.isIncome)
        hasher.combine(tx.category?.name)
        hasher.combine(tx.recurrence)
        hasher.combine(tx.endDate)
        hasher.combine(tx.notes)
    }
    return hasher.finalize()
}

/// Fingerprint of the categories that feed Home's summary card, so adding, deleting,
/// renaming, or restyling a category refreshes it. Budget amounts aren't included —
/// a category budget is a `Budget`, already covered by `budgetsFingerprint`.
func categoriesFingerprint(_ categories: [Category]) -> Int {
    var hasher = Hasher()
    hasher.combine(categories.count)
    for category in categories {
        hasher.combine(category.id)
        hasher.combine(category.name)
        hasher.combine(category.symbol)
        hasher.combine(category.hexColor)
    }
    return hasher.finalize()
}

/// Fingerprint of the budgets that feed `budgetNetAdjustment()`, so editing a budget
/// alone refreshes the net total. Folds in the amount/preFunding inputs the reserve
/// depends on for every active budget (a pre-funded *category* budget now reserves too),
/// plus freestanding `remaining` (so re-tagging a transaction to one is caught). Category
/// spend changes are already covered by `transactionsFingerprint`.
@MainActor func budgetsFingerprint(_ budgets: [Budget]) -> Int {
    var hasher = Hasher()
    for budget in budgets where budget.hasBudget {
        hasher.combine(budget.id)
        hasher.combine(budget.amount)
        hasher.combine(budget.preFunding)
        hasher.combine(budget.isFreestanding)
        if budget.isFreestanding {
            hasher.combine(budget.start)
            hasher.combine(budget.end)
            hasher.combine(budget.remaining)
        }
    }
    return hasher.finalize()
}

/// Fingerprint of the housing entries that feed `housingAllTimeTotal()`, so adding,
/// editing, or ending a rent/mortgage entry refreshes the net total.
@MainActor func housingsFingerprint(_ housings: [Housing]) -> Int {
    var hasher = Hasher()
    for housing in housings {
        hasher.combine(housing.id)
        hasher.combine(housing.amount)
        hasher.combine(housing.startDate)
        hasher.combine(housing.endDate)
        hasher.combine(housing.frequency)
        hasher.combine(housing.includeUpcoming)
        hasher.combine(housing.leadDays)
        hasher.combine(housing.matchNotes)
        hasher.combine(housing.account?.externalID)
    }
    return hasher.finalize()
}
