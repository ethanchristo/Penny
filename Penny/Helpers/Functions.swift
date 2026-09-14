//
//  BudgetFunctions.swift
//  Penny
//
//  Created by Ethan Christo on 1/31/26.
//

import CoreData
import CoreSpotlight
import Foundation
import FoundationModels
import OSLog
import SwiftUI
import SwiftData
import AppIntents

private let log = Logger(subsystem: "com.opal.Penny", category: "data")

// MARK: - Transaction Filtering
func categoriedTransactions(for transactions: [Transaction], with category: Category) -> [Transaction] {
    transactions.filter { $0.category?.name == category.name }
}

nonisolated func typedTransactions(for transactions: [Transaction], income: Bool?, fund: Bool = false ) -> [Transaction] {
    if income == true {
        if !fund  {
            transactions.filter { $0.isIncome && $0.budget == nil }
        } else {
            // Include both plain income and budget contributions (both are `isIncome`).
            transactions.filter { $0.isIncome }
        }
    } else if income == false {
        if !fund {
            transactions.filter { !$0.isIncome && $0.budget == nil }
        } else {
            // Include both plain expenses and budget uses (both are `!isIncome`).
            transactions.filter { !$0.isIncome }
        }
    } else {
        if !fund {
            transactions
                .filter { $0.budget == nil }
        } else {
            transactions
        }
    }
}

func transactionsInRange(window: BudgetWindow? = nil, shiftAmount: Int, transactions: [Transaction]) -> [Transaction] {
    let bounds: (start: Date, end: Date)
    if let window {
        bounds = budgetWindowBounds(for: window, shiftAmount: shiftAmount)
    } else {
        // A nil window spans everything up through the end of today.
        let calendar = Calendar.current
        bounds = (calendar.startOfDay(for: .distantPast),
                  calendar.date(bySettingHour: 23, minute: 59, second: 59, of: .now) ?? .now)
    }
    return transactionsInRange(start: bounds.start, end: bounds.end, transactions: transactions)
}

/// [start, end] bounds for a `BudgetWindow` shifted by `shiftAmount` periods, with the
/// start normalized to midnight and the end to 23:59:59 of the window's last day.
/// Single source of truth for BudgetWindow windowing so the budget total, its
/// transaction list, and its chart all agree on exactly which dates fall inside.
func budgetWindowBounds(for window: BudgetWindow, shiftAmount: Int = 0) -> (start: Date, end: Date) {
    let now = Date().shifting(by: shiftAmount, window: window)
    let calendar = Calendar.current

    let rawStart: Date
    let rawEnd: Date
    switch window {
    case .daily:        rawStart = now.startOfDay; rawEnd = now.endOfDay
    case .weekly:       rawStart = now.startOfWeek; rawEnd = now.endOfWeek
    case .biweekly:     rawStart = now.startOfFortnight; rawEnd = now.endOfFortnight
    case .monthly:      rawStart = now.startOfMonth; rawEnd = now.endOfMonth
    case .quarterly:    rawStart = now.startOfQuarter; rawEnd = now.endOfQuarter
    case .semiAnnually: rawStart = now.startOfSemiAnnual; rawEnd = now.endOfSemiAnnual
    case .yearly:       rawStart = now.startOfYear; rawEnd = now.endOfYear
    }

    let start = calendar.startOfDay(for: rawStart)
    let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: rawEnd) ?? rawEnd
    return (start, end)
}

/// Filters `transactions` to those with at least one occurrence inside an explicit
/// [start, end] window, expanding recurrences the same way the calendar-window
/// overload does. Used for windows that aren't a `BudgetWindow` — e.g. the
/// payday-anchored pay period, whose bounds come from `payPeriodBounds`.
func transactionsInRange(start: Date, end: Date, transactions: [Transaction]) -> [Transaction] {
    let calendar = Calendar.current

    // Filter to those with at least one occurrence in the window, newest first.
    return transactions
        .filter { occurs($0, from: start, to: end, calendar: calendar) }
        .sorted { $0.date > $1.date }
}

// MARK: - Recurrence Occurrences

/// The number of times `transaction` occurs within the inclusive window [start, end],
/// expanding its recurrence. A non-recurring transaction occurs 0 or 1 times.
///
/// This is the single source of truth for "does this transaction land in the window,
/// and how many times" — every windowed total, count, and filter routes through it so
/// they can never drift apart. `calendar` is injected so callers summing over large
/// arrays reuse one instance rather than rebuilding `Calendar.current` per transaction.
/// Pass `countAll: false` to stop at the first hit when only existence matters.
nonisolated func occurrenceCount(of transaction: Transaction, from start: Date, to end: Date, calendar: Calendar = .current, countAll: Bool = true) -> Int {
    let txDate = calendar.startOfDay(for: transaction.date)

    // Cheap rejections: starts after the window, or its recurrence ended before it.
    if txDate > end { return 0 }
    if let endDate = transaction.endDate, calendar.startOfDay(for: endDate) < start { return 0 }

    switch transaction.recurrence {
    case .none:
        return (txDate >= start && txDate <= end) ? 1 : 0

    case .daily, .weekly, .biweekly, .monthly, .quarterly, .semiAnnually, .yearly:
        var nextOccurrence = txDate

        // Fast-forward to the first occurrence on or after the window start.
        if nextOccurrence < start {
            while nextOccurrence < start {
                guard let future = calculateNextDate(from: nextOccurrence, frequency: transaction.recurrence) else { return 0 }
                nextOccurrence = future
            }
        }

        // Occurrences (always midnight-aligned) are counted up to the transaction's
        // own end date if it has one, clamped to the window end.
        let actualEndDate = transaction.endDate.map { min(end, calendar.startOfDay(for: $0)) } ?? end

        var count = 0
        while nextOccurrence <= actualEndDate {
            if nextOccurrence >= start {
                count += 1
                if !countAll { return count }
            }
            guard let future = calculateNextDate(from: nextOccurrence, frequency: transaction.recurrence) else { break }
            nextOccurrence = future
        }
        return count
    }
}

/// Whether `transaction` has at least one occurrence inside [start, end]. Short-circuits
/// on the first hit — use this for filtering rather than `occurrenceCount(...) > 0`.
func occurs(_ transaction: Transaction, from start: Date, to end: Date, calendar: Calendar = .current) -> Bool {
    occurrenceCount(of: transaction, from: start, to: end, calendar: calendar, countAll: false) > 0
}

// MARK: - Total Calculations
/// Windowed sum of the non-reserved `transactions` (income adds, expense subtracts).
/// Transactions tagged to a freestanding budget, and those in a pre-funded category, are
/// skipped here — those budgets are reconciled in aggregate by `budgetNetAdjustment()` so
/// their impact lands on the net total exactly once, independent of the selected window and
/// never on the income/expense breakdowns. Ordinary category spending is NOT skipped — it
/// flows through as normal spending.
/// Pass `includeReserved: true` to count reserved (budget-tagged / pre-funded-category)
/// spending at face value instead of skipping it. The net total uses this so an account's
/// value reflects ALL its spending; the reserve then covers only the *unspent* remainder
/// (see `budgetReserveRemainingItems`), avoiding the double-count the old skip-plus-full-
/// reserve model produced.
nonisolated func calculateTotal(for transactions: [Transaction], start: Date, end: Date, includeReserved: Bool = false) -> Double {

    let savingsTotalEnabled = UserDefaults.group.object(forKey: "savings_total") as? Bool ?? false
    let calendar = Calendar.current

    let transactionTotal = transactions.reduce(0.0) { total, transaction in
        // Transactions reconciled in aggregate by the budget reserve rather than the
        // windowed running total: those tagged to a freestanding budget, and those in a
        // category whose budget is pre-funded (an envelope that behaves like a fund).
        let inPreFundedCategory = transaction.category?.budget.map { $0.hasBudget && $0.preFunding } ?? false
        let isReserved = transaction.budgetValue != nil || inPreFundedCategory

        // Skip only NORMAL savings transactions when the savings total is off.
        if !isReserved, transaction.account?.accountType == .savings, !savingsTotalEnabled {
            return total
        }

        // Reserved transactions are normally reconciled by the budget reserve, so they
        // don't move the running total — unless the caller wants them counted at face
        // value (the net total, so the reserve can cover only the unspent remainder).
        // A freestanding-budget *contribution* (income tagged directly to a budget) stays
        // excluded even then: it's a virtual earmark of money already on hand, not a new
        // deposit, so counting it would inflate the account's value.
        let isContribution = transaction.budgetValue != nil && transaction.isIncome
        if isReserved && (!includeReserved || isContribution) { return total }

        let multiplier = occurrenceCount(of: transaction, from: start, to: end, calendar: calendar)
        let amount = abs(transaction.amount) * Double(multiplier)

        // Only non-fund transactions reach here; income adds, expense subtracts.
        return transaction.isIncome ? total + amount : total - amount
    }

    return transactionTotal
}

