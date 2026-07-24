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
/// Catches insert/delete (count) and the most common in-place edits (amount + date +
/// isIncome + category). Category is folded in so re-categorizing a transaction to
/// Payroll re-fires the recompute that syncs the payday-anchored pay period.
func transactionsFingerprint(_ transactions: [Transaction]) -> Int {
    var hasher = Hasher()
    hasher.combine(transactions.count)
    for tx in transactions {
        hasher.combine(tx.amount)
        hasher.combine(tx.date)
        hasher.combine(tx.isIncome)
        hasher.combine(tx.category?.name)
    }
    return hasher.finalize()
}

/// Fingerprint of the funds that feed `fundNetAdjustment()`. Folds in `remaining` (so
/// re-tagging a transaction to a fund is caught) along with the goal/preAllocate/date
/// inputs the adjustment depends on, so editing a fund alone refreshes the net total.
@MainActor func fundsFingerprint(_ funds: [Fund]) -> Int {
    var hasher = Hasher()
    hasher.combine(funds.count)
    for fund in funds {
        hasher.combine(fund.goal)
        hasher.combine(fund.preAllocate)
        hasher.combine(fund.start)
        hasher.combine(fund.end)
        hasher.combine(fund.remaining)
    }
    return hasher.finalize()
}