/// Number of transactions with at least one occurrence inside the window.
/// Used as the divisor for per-transaction averages (e.g. the AVG stat in
/// Insights). Recurring transactions are counted once — matching how they
/// appear as a single row in the filtered list — and date windowing mirrors
/// `calculateTotal` so the count lines up with what the total is summed over.
@MainActor func transactionCount(for transactions: [Transaction], start: Date, end: Date) -> Int {
    // Recurring transactions are counted once (they appear as a single row), so this
    // is existence-in-window, not the raw occurrence count.
    let calendar = Calendar.current
    return transactions.reduce(into: 0) { count, transaction in
        if occurs(transaction, from: start, to: end, calendar: calendar) { count += 1 }
    }
}

/// Raw windowed sum of transaction *magnitudes* (`abs(amount)`), honoring the
/// date window and recurrence exactly like `calculateTotal` but WITHOUT its
/// fund/savings netting rules. `calculateTotal` deliberately skips fund-use
/// transactions and pre-allocate fund contributions so they don't move the
/// spendable total — which makes it return 0 for those. When you instead want
/// the actual money that moved (e.g. the Insights chart's fund contribution and
/// use breakdowns), use this so every transaction is counted at face value.
@MainActor func windowedAmountSum(for transactions: [Transaction], start: Date, end: Date) -> Double {
    let calendar = Calendar.current
    return transactions.reduce(0.0) { total, transaction in
        let multiplier = occurrenceCount(of: transaction, from: start, to: end, calendar: calendar)
        return total + abs(transaction.amount) * Double(multiplier)
    }
}

/// The aggregate reserve applied to the net total by **freestanding** budgets. Their own
/// transactions are skipped in `calculateTotal`; this reconciles them so money set aside
/// affects the net total. Category budgets are ignored here — their spend already flows
/// through the net total normally. Per freestanding budget the amount reserved (subtracted
/// by the caller) is:
///   • pre-funded: max(amount, used) — the full amount is removed from the net total, and
///     only spending *over* the amount eats further (amount + max(0, used − amount)).
///   • contribute-toward: max(contributed, used) — contributions are set aside and a use
///     only bites once it exceeds what was contributed.
/// Subtracted from the *net total only* (`isIncome == nil`), once, never on the
/// income/expense breakdowns.
/// Pure, nonisolated core: the aggregate reserve for an explicit set of budgets. Being
/// nonisolated lets it run on a background `ModelActor` as well as on the main thread.
nonisolated func budgetReserveTotal(for budgets: [Budget]) -> Double {
    budgetReserveItems(for: budgets).reduce(0.0) { $0 + $1.reserved }
}

/// Per-budget breakdown of `budgetReserveTotal`: the amount each budget reserves against
/// the net total, skipping budgets that reserve nothing. `budgetReserveTotal` is just the
/// sum of these, so the itemized display can never disagree with the applied reserve.
nonisolated func budgetReserveItems(for budgets: [Budget]) -> [(budget: Budget, reserved: Double)] {
    budgets.compactMap { budget in
        guard budget.hasBudget else { return nil }

        if budget.isFreestanding {
            let reserved = budget.preFunding
                ? max(budget.amount, budget.used)
                : max(budget.contributed, budget.used)
            return (budget, reserved)
        } else {
            // Category budgets reserve only when pre-funded. Their category's transactions
            // are excluded from the running total (see calculateTotal), so reconcile them
            // exactly like a pre-funded fund: max(amount, all-time category spend).
            guard budget.preFunding else { return nil }
            let categorySpend = (budget.category?.transactions ?? [])
                .reduce(0.0) { $1.isIncome ? $0 : $0 + abs($1.amount) }
            return (budget, max(budget.amount, categorySpend))
        }
    }
}

/// Main-thread convenience: prefers the caller's already-loaded budgets (the app passes
/// its `@Query` budgets) to avoid a fetch on every render, falling back to fetching the
/// shared container when none are supplied (the charts call this without budgets in hand).
@MainActor func budgetNetAdjustment(budgets: [Budget]? = nil) -> Double {
    let allBudgets = budgets ?? (try? SharedDatabase.shared.container.mainContext.fetch(FetchDescriptor<Budget>())) ?? []
    return budgetReserveTotal(for: allBudgets)
}

@MainActor func netTotalType(for transactions: [Transaction], use accounts: [Account]? = nil, budgets: [Budget]? = nil, isIncome: Bool? = nil, in selectedTimeRange: HomeTimeRange, offset: Int, type: CreditCardBalanceType) -> Double {

    if type == .statement {
        return netTotalCardStatement(for: transactions, isIncome: isIncome, with: accounts ?? [], budgets: budgets, in: selectedTimeRange)
    } else if type == .balance {
        return netTotalCardBalance(for: transactions, isIncome: isIncome, with: accounts ?? [], budgets: budgets, in: selectedTimeRange)
    } else {
        return netTotalAmount(for: transactions, isIncome: isIncome, budgets: budgets, in: selectedTimeRange, offset: offset)
    }
}

// MARK: - Pay Period Window

/// The user's configured pay-period settings, read from the shared App Group so the
/// app, widget, and Siri intent all resolve the same window. `anchor` is a known
/// payday (normalized to the start of its day); `cadence` is how often they're paid;
/// `graceDays` pulls each boundary slightly earlier to catch holiday-shifted checks.
/// Falls back to a biweekly cadence anchored to the start of the current week when
/// the user hasn't set a payday yet, so the window is still usable before setup.
nonisolated func payPeriodConfig() -> (anchor: Date, cadence: PayPeriodCadence, graceDays: Int) {
    let defaults = UserDefaults.group

    let cadence = PayPeriodCadence(rawValue: defaults.string(forKey: "pay_period_cadence") ?? "") ?? .biweekly

    let storedAnchor = defaults.double(forKey: "pay_period_anchor")
    let anchor = storedAnchor > 0 ? Date(timeIntervalSince1970: storedAnchor) : Date.now.startOfWeek

    let graceDays = defaults.object(forKey: "pay_period_grace_days") as? Int ?? 2

    return (anchor.startOfDay, cadence, graceDays)
}

/// Start/end of the pay period `offset` periods away from the one containing `date`.
/// `offset` 0 is the current period, -1 the previous, +1 the next. The end is
/// 23:59:59 of the period's last day, matching the inclusive end used elsewhere.
///
/// The boundary is anchored to the user's payday and repeats each cadence, so every
/// window holds exactly one paycheck even though paydays drift across calendar months.
/// Boundaries that land on a weekend roll back to the preceding business day (payroll
/// pays early when payday is a Sat/Sun), and `graceDays` pulls the boundary a little
/// earlier still so a holiday-shifted check lands in the period it funds rather than
/// the previous one.
nonisolated func payPeriodBounds(containing date: Date = .now, offset: Int = 0) -> (start: Date, end: Date) {
    let calendar = Calendar.current
    let (anchor, cadence, graceDays) = payPeriodConfig()
    let today = calendar.startOfDay(for: date)

    // The nominal (scheduled) boundary `n` periods from the anchor. Monthly steps by
    // whole calendar months (preserving day-of-month); day-based cadences by length.
    func nominalBoundary(_ n: Int) -> Date {
        if let length = cadence.lengthDays {
            return calendar.date(byAdding: .day, value: n * length, to: anchor) ?? anchor
        }
        return calendar.date(byAdding: .month, value: n, to: anchor) ?? anchor
    }

    // The boundary actually used for bucketing: roll off weekends to the prior
    // business day, then subtract the grace days. Both only ever move it earlier.
    func effectiveBoundary(_ n: Int) -> Date {
        var boundary = nominalBoundary(n)
        while calendar.isDateInWeekend(boundary) {
            boundary = calendar.date(byAdding: .day, value: -1, to: boundary) ?? boundary
        }
        boundary = calendar.date(byAdding: .day, value: -graceDays, to: boundary) ?? boundary
        return calendar.startOfDay(for: boundary)
    }

    // Estimate the period index containing `today`, then correct for the small
    // distortions the weekend/grace adjustments introduce. Both loops are bounded
    // because the estimate is at most one period off.
    var n: Int
    if let length = cadence.lengthDays {
        let days = calendar.dateComponents([.day], from: anchor, to: today).day ?? 0
        n = Int(floor(Double(days) / Double(length)))
    } else {
        n = calendar.dateComponents([.month], from: anchor.startOfMonth, to: today.startOfMonth).month ?? 0
    }
    while effectiveBoundary(n) > today { n -= 1 }
    while effectiveBoundary(n + 1) <= today { n += 1 }

    n += offset

    let start = effectiveBoundary(n)
    let rawEnd = effectiveBoundary(n + 1)
    let end = calendar.date(byAdding: .second, value: -1, to: rawEnd) ?? rawEnd

    return (start, end)
}

/// The most recent Payroll-categorized transaction's day (start-of-day), or nil if
/// there are none. Single source of truth for payroll detection — used both to sync
/// the anchor and to show the detected payday in Settings. Optionally pass a
/// pre-fetched list; otherwise it fetches from the shared container.
@MainActor func latestPayrollDate(from transactions: [Transaction]? = nil) -> Date? {
    let txns = transactions ?? (try? SharedDatabase.shared.container.mainContext.fetch(FetchDescriptor<Transaction>())) ?? []
    return txns
        .filter { $0.category?.effectiveRole == .payroll }
        .map(\.date)
        .max()?
        .startOfDay
}

/// When payroll tracking is enabled, anchors the pay period to the most recent
/// Payroll transaction, writing it to the shared App Group so the app and widget
/// resolve the same window without manual upkeep. No-op when tracking is off or there
/// are no payroll transactions yet, so a manually set payday is preserved.
@MainActor func syncPayrollPayPeriodAnchor(from transactions: [Transaction]? = nil) {
    let defaults = UserDefaults.group
    guard defaults.object(forKey: "pay_period_track_payroll") as? Bool ?? true else { return }
    guard let payday = latestPayrollDate(from: transactions) else { return }
    defaults.set(payday.timeIntervalSince1970, forKey: "pay_period_anchor")
}

/// The [start, end] date bounds for a `HomeTimeRange` shifted by `offset` periods.
/// Single source of truth for windowing so the total and the fund adjustment agree
/// on exactly which dates fall inside the selected window.
@MainActor func windowBounds(for selectedTimeRange: HomeTimeRange, offset: Int) -> (start: Date, end: Date) {
    switch selectedTimeRange {
    case .daily:
        let anchorDate = Date().shifting(by: offset, window: .daily)
        return (anchorDate.startOfDay, anchorDate.endOfDay)
    case .weekly:
        let anchorDate = Date().shifting(by: offset, window: .weekly)
        return (anchorDate.startOfWeek, anchorDate.endOfWeek)
    case .payPeriod:
        return payPeriodBounds(offset: offset)
    case .monthly:
        let anchorDate = Date().shifting(by: offset, window: .monthly)
        return (anchorDate.startOfMonth, anchorDate.endOfMonth)
    case .yearly:
        let anchorDate = Date().shifting(by: offset, window: .yearly)
        return (anchorDate.startOfYear, anchorDate.endOfYear)
    case .allTime:
        // No window to shift; span everything up to the end of today.
        return (.distantPast, Date().endOfDay)
    }
}

/// Raw windowed total for a `HomeTimeRange` + offset, with NO fund adjustment applied.
/// Shared building block so callers can add the fund adjustment exactly once.
@MainActor func windowTotal(for transactions: [Transaction], in selectedTimeRange: HomeTimeRange, offset: Int) -> Double {
    let bounds = windowBounds(for: selectedTimeRange, offset: offset)
    return calculateTotal(for: transactions, start: bounds.start, end: bounds.end)
}

@MainActor func netTotalAmount(for transactions: [Transaction], isIncome: Bool?, budgets: [Budget]? = nil, in selectedTimeRange: HomeTimeRange, offset: Int) -> Double {
    let filtered = typedTransactions(for: transactions, income: isIncome)
    let total = windowTotal(for: filtered, in: selectedTimeRange, offset: offset)

    // Apply the budget reserve only to the aggregate net total (isIncome == nil),
    // never to the income/expense breakdowns.
    return isIncome == nil ? total - budgetNetAdjustment(budgets: budgets) : total
}

/// The all-time net total (or income/expense breakdown) for the home tab, decoupled
/// from the selected time range. Sums everything through today; when the
/// `net_total_include_upcoming` toggle is on, RECURRING transactions are additionally
/// counted through the next predicted payday, so bills/income due before the next
/// paycheck are reflected. Future one-time transactions are never included. The fund
/// reserve is applied once, to the net total only.
/// Nonisolated so it can run on a background `ModelActor` (see `StatsCalculator`) as
/// well as the main thread. `budgets` is required — the caller passes the budgets fetched
/// from the same context as `transactions`, so no context-crossing fetch is needed.
nonisolated func netTotalAllTime(for transactions: [Transaction], isIncome: Bool?, budgets: [Budget], housings: [Housing] = []) -> Double {
    let includeUpcoming = UserDefaults.group.object(forKey: "net_total_include_upcoming") as? Bool ?? true
    let filtered = typedTransactions(for: transactions, income: isIncome)

    let now = Date().endOfDay
    // Recurring transactions extend to the next payday when the toggle is on.
    let recurringEnd = includeUpcoming ? payPeriodBounds(offset: 1).start.endOfDay : now

    let nonRecurring = filtered.filter { $0.recurrence == .none }
    let recurring = filtered.filter { $0.recurrence != .none }

    var total = calculateTotal(for: nonRecurring, start: .distantPast, end: now)
    total += calculateTotal(for: recurring, start: .distantPast, end: recurringEnd)

    // Housing (rent/mortgage) is expense-only, so it never touches the income breakdown.
    if isIncome != true { total -= housingAllTimeTotal(for: housings, transactions: transactions) }

    return isIncome == nil ? total - budgetReserveTotal(for: budgets) : total
}

/// Whether `housing`'s chosen account has a real bank feed behind it — either a specific
/// `Account` with an `externalID`, or the primary checking bucket (`housing.account ==
/// nil`, mirroring the app-wide convention that a nil `Transaction.account` means primary
/// checking) when SimpleFIN/FinanceKit has designated a checking account for it. Reads the
/// raw App Group keys directly (mirroring `BankSyncMapping.primaryCheckingID`) rather than
/// depending on that type, since this file is also compiled into the widget target, which
/// doesn't link the SimpleFIN/FinanceKit client code that type lives alongside.
nonisolated private func housingAccountIsImportLinked(_ housing: Housing) -> Bool {
    if let account = housing.account { return account.externalID != nil }
    let defaults = UserDefaults.group
    return defaults.string(forKey: "simplefin_checking_id") != nil
        || defaults.string(forKey: "financekit_checking_id") != nil
}

/// Whether `transaction` is the real (bank-imported) posting of `housing`'s payment —
/// matched by notes + amount on the housing's own linked account (which may be the nil
/// "primary checking" bucket). Only meaningful once the user has linked a transaction
/// once (`housing.matchNotes` is set) and the account is import-linked; a manually-added/
/// unlinked account never matches, so its occurrences are never skipped.
nonisolated private func housingPaymentMatches(_ transaction: Transaction, housing: Housing) -> Bool {
    guard housingAccountIsImportLinked(housing) else { return false }
    guard let matchNotes = housing.matchNotes, !matchNotes.isEmpty else { return false }
    return transaction.account == housing.account
        && transaction.notes == matchNotes
        && abs(abs(transaction.amount) - housing.amount) < 0.005
}

/// All-time cost of `housings` (rent/mortgage payments), summed the same way a recurring
/// expense Transaction is: through today, extended ahead of an upcoming occurrence's due
/// date by that entry's own `leadDays` when `includeUpcoming` is on (both configurable per
/// housing entry — see `Housing`). Always a positive magnitude — callers subtract it from
/// the net total.
///
/// When `housing`'s account is import-linked (SimpleFIN/FinanceKit — see
/// `housingAccountIsImportLinked`), every PAST occurrence is already reflected in that
/// account's own balance via its real, bank-synced transactions, so only the not-yet-
/// happened upcoming occurrence (within `leadDays`, when `includeUpcoming` is on) is
/// projected here — summing all of history too would double-count everything the bank
/// feed already carries. Without an import link (manually-tracked account, or none at
/// all), there's no such feed, so every occurrence that's ever happened still counts,
/// same as a manually-entered recurring Transaction always has.
///
/// Either way, an occurrence whose period already contains a real transaction matching
/// the user's one-time `matchNotes` link is skipped regardless — covers the case where a
/// payment posts a little early or late relative to its scheduled date.
nonisolated func housingAllTimeTotal(for housings: [Housing], transactions: [Transaction] = []) -> Double {
    guard !housings.isEmpty else { return 0 }
    let now = Date().endOfDay
    let today = Date.now.startOfDay
    let calendar = Calendar.current

    return housings.reduce(0.0) { runningTotal, housing in
        let end: Date = housing.includeUpcoming
            ? (calendar.date(byAdding: .day, value: housing.leadDays, to: now) ?? now)
            : now

        // Import-linked housing skips everything before today — that history is already
        // in the account's own balance. Manually-tracked housing sums from the very start.
        let windowStart = housingAccountIsImportLinked(housing) ? today : calendar.startOfDay(for: housing.startDate)

        var occurrenceDate = calendar.startOfDay(for: housing.startDate)
        if let housingEnd = housing.endDate, calendar.startOfDay(for: housingEnd) < occurrenceDate { return runningTotal }
        guard occurrenceDate <= end else { return runningTotal }

        let actualEndDate = housing.endDate.map { min(end, calendar.startOfDay(for: $0)) } ?? end
        let recurrence = housing.frequency.asRecurrence

        var housingTotal = 0.0
        while occurrenceDate <= actualEndDate {
            let nextOccurrence = calculateNextDate(from: occurrenceDate, frequency: recurrence)
            let periodEnd = nextOccurrence ?? (calendar.date(byAdding: .day, value: 1, to: occurrenceDate) ?? occurrenceDate)

            // Skip occurrences before the window (already reflected elsewhere for
            // import-linked housing) and any whose period already contains the matching
            // real payment — that's already counted through the normal transaction total.
            let alreadyPosted = occurrenceDate < windowStart || transactions.contains { transaction in
                housingPaymentMatches(transaction, housing: housing)
                    && transaction.date >= occurrenceDate
                    && transaction.date < periodEnd
            }
            if !alreadyPosted {
                housingTotal += housing.amount
            }

            guard let next = nextOccurrence else { break }
            occurrenceDate = next
        }

        return runningTotal + housingTotal
    }
}

/// Amount owed on a single credit card, from its own transactions and its
/// closing-day setting. `due` is the last closed statement's balance (owed on the
/// due date); `total` is the full outstanding balance (all-time net — the seeded
/// opening balance makes this the real current balance). Both positive when owed.
/// Nonisolated so it can run on the background `StatsCalculator`.
nonisolated func creditCardOwed(for card: Account, transactions: [Transaction], includeReserved: Bool = false) -> (due: Double, total: Double) {
    let calendar = Calendar.current
    let now = Date.now
    let cardTransactions = transactions.filter { $0.account == card }

    // The billing cycle that ended on the closing date that most recently passed.
    let close = mostRecentDayOfMonth(card.closingDate ?? 1, onOrBefore: now, calendar: calendar)
    let previousClose = calendar.date(byAdding: .month, value: -1, to: close) ?? close
    let periodStart = calendar.startOfDay(
        for: calendar.date(byAdding: .day, value: 1, to: previousClose) ?? previousClose
    )

    // The seeded "Opening balance" transaction captures the card's balance at
    // connect time, not a real statement charge, and is dated at connect. Left in,
    // it can land inside the statement window and inflate the amount due by nearly
    // the whole starting balance — so exclude it from the statement calc. (The id
    // prefix mirrors `SimpleFINImporter`/`FinanceKitImporter.openingBalanceID`.) It
    // stays in `total`, since it is genuinely part of the outstanding balance.
    let statementTxns = cardTransactions.filter {
        guard let externalID = $0.externalID else { return true }
        return !externalID.hasPrefix("simplefin-opening-balance-")
            && !externalID.hasPrefix("financekit-opening-balance-")
    }

    // `calculateTotal` returns income − expense, so spending is negative; flip the
    // sign so an amount owed reads positive.
    let due = -calculateTotal(for: statementTxns, start: periodStart, end: close.endOfDay, includeReserved: includeReserved)
    let total = -calculateTotal(for: cardTransactions, start: .distantPast, end: now.endOfDay, includeReserved: includeReserved)
    return (due, total)
}

/// Per-budget "reserve remaining" for the net total — the still-unspent portion of each
/// budget's set-aside money, applied as ONE global adjustment (never tied to a specific
/// card). Actual spending is reflected by the account/card balances themselves (the net
/// total counts reserved transactions at face value via `calculateTotal(includeReserved:)`),
/// so the reserve covers only what hasn't been utilized yet: `max(0, target - used)`.
///
///   • **Pre-funded** budget (freestanding or category): `target = amount`. Starts fully
///     reserved (`amount` when nothing's spent) and shrinks as utilization grows, hitting
///     0 once spending reaches the amount — past that the balances alone carry the spend.
///   • **Contribution** budget (freestanding, not pre-funded): `target = contributed`.
///     The contributed money is reserved, reduced by any utilization, and only counts
///     while contributions exceed use (`max(0, contributed - used)`).
///   • **Plain category** budget (not pre-funded): reserves nothing.
///
/// Skips budgets that reserve nothing so the itemized breakdown stays tidy.
nonisolated func budgetReserveRemainingItems(for budgets: [Budget]) -> [(budget: Budget, reserved: Double)] {
    budgets.compactMap { budget in
        guard budget.hasBudget else { return nil }

        let target: Double
        let used: Double
        if budget.isFreestanding {
            target = budget.preFunding ? budget.amount : budget.contributed
            used = budget.used
        } else {
            // Category budgets reserve only when pre-funded; their spend is the category's
            // all-time expenses (its transactions are counted in the net total normally).
            guard budget.preFunding else { return nil }
            target = budget.amount
            used = (budget.category?.transactions ?? [])
                .reduce(0.0) { $1.isIncome ? $0 : $0 + abs($1.amount) }
        }

        let reserved = max(0, target - used)
        return reserved > 0 ? (budget, reserved) : nil
    }
}

/// Aggregate net-total reserve: the sum of every budget's unspent reservation.
nonisolated func budgetReserveRemainingTotal(for budgets: [Budget]) -> Double {
    budgetReserveRemainingItems(for: budgets).reduce(0.0) { $0 + $1.reserved }
}

/// The fully itemized components that sum to the home/widget/Siri net total, so the UI
/// can show *exactly where the number came from* — one row per account, per card, per
/// upcoming recurring transaction, and per reserving budget. Each `value` already carries
/// its sign, so every item and every group subtotal adds up to `total` directly.
/// `Sendable`/plain values so the whole thing can cross back from `StatsCalculator`.
struct NetTotalBreakdown: Sendable {
    /// A single signed line. `value` is its signed contribution to the net total.
    struct Item: Sendable, Identifiable {
        let id: String
        let label: String
        let value: Double
    }

    /// A named collection of items (e.g. every account) with its own subtotal.
    struct Group: Sendable, Identifiable {
        let id: String
        let title: String
        let items: [Item]
        nonisolated var subtotal: Double { items.reduce(0) { $0 + $1.value } }
    }

    var groups: [Group] = []
    nonisolated var total: Double { groups.reduce(0) { $0 + $1.subtotal } }
}

/// The credit-card-aware home/widget/Siri net total: assets (checking + debit +
/// savings-if-enabled) − credit-card debt − fund reserve, all-time and optionally
/// extended to the next payday for recurring transactions. Thin wrapper over
/// `netTotalBreakdown` so the displayed total and its breakdown can never drift.
nonisolated func netTotalAggregate(for transactions: [Transaction], budgets: [Budget], housings: [Housing] = []) -> Double {
    netTotalBreakdown(for: transactions, budgets: budgets, housings: housings).total
}

/// Same computation as `netTotalAggregate`, but returns the individual components
/// (assets, credit debt, upcoming recurring, budget reserve) that sum to the total.
///
/// Reserve model: each account/card contributes its FULL value (all spending included),
/// and budgets are reconciled by ONE global reserve of their unspent set-aside money
/// (`budgetReserveRemainingItems`). A pre-funded budget starts fully reserved and its
/// reservation shrinks as it's spent (utilization is already reflected in the balances),
/// reaching 0 once spending meets the amount; a contribution budget reserves
/// `max(0, contributed − used)`. Nothing is tied to a specific card.
///
/// Credit cards count per the `net_total_credit_mode` setting — `.balance` subtracts
/// each card's full outstanding balance, `.statement` subtracts only its last closed
/// statement (amount due). When a bank sync has reported a live balance for an account
/// it is the source of truth (checking included); otherwise the figure is derived
/// from that account's transactions. Unless `include_installment_balance` is on, each
/// card's manually entered installment-plan balance is then subtracted back out, since
/// bank-sync balances have no way to report it separately. Nonisolated so it runs on
/// `StatsCalculator`.
nonisolated func netTotalBreakdown(for transactions: [Transaction], budgets: [Budget], housings: [Housing] = []) -> NetTotalBreakdown {
    let defaults = UserDefaults.group
    let mode = CreditCardBalanceType(rawValue: defaults.string(forKey: "net_total_credit_mode") ?? "") ?? .balance
    let includeUpcoming = defaults.object(forKey: "net_total_include_upcoming") as? Bool ?? true
    let includeSavings = defaults.object(forKey: "savings_total") as? Bool ?? false
    let includeInstallmentBalance = defaults.object(forKey: "include_installment_balance") as? Bool ?? false
    // Read the bank-sync live balances straight from the App Group (keys mirror
    // `SimpleFINConfig` / `FinanceKitConfig`) so this stays usable from the widget
    // target, which links neither client. FinanceKit ids are namespaced
    // (`financekit-…`), so the two dictionaries merge without key collisions.
    var balances = defaults.dictionary(forKey: "simplefin_account_balances") as? [String: Double] ?? [:]
    balances.merge(defaults.dictionary(forKey: "financekit_account_balances") as? [String: Double] ?? [:]) { _, new in new }
    // Whichever source designated the primary checking (only one can, in practice).
    let checkingID = defaults.string(forKey: "simplefin_checking_id")
        ?? defaults.string(forKey: "financekit_checking_id")

    let now = Date().endOfDay

    let creditTxns = transactions.filter { $0.account?.accountType == .credit }
    let nonCreditTxns = transactions.filter { $0.account?.accountType != .credit }

    // MARK: Assets — one item per account, preferring the bank-sync live balance,
    // else the transaction-derived all-time total. Both reflect the account's FULL value
    // (budget/reserved spending included); the reserve below covers only the unspent
    // remainder, so nothing is double-counted.
    var assetItems: [NetTotalBreakdown.Item] = []

    // Primary checking (account == nil) maps to the designated live-balance checkingID.
    let checkingTxns = nonCreditTxns.filter { $0.account == nil }
    let checkingValue: Double
    if let checkingID, let balance = balances[checkingID] {
        // Live balance already includes all spending. `abs` guards against a source
        // reporting a signed balance (e.g. Apple Card comes through negative).
        checkingValue = abs(balance)
    } else {
        // Count reserved spending at face value so the balance reflects reality; the
        // reserve then only holds what hasn't been spent.
        checkingValue = calculateTotal(for: checkingTxns, start: .distantPast, end: now, includeReserved: true)
    }
    assetItems.append(.init(id: "checking", label: "Primary checking", value: checkingValue))

    // Each mapped non-credit account (savings, additional checking/debit).
    for account in Set(nonCreditTxns.compactMap({ $0.account })) {
        // Honor the savings toggle even on the live-balance path (the
        // transaction path already excludes savings via `calculateTotal`).
        if account.accountType == .savings, !includeSavings { continue }
        let accountTxns = nonCreditTxns.filter { $0.account == account }
        let value: Double
        if let externalID = account.externalID, let balance = balances[externalID] {
            value = abs(balance)
        } else {
            value = calculateTotal(for: accountTxns, start: .distantPast, end: now, includeReserved: true)
        }
        let label = account.name.isEmpty ? "Account" : account.name
        assetItems.append(.init(id: "account-\(account.externalID ?? account.name)", label: label, value: value))
    }

    // MARK: Credit-card debt — one item per card, stored negative (it reduces the total).
    // The card's balance now reflects ALL spending charged to it, including reserved/budget
    // spending (no per-card reserve adjustment — that's applied globally below). This is what
    // fixes spend cards (Chase/Amex) from flipping positive: an all-time budget-use figure is
    // never subtracted from a single card's current balance.
    var creditItems: [NetTotalBreakdown.Item] = []
    for card in Set(creditTxns.compactMap({ $0.account })) {
        var owed: Double
        switch mode {
        case .statement:
            owed = creditCardOwed(for: card, transactions: creditTxns, includeReserved: true).due
        default: // .balance
            if let externalID = card.externalID, let balance = balances[externalID] {
                // `abs` takes the owed magnitude regardless of the source's sign
                // convention (Apple Card reports a negative balance).
                owed = abs(balance)
            } else {
                owed = creditCardOwed(for: card, transactions: creditTxns, includeReserved: true).total
            }
        }
        // Bank-sync balances (and this card's own transaction history) lump an
        // installment plan's remaining balance in with the rest of what's owed, with
        // no way to separate it out from the API alone. When the setting is off,
        // subtract the manually entered installment balance back out.
        if !includeInstallmentBalance {
            owed = max(0, owed - card.installmentBalance)
        }
        let label = card.name.isEmpty ? "Credit card" : card.name
        creditItems.append(.init(id: "card-\(card.externalID ?? card.name)", label: label, value: -owed))
    }

    // MARK: Upcoming recurring — one item per recurring transaction whose FUTURE
    // occurrences (before the next payday) contribute. Past occurrences are already in
    // the balances/totals above, so each item is (through-payday − through-today).
    var upcomingItems: [NetTotalBreakdown.Item] = []
    if includeUpcoming {
        let recurringEnd = payPeriodBounds(offset: 1).start.endOfDay
        if recurringEnd > now {
            let recurring = transactions.filter { $0.recurrence != .none }
            for txn in recurring {
                let throughEnd = calculateTotal(for: [txn], start: .distantPast, end: recurringEnd)
                let throughNow = calculateTotal(for: [txn], start: .distantPast, end: now)
                let value = throughEnd - throughNow
                guard abs(value) >= 0.005 else { continue }
                let label = txn.notes.isEmpty ? (txn.category?.name ?? "Recurring") : txn.notes
                upcomingItems.append(.init(id: "recurring-\(txn.id.uuidString)", label: label, value: value))
            }
        }
    }

    // MARK: Budget reserve — one item per reserving budget, stored negative. This is the
    // single global adjustment: each budget's still-unspent set-aside money. Utilization is
    // already reflected in the account/card balances above, so this shrinks as budgets are
    // spent and never touches an individual card.
    let reserveItems = budgetReserveRemainingItems(for: budgets).map { entry in
        NetTotalBreakdown.Item(
            id: "budget-\(entry.budget.displayName)",
            label: entry.budget.displayName,
            value: -entry.reserved
        )
    }

    // MARK: Housing — one item per rent/mortgage entry, stored negative. Each item is
    // that entry's full cost since its start date, extended ahead of its due date by its
    // own lead-days setting when upcoming inclusion is on (see `housingAllTimeTotal`).
    let housingItems = housings.map { housing in
        NetTotalBreakdown.Item(
            id: "housing-\(housing.id.uuidString)",
            label: housing.name.isEmpty ? (housing.mortgage ? "Mortgage" : "Rent") : housing.name,
            value: -housingAllTimeTotal(for: [housing], transactions: transactions)
        )
    }

    var groups: [NetTotalBreakdown.Group] = []
    groups.append(.init(id: "assets", title: "Accounts", items: assetItems))
    if !creditItems.isEmpty {
        groups.append(.init(id: "credit", title: "Credit card debt", items: creditItems))
    }
    if !upcomingItems.isEmpty {
        groups.append(.init(id: "upcoming", title: "Upcoming recurring", items: upcomingItems))
    }
    if !housingItems.isEmpty {
        groups.append(.init(id: "housing", title: "Housing", items: housingItems))
    }
    if !reserveItems.isEmpty {
        groups.append(.init(id: "reserve", title: "Budget reserve", items: reserveItems))
    }

    return NetTotalBreakdown(groups: groups)
}

@MainActor func netTotalCardStatement(for transactions: [Transaction], isIncome: Bool?, with accounts: [Account], budgets: [Budget]? = nil, in selectedTimeRange: HomeTimeRange) -> Double {
    var runningTotal: Double = 0
    let calendar = Calendar.current
    let now = Date.now
    
    var creditCards: [Account] {
        accounts.filter { $0.accountType == .credit }
    }
    
    var debitCards: [Account] {
        accounts.filter { $0.accountType != .credit }
    }
    
    // guard instead if cards is optional
    if !accounts.isEmpty {
        let (start, end) = windowBounds(for: selectedTimeRange, offset: 0)

        for card in creditCards {
            var dueComponents = calendar.dateComponents([.year, .month, .day], from: now)
            dueComponents.day = card.dueDate // e.g., 25
            
            let due = calendar.date(from: dueComponents) ?? now
            
            if due >= start && due <= end {
                // 1. Calculate the exact Start Date (The last time this card closed)
                var closeComponents = calendar.dateComponents([.year, .month, .day], from: now)
                closeComponents.day = card.closingDate // e.g., 25
                
                let close = calendar.date(from: closeComponents) ?? now
                
                let startClose: Date
                let endClose: Date
                
                if close > now {
                    startClose = calendar.date(byAdding: .month, value: -2, to: close) ?? close
                    endClose = calendar.date(byAdding: .month, value: -1, to: close) ?? close
                } else {
                    startClose = calendar.date(byAdding: .month, value: -1, to: close) ?? close
                    endClose = close
                }
                
                // 2. Filter the transactions to ONLY include ones from this specific card
                
                let cardTransactions = typedTransactions(for: transactions.filter { $0.account == card }, income: isIncome)
                
                // 3. Calculate the total for this card and add it to our running tally
                runningTotal += calculateTotal(for: cardTransactions, start: startClose, end: endClose)
            }
        }
    }
    
    for card in debitCards {
        let debitTransactions = transactions.filter { $0.account == card }
        
        runningTotal += windowTotal(for: typedTransactions(for: debitTransactions, income: isIncome), in: selectedTimeRange, offset: 0)
    }
    
    let checkingTransactions = transactions.filter { $0.account == nil }

    runningTotal += windowTotal(for: typedTransactions(for: checkingTransactions, income: isIncome), in: selectedTimeRange, offset: 0)

    // Apply the budget reserve once, after all accounts are summed.
    if isIncome == nil { runningTotal -= budgetNetAdjustment(budgets: budgets) }

    return runningTotal
}

@MainActor func netTotalCardBalance(for transactions: [Transaction], isIncome: Bool?, with accounts: [Account], budgets: [Budget]? = nil, in selectedTimeRange: HomeTimeRange) -> Double {
    var runningTotal: Double = 0
    let calendar = Calendar.current
    let now = Date.now
    
    var creditCards: [Account] {
        accounts.filter { $0.accountType == .credit }
    }
    
    var debitCards: [Account] {
        accounts.filter { $0.accountType != .credit }
    }
    
    if !accounts.isEmpty {
        for card in creditCards {
            // 1. Calculate the exact Start Date (The last time this card closed)
            var closeComponents = calendar.dateComponents([.year, .month, .day], from: now)
            closeComponents.day = card.closingDate // e.g., 25
            
            var close = calendar.date(from: closeComponents) ?? now
            
            var dueComponents = calendar.dateComponents([.year, .month, .day], from: now)
            dueComponents.day = card.dueDate // e.g., 25
            
            let due = calendar.date(from: dueComponents) ?? now
            
            // If the 25th of this month hasn't happened yet, drop back to last month!
            if due >= now {
                close = calendar.date(byAdding: .month, value: -2, to: close) ?? close
            } else {
                close = calendar.date(byAdding: .month, value: -1, to: close) ?? close
            }
            
            // 2. Filter the transactions to ONLY include ones from this specific card
            let cardTransactions = transactions.filter { $0.account == card }
            
            // 3. Calculate the total for this card and add it to our running tally
            runningTotal += calculateTotal(for: cardTransactions, start: close, end: now)
        }
    }
    
    for card in debitCards {
        let debitTransactions = transactions.filter { $0.account == card }
        
        runningTotal += windowTotal(for: typedTransactions(for: debitTransactions, income: isIncome), in: selectedTimeRange, offset: 0)
    }
    
    let checkingTransactions = transactions.filter { $0.account == nil }

    runningTotal += windowTotal(for: typedTransactions(for: checkingTransactions, income: isIncome), in: selectedTimeRange, offset: 0)

    // Apply the budget reserve once, after all accounts are summed.
    if isIncome == nil { runningTotal -= budgetNetAdjustment(budgets: budgets) }

    return runningTotal
}

// MARK: - Credit Card Statement

/// A credit card's most recently **closed** statement: the cycle it covers, the
/// date payment is due, and the balance owed.
struct CreditCardBalances {
    /// First day included in the closed billing cycle.
    let periodStart: Date
    /// The closing date the statement was generated on (last day of the cycle).
    let closingDate: Date
    /// The day the statement balance must be paid.
    let dueDate: Date
    /// The balance owed for this statement. Positive means money is owed; a
    /// negative value means the card carries a credit (overpayment / refunds).
    let balanceDue: Double
    let totalBalance: Double
}

/// Builds the most recently closed statement for a single credit card from its
/// closing/due day-of-month settings and its own transactions.
///
/// The statement period is the billing cycle that ended on the closing date that
/// most recently passed; its balance is the net spending over that cycle — the
/// amount coming due on `dueDate`. Returns `nil` for non-credit accounts.
@MainActor
func creditCardStatement(for card: Account) -> CreditCardBalances? {
    guard card.accountType == .credit else { return nil }

    let calendar = Calendar.current
    let now = Date.now

    // The closing date that most recently passed defines the statement that just
    // closed. The cycle is the month ending on that date.
    let close = mostRecentDayOfMonth(card.closingDate ?? 1, onOrBefore: now, calendar: calendar)
    let previousClose = calendar.date(byAdding: .month, value: -1, to: close) ?? close
    let periodStart = calendar.startOfDay(
        for: calendar.date(byAdding: .day, value: 1, to: previousClose) ?? previousClose
    )

    // The statement is due on the first occurrence of the due day on/after it closed.
    let dueDate = firstDayOfMonth(card.dueDate ?? 1, onOrAfter: close, calendar: calendar)

    // Net the card's own transactions across the cycle. `calculateTotal` returns
    // income − expense, so spending is negative; flip the sign to get amount owed.
    let cardTransactions = (card.transactions ?? []).filter { $0.account == card }
    let net = calculateTotal(for: cardTransactions, start: periodStart, end: close.endOfDay)

    // Total balance = the closed statement's balance due PLUS everything charged
    // since it closed, up to today — i.e. the net from the cycle's start through
    // today, sign-flipped so owed is positive.
    let totalNet = calculateTotal(for: cardTransactions, start: periodStart, end: now.endOfDay)

    return CreditCardBalances(
        periodStart: periodStart,
        closingDate: close,
        dueDate: dueDate,
        balanceDue: -net,
        totalBalance: -totalNet
    )
}

/// The date in `base`'s month whose day-of-month is `day`, clamped to the number
/// of days in that month (so e.g. day 31 lands on Feb 28). Normalized to midnight.
nonisolated private func dateForDay(_ day: Int, inMonthOf base: Date, calendar: Calendar) -> Date {
    let range = calendar.range(of: .day, in: .month, for: base) ?? 1..<29
    let clamped = min(max(day, 1), range.upperBound - 1)
    var components = calendar.dateComponents([.year, .month], from: base)
    components.day = clamped
    return calendar.startOfDay(for: calendar.date(from: components) ?? base)
}

/// The most recent date whose day-of-month is `day`, occurring on or before `reference`.
nonisolated private func mostRecentDayOfMonth(_ day: Int, onOrBefore reference: Date, calendar: Calendar) -> Date {
    let thisMonth = dateForDay(day, inMonthOf: reference, calendar: calendar)
    if thisMonth <= reference { return thisMonth }

    // This month's day is still in the future — fall back to last month's.
    let lastMonth = calendar.date(byAdding: .month, value: -1, to: reference) ?? reference
    return dateForDay(day, inMonthOf: lastMonth, calendar: calendar)
}

/// The first date whose day-of-month is `day`, occurring on or after `reference`.
private func firstDayOfMonth(_ day: Int, onOrAfter reference: Date, calendar: Calendar) -> Date {
    let thisMonth = dateForDay(day, inMonthOf: reference, calendar: calendar)
    if thisMonth >= reference { return thisMonth }

    // This month's day already passed — roll forward to next month's.
    let nextMonth = calendar.date(byAdding: .month, value: 1, to: reference) ?? reference
    return dateForDay(day, inMonthOf: nextMonth, calendar: calendar)
}

func overallBudgetTotal(for overallBudget: OverallBudget, in transactions: [Transaction], by shiftAmount: Int) -> Double {
    // Spending only: the overall budget is a spend cap, so income (payroll especially)
    // is excluded — otherwise a paycheck would net the "spent" figure negative.
    let overallTransactions = transactions.filter { !$0.isIncome }
    let window = overallBudget.budgetWindow

    return budgetAmountSpent(window: window, shiftAmount: shiftAmount, transactions: overallTransactions)
}

func budgetTotal(for category: Category, in transactions: [Transaction], by shiftAmount: Int) -> Double {
    // Include income too so refunds/reimbursements net against spending (see budgetAmountSpent).
    let categoryTransactions = transactions.filter { transaction in
        transaction.category?.name == category.name
    }

    let window = category.budget?.budgetWindow ?? .monthly

    return budgetAmountSpent(window: window, shiftAmount: shiftAmount, transactions: categoryTransactions)
}

/// The net amount spent in a window: expenses add, income (refunds, reimbursements)
/// subtracts, so the total reflects money that actually left net of anything that came
/// back. Positive means net spending; it can go negative if income exceeds expenses.
func budgetAmountSpent(window: BudgetWindow, shiftAmount: Int, transactions: [Transaction]) -> Double {
    let calendar = Calendar.current
    let (start, end) = budgetWindowBounds(for: window, shiftAmount: shiftAmount)

    return transactions.reduce(0.0) { total, transaction in
        let multiplier = occurrenceCount(of: transaction, from: start, to: end, calendar: calendar)
        let amount = abs(transaction.amount) * Double(multiplier)
        return transaction.isIncome ? total - amount : total + amount
    }
}

// MARK: - Date Calculations
nonisolated func calculateNextDate(from date: Date, frequency: Recurrence) -> Date? {
    let calendar = Calendar.current
    switch frequency {
    case .daily:        return calendar.date(byAdding: .day, value: 1, to: date)
    case .weekly:       return calendar.date(byAdding: .day, value: 7, to: date)
    case .biweekly:     return calendar.date(byAdding: .day, value: 14, to: date)
    case .monthly:      return calendar.date(byAdding: .month, value: 1, to: date)
    case .quarterly:    return calendar.date(byAdding: .month, value: 3, to: date)
    case .semiAnnually: return calendar.date(byAdding: .month, value: 6, to: date)
    case .yearly:       return calendar.date(byAdding: .year, value: 1, to: date)
    case .none:         return nil
    }
}

// MARK: - Text Formatting
func amountTruncation(for num: Double, currencySymbol: String? = nil) -> String {
    let truncated: String
    
    let absoluteNum = abs(num)
    
    if absoluteNum >= 100 && absoluteNum < 1_000 {
        truncated = String(format: "%.0f", abs(num))
        
    } else if absoluteNum >= 1_000 && absoluteNum < 1_000_000 {
        truncated = String(format: "%.2fK", abs(num) / 1_000)
        
    } else if absoluteNum >= 1_000_000 && absoluteNum < 1_000_000_000 {
        truncated = String(format: "%.2fM", abs(num) / 1_000_000)
        
    } else {
        truncated = String(format: "%.2f", abs(num))
    }
    
    if let symbol = currencySymbol {
        return num < 0 ? "-\(symbol)\(truncated)" : "\(symbol)\(truncated)"
    }
    
    return num < 0 ? "-\(truncated)" : "\(truncated)"
}

func budgetWindowText(from window: BudgetWindow) -> String {
    switch window {
    case .daily:        return "today"
    case .weekly:       return "this week"
    case .biweekly:     return "this fortnight"
    case .monthly:      return "this month"
    case .quarterly:    return "this quarter"
    case .semiAnnually: return "this six-month period"
    case .yearly:       return "this year"
    }
}

func insightsWindowText(for window: HomeTimeRange) -> String {
    switch window {
    case .daily:     return "By Day"
    case .weekly:    return "By Week"
    case .payPeriod: return "By Pay Period"
    case .monthly:   return "By Month"
    case .yearly:    return "By Year"
    case .allTime:   return "All Time"
    }
}

@MainActor
func seedDefaultCategoriesIfNeeded() async {
    let context = SharedDatabase.shared.container.mainContext

    do {
        let initial = try context.fetch(FetchDescriptor<Category>())

        // One-time-per-device backfill: `role` is nil for categories created before
        // it existed, or synced down from a device that hasn't updated yet. Recover
        // the role of known pre-built categories by name so they don't get treated as
        // missing and re-seeded as duplicates below, and so role-specific behavior
        // (e.g. payroll detection) keeps working after the migration; anything else
        // becomes explicitly `.userCreated`. Cheap no-op on every launch after the
        // first, since roles stick once assigned.
        let roleByName = Dictionary(uniqueKeysWithValues: CategoryOptions.allCases.map { ($0.rawValue, $0.role) })
        for category in initial where category.role == nil {
            category.role = roleByName[category.name] ?? .userCreated
        }

        // Fast path: if this device already has the prebuilt categories there is
        // nothing else to do. Covers every launch after the first without any delay.
        if initial.filter({ $0.effectiveRole != .userCreated }).count >= 2 {
            try context.save()
            return
        }

        // No prebuilt categories locally yet. On a device that's new to the
        // user's iCloud account this is usually because CloudKit hasn't finished
        // its first import — the categories already exist remotely and are about
        // to sync down. Wait for that import (or a short timeout) before seeding
        // so we don't create duplicates of categories we're about to receive.
        await waitForInitialCloudKitImport()

        let allCategories = try context.fetch(FetchDescriptor<Category>())

        if !allCategories.contains(where: { $0.name == "Miscellaneous" }) {
            let miscCategory = Category(name: "Miscellaneous", hexColor: "#8E8E93", symbol: "📦", role: .miscellaneous)
            context.insert(miscCategory)
        }

        let preBuiltCount = allCategories.filter { $0.effectiveRole != .userCreated }.count

        if preBuiltCount < 2 {
            for option in CategoryOptions.allCases where option.rawValue != "Miscellaneous" {
                context.insert(option.preBuiltCategory)
            }
        }

        try context.save()
    } catch {
        log.error("Failed to seed database: \(error.localizedDescription)")
    }
}

/// Suspends until CloudKit reports that it has finished its first import on this
/// device, or until `timeout` elapses — whichever comes first. This lets seeding
/// logic wait for remote data to sync down before deciding it needs to create
/// defaults, avoiding duplicates. The timeout ensures the app still seeds when
/// there is no iCloud account or the device is offline and no import ever fires.
func waitForInitialCloudKitImport(timeout: Duration = .seconds(8)) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            let events = NotificationCenter.default.notifications(
                named: NSPersistentCloudKitContainer.eventChangedNotification
            )
            for await note in events {
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { continue }
                if event.type == .import && event.endDate != nil {
                    return
                }
            }
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
        }

        // Resume as soon as either the import finishes or the timeout fires,
        // then cancel the loser.
        await group.next()
        group.cancelAll()
    }
}

/// Indexes Transactions and active Budgets (category + freestanding) in Core Spotlight
/// so they're searchable from the system search field and Siri. Tapping a result runs the
/// matching Open intent. Safe to call on every launch — re-indexing refreshes any entities
/// whose displayed values changed.
@MainActor
func indexEntitiesForSpotlight() async {
    let context = SharedDatabase.shared.container.mainContext

    // Use a named index, not `.default()`. Apple documents the default index as
    // development-only; named indexes are what reliably surface in production
    // Spotlight. Each type is indexed independently so one failure can't abort
    // the others (the previous single do/catch silently dropped all three when
    // any one throw occurred).
    let index = CSSearchableIndex(name: "PennyEntities")

    do {
        let budgets = try context.fetch(FetchDescriptor<Budget>())
            .filter { $0.hasBudget }
            .map(BudgetEntity.init)
        try await index.indexAppEntities(budgets)
    } catch {
        log.error("Failed to index Budgets for Spotlight: \(error.localizedDescription)")
    }
}

// MARK: - Categorizing
// 1. Temporary Struct to match your JSON keys exactly
struct TransactionDTO: Codable {
    let name: String
    let amount: Double
    let date: String // JSON usually sends dates as Strings (ISO 8601)
    let account: String?
}

struct RawEmailDTO: Codable {
    let body: String
    let date: String
}

func findCategoryByRule(for dto: TransactionDTO, categories: [Category]) -> Category? {
    for category in categories {
        guard let rules = category.rules else { continue }
        
        for rule in rules {
            if let keyword = rule.inputNotes, !keyword.isEmpty {
                if dto.name.localizedCaseInsensitiveContains(keyword) {
                    return category // Found a strict rule match!
                }
            }
        }
    }
    return nil
}

func autoCategorize(text: String, categories: [String]) async -> String? {
    let session = LanguageModelSession()
    let categoryList = categories.joined(separator: ", ")
    
    let prompt = """
    You are a strict financial categorization engine.
    Merchant: "\(text)"
    Allowed Categories: [\(categoryList)]
    
    Task: Select the single most accurate category for the merchant from the array above.
    Rule 1: Output ONLY the exact category name. No quotes, no periods, no introductory text.
    Rule 2: If the merchant is completely unrecognizable, output "Miscellaneous", but try to only use "Muscellaneous" as a last resort.
    """
    do {
        let response = try await session.respond(to: prompt)
        
        let cleanResponse = response.content.lowercased()
        // Match the response back to a known category
        return categories.first { categoryName in
            cleanResponse.contains(categoryName.lowercased())
        }
    } catch {
        return nil
    }
}

func extractDataWithAI(from emailText: String, date: String) async -> TransactionDTO? {
    let session = LanguageModelSession()
    
    let prompt = """
    You are a strict data extraction engine. Read the following transaction email and extract the merchant name, the exact purchase amount, and the account used (e.g., Sapphire, Amex, United, Debit).
    
    Email text:
    "\(emailText)"
    
    Task: Output ONLY a valid JSON object with exact keys: "name" (String), "amount" (Number, no quotes or currency symbols), and "account" (String). Do not include markdown formatting, backticks, or any conversational text.
    """
    
    do {
        let response = try await session.respond(to: prompt)
        
        // Clean the AI's output in case it includes markdown code blocks (```json)
        let cleanJSON = response.content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let jsonData = cleanJSON.data(using: .utf8) else { return nil }
        
        // The AI only returns name/amount/card — date comes from the email metadata
        struct PartialDTO: Codable {
            let name: String
            let amount: Double
            let account: String? // Optional to match TransactionDTO
        }

        let partial = try JSONDecoder().decode(PartialDTO.self, from: jsonData)

        // Inject the date from the raw email to produce a complete TransactionDTO
        return TransactionDTO(
            name: partial.name,
            amount: partial.amount,
            date: date,
            account: partial.account // nil if AI didn't find a card
        )
        
    } catch {
        return nil
    }
}
