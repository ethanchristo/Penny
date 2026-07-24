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
            transactions.filter { $0.isIncome && $0.fund == nil }
        } else {
            // Include both non-fund income and fund contributions (both are `isIncome`).
            transactions.filter { $0.isIncome }
        }
    } else if income == false {
        if !fund {
            transactions.filter { !$0.isIncome && $0.fund == nil }
        } else {
            // Include both non-fund expenses and fund uses (both are `!isIncome`).
            transactions.filter { !$0.isIncome }
        }
    } else {
        if !fund {
            transactions
                .filter { $0.fund == nil }
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
/// Windowed sum of the non-fund `transactions` (income adds, expense subtracts).
/// ALL fund transactions are skipped here — funds are reconciled in aggregate by
/// `fundNetAdjustment()` so their impact lands on the net total exactly once,
/// independent of the selected window and never on the income/expense breakdowns.
nonisolated func calculateTotal(for transactions: [Transaction], start: Date, end: Date) -> Double {

    let savingsTotalEnabled = UserDefaults.group.object(forKey: "savings_total") as? Bool ?? false
    let calendar = Calendar.current

    let transactionTotal = transactions.reduce(0.0) { total, transaction in
        // Skip only NORMAL savings transactions when the savings total is off.
        if transaction.fund == nil, transaction.account?.accountType == .savings, !savingsTotalEnabled {
            return total
        }

        // Every fund transaction — contributions and uses, pre-allocate or not — is
        // reconciled in aggregate by fundNetAdjustment(), so none of them move the
        // windowed running total here.
        if transaction.fund != nil { return total }

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

/// The aggregate fund reserve applied to the net total. Every fund's own transactions
/// are skipped in `calculateTotal`; this reconciles them so money set aside affects the
/// net total. Per fund the amount reserved (subtracted by the caller) is:
///   • pre-allocate: max(goal, used) — the full goal is removed from the net total, and
///     only spending *over* the goal eats further (goal + max(0, used − goal)).
///   • non-pre-allocate: max(contributed, used) — contributions are set aside and a use
///     only bites once it exceeds what was contributed.
/// Subtracted from the *net total only* (`isIncome == nil`), once, never on the
/// income/expense breakdowns.
/// Pure, nonisolated core: the aggregate reserve for an explicit set of funds. Being
/// nonisolated lets it run on a background `ModelActor` as well as on the main thread.
nonisolated func fundReserveTotal(for funds: [Fund]) -> Double {
    funds.reduce(0.0) { sum, fund in
        let reserved = fund.preAllocate
            ? max(fund.goal, fund.used)
            : max(fund.contributed, fund.used)
        return sum + reserved
    }
}

/// Main-thread convenience: prefers the caller's already-loaded funds (the app passes
/// its `@Query` funds) to avoid a fetch on every render, falling back to fetching the
/// shared container when none are supplied (the charts call this without funds in hand).
@MainActor func fundNetAdjustment(funds: [Fund]? = nil) -> Double {
    let allFunds = funds ?? (try? SharedDatabase.shared.container.mainContext.fetch(FetchDescriptor<Fund>())) ?? []
    return fundReserveTotal(for: allFunds)
}

@MainActor func netTotalType(for transactions: [Transaction], use accounts: [Account]? = nil, funds: [Fund]? = nil, isIncome: Bool? = nil, in selectedTimeRange: HomeTimeRange, offset: Int, type: CreditCardBalanceType) -> Double {

    if type == .statement {
        return netTotalCardStatement(for: transactions, isIncome: isIncome, with: accounts ?? [], funds: funds, in: selectedTimeRange)
    } else if type == .balance {
        return netTotalCardBalance(for: transactions, isIncome: isIncome, with: accounts ?? [], funds: funds, in: selectedTimeRange)
    } else {
        return netTotalAmount(for: transactions, isIncome: isIncome, funds: funds, in: selectedTimeRange, offset: offset)
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
        .filter { $0.category?.name.caseInsensitiveCompare("Payroll") == .orderedSame }
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

@MainActor func netTotalAmount(for transactions: [Transaction], isIncome: Bool?, funds: [Fund]? = nil, in selectedTimeRange: HomeTimeRange, offset: Int) -> Double {
    let filtered = typedTransactions(for: transactions, income: isIncome)
    let total = windowTotal(for: filtered, in: selectedTimeRange, offset: offset)

    // Apply the fund adjustment only to the aggregate net total (isIncome == nil),
    // never to the income/expense breakdowns.
    return isIncome == nil ? total - fundNetAdjustment(funds: funds) : total
}

/// The all-time net total (or income/expense breakdown) for the home tab, decoupled
/// from the selected time range. Sums everything through today; when the
/// `net_total_include_upcoming` toggle is on, RECURRING transactions are additionally
/// counted through the next predicted payday, so bills/income due before the next
/// paycheck are reflected. Future one-time transactions are never included. The fund
/// reserve is applied once, to the net total only.
/// Nonisolated so it can run on a background `ModelActor` (see `StatsCalculator`) as
/// well as the main thread. `funds` is required — the caller passes the funds fetched
/// from the same context as `transactions`, so no context-crossing fetch is needed.
nonisolated func netTotalAllTime(for transactions: [Transaction], isIncome: Bool?, funds: [Fund]) -> Double {
    let includeUpcoming = UserDefaults.group.object(forKey: "net_total_include_upcoming") as? Bool ?? true
    let filtered = typedTransactions(for: transactions, income: isIncome)

    let now = Date().endOfDay
    // Recurring transactions extend to the next payday when the toggle is on.
    let recurringEnd = includeUpcoming ? payPeriodBounds(offset: 1).start.endOfDay : now

    let nonRecurring = filtered.filter { $0.recurrence == .none }
    let recurring = filtered.filter { $0.recurrence != .none }

    var total = calculateTotal(for: nonRecurring, start: .distantPast, end: now)
    total += calculateTotal(for: recurring, start: .distantPast, end: recurringEnd)

    return isIncome == nil ? total - fundReserveTotal(for: funds) : total
}

/// Amount owed on a single credit card, from its own transactions and its
/// closing-day setting. `due` is the last closed statement's balance (owed on the
/// due date); `total` is the full outstanding balance (all-time net — the seeded
/// opening balance makes this the real current balance). Both positive when owed.
/// Nonisolated so it can run on the background `StatsCalculator`.
nonisolated func creditCardOwed(for card: Account, transactions: [Transaction]) -> (due: Double, total: Double) {
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
    // prefix mirrors `SimpleFINImporter.openingBalanceID`.) It stays in `total`,
    // since it is genuinely part of the outstanding balance.
    let statementTxns = cardTransactions.filter {
        !($0.externalID?.hasPrefix("simplefin-opening-balance-") ?? false)
    }

    // `calculateTotal` returns income − expense, so spending is negative; flip the
    // sign so an amount owed reads positive.
    let due = -calculateTotal(for: statementTxns, start: periodStart, end: close.endOfDay)
    let total = -calculateTotal(for: cardTransactions, start: .distantPast, end: now.endOfDay)
    return (due, total)
}

/// Total of fund *use* (spending) transactions in `transactions`. These are real
/// outflows already reflected in a SimpleFIN balance, but `calculateTotal` excludes
/// all fund transactions (funds are reconciled once via `fundReserveTotal`). Adding
/// this back to a SimpleFIN balance converts it to the fund-excluded basis the
/// reserve expects, so fund spending isn't counted twice (once in the live balance,
/// once in the reserve). Fund *contributions* are treated as virtual earmarks of
/// existing money — not new deposits — so they are deliberately NOT added back,
/// matching how the transaction-derived total already treats them.
nonisolated func fundUseTotal(in transactions: [Transaction]) -> Double {
    transactions.reduce(0.0) { sum, txn in
        (txn.fund != nil && !txn.isIncome) ? sum + abs(txn.amount) : sum
    }
}

/// The credit-card-aware home/widget/Siri net total: assets (checking + debit +
/// savings-if-enabled) − credit-card debt − fund reserve, all-time and optionally
/// extended to the next payday for recurring transactions.
///
/// Credit cards count per the `net_total_credit_mode` setting — `.balance` subtracts
/// each card's full outstanding balance, `.statement` subtracts only its last closed
/// statement (amount due). When SimpleFIN has reported a live balance for an account
/// it is the source of truth (checking included); otherwise the figure is derived
/// from that account's transactions. Nonisolated so it runs on `StatsCalculator`.
nonisolated func netTotalAggregate(for transactions: [Transaction], funds: [Fund]) -> Double {
    let defaults = UserDefaults.group
    let mode = CreditCardBalanceType(rawValue: defaults.string(forKey: "net_total_credit_mode") ?? "") ?? .balance
    let includeUpcoming = defaults.object(forKey: "net_total_include_upcoming") as? Bool ?? true
    let includeSavings = defaults.object(forKey: "savings_total") as? Bool ?? false
    // Read the SimpleFIN balances straight from the App Group (keys mirror
    // `SimpleFINConfig`) so this stays usable from the widget target, which doesn't
    // link the SimpleFIN client.
    let balances = defaults.dictionary(forKey: "simplefin_account_balances") as? [String: Double] ?? [:]
    let checkingID = defaults.string(forKey: "simplefin_checking_id")

    let now = Date().endOfDay

    let creditTxns = transactions.filter { $0.account?.accountType == .credit }
    let nonCreditTxns = transactions.filter { $0.account?.accountType != .credit }

    // MARK: Assets — prefer SimpleFIN's live balance per account, else the
    // transaction-derived all-time total (which already honors the savings toggle).
    var assets: Double = 0

    // Primary checking (account == nil) maps to the designated SimpleFIN checkingID.
    let checkingTxns = nonCreditTxns.filter { $0.account == nil }
    if let checkingID, let balance = balances[checkingID] {
        // Add back fund spending already baked into the live balance so it isn't
        // double-counted against the fund reserve below.
        assets += balance + fundUseTotal(in: checkingTxns)
    } else {
        assets += calculateTotal(for: checkingTxns, start: .distantPast, end: now)
    }

    // Each mapped non-credit account (savings, additional checking/debit).
    for account in Set(nonCreditTxns.compactMap({ $0.account })) {
        // Honor the savings toggle even on the SimpleFIN-balance path (the
        // transaction path already excludes savings via `calculateTotal`).
        if account.accountType == .savings, !includeSavings { continue }
        let accountTxns = nonCreditTxns.filter { $0.account == account }
        if let externalID = account.externalID, let balance = balances[externalID] {
            assets += balance + fundUseTotal(in: accountTxns)
        } else {
            assets += calculateTotal(for: accountTxns, start: .distantPast, end: now)
        }
    }

    // MARK: Credit-card debt.
    var creditOwed: Double = 0
    for card in Set(creditTxns.compactMap({ $0.account })) {
        switch mode {
        case .statement:
            creditOwed += creditCardOwed(for: card, transactions: creditTxns).due
        default: // .balance
            if let externalID = card.externalID, let balance = balances[externalID] {
                // Fund spending charged to this card is already in its live balance;
                // remove it here so the reserve doesn't count it a second time.
                let cardTxns = creditTxns.filter { $0.account == card }
                creditOwed += balance - fundUseTotal(in: cardTxns)
            } else {
                creditOwed += creditCardOwed(for: card, transactions: creditTxns).total
            }
        }
    }

    // MARK: Upcoming recurring — only FUTURE occurrences before the next payday.
    // Past occurrences are already reflected in the balances/totals above.
    var upcoming: Double = 0
    if includeUpcoming {
        let recurringEnd = payPeriodBounds(offset: 1).start.endOfDay
        if recurringEnd > now {
            let recurring = transactions.filter { $0.recurrence != .none }
            let throughEnd = calculateTotal(for: recurring, start: .distantPast, end: recurringEnd)
            let throughNow = calculateTotal(for: recurring, start: .distantPast, end: now)
            upcoming = throughEnd - throughNow
        }
    }

    return assets - creditOwed + upcoming - fundReserveTotal(for: funds)
}

@MainActor func netTotalCardStatement(for transactions: [Transaction], isIncome: Bool?, with accounts: [Account], funds: [Fund]? = nil, in selectedTimeRange: HomeTimeRange) -> Double {
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

    // Apply the fund adjustment once, after all accounts are summed.
    if isIncome == nil { runningTotal -= fundNetAdjustment(funds: funds) }

    return runningTotal
}

@MainActor func netTotalCardBalance(for transactions: [Transaction], isIncome: Bool?, with accounts: [Account], funds: [Fund]? = nil, in selectedTimeRange: HomeTimeRange) -> Double {
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

    // Apply the fund adjustment once, after all accounts are summed.
    if isIncome == nil { runningTotal -= fundNetAdjustment(funds: funds) }

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

//func accountBalances(for account: Account?) -> AccountBalances? {
//    guard account?.accountType != .credit else { return nil }
//    
//}

/// The date in `base`'s month whose day-of-month is `day`, clamped to the number
/// of days in that month (so e.g. day 31 lands on Feb 28). Normalized to midnight.
private func dateForDay(_ day: Int, inMonthOf base: Date, calendar: Calendar) -> Date {
    let range = calendar.range(of: .day, in: .month, for: base) ?? 1..<29
    let clamped = min(max(day, 1), range.upperBound - 1)
    var components = calendar.dateComponents([.year, .month], from: base)
    components.day = clamped
    return calendar.startOfDay(for: calendar.date(from: components) ?? base)
}

/// The most recent date whose day-of-month is `day`, occurring on or before `reference`.
private func mostRecentDayOfMonth(_ day: Int, onOrBefore reference: Date, calendar: Calendar) -> Date {
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
    let overallTransactions = transactions .filter { !$0.isIncome }
    let window = overallBudget.budgetWindow
    
    return budgetAmountSpent(window: window, shiftAmount: shiftAmount, transactions: overallTransactions)
}

func budgetTotal(for category: Category, in transactions: [Transaction], by shiftAmount: Int) -> Double {
    let categoryTransactions = transactions.filter { transaction in
        !transaction.isIncome && transaction.category?.name == category.name
    }

    let window = category.budget?.budgetWindow ?? .monthly

    return budgetAmountSpent(window: window, shiftAmount: shiftAmount, transactions: categoryTransactions)
}

func budgetAmountSpent(window: BudgetWindow, shiftAmount: Int, transactions: [Transaction]) -> Double {
    let calendar = Calendar.current
    let (start, end) = budgetWindowBounds(for: window, shiftAmount: shiftAmount)

    let transactionSum = transactions.reduce(0.0) { total, transaction in
        let multiplier = occurrenceCount(of: transaction, from: start, to: end, calendar: calendar)
        let amount = abs(transaction.amount) * Double(multiplier)
        return transaction.isIncome ? total + amount : total - amount
    }

    return abs(transactionSum)
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
        // Fast path: if this device already has the prebuilt categories there is
        // nothing to do. Covers every launch after the first without any delay.
        let initial = try context.fetch(FetchDescriptor<Category>())
        if initial.filter({ $0.isPreBuilt }).count >= 2 {
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
            let miscCategory = Category(name: "Miscellaneous", hexColor: "#8E8E93", symbol: "📦", isPreBuilt: true)
            context.insert(miscCategory)
        }

        let preBuiltCount = allCategories.filter { $0.isPreBuilt }.count

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

/// Indexes Funds, Transactions and enabled Budgets in Core Spotlight so they're
/// searchable from the system search field and Siri. Tapping a result runs the
/// matching Open intent. Safe to call on every launch — re-indexing refreshes
/// any entities whose displayed values changed.
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
        let funds = try context.fetch(FetchDescriptor<Fund>()).map(FundEntity.init)
        try await index.indexAppEntities(funds)
    } catch {
        log.error("Failed to index Funds for Spotlight: \(error.localizedDescription)")
    }

//    do {
//        let transactions = try context.fetch(FetchDescriptor<Transaction>()).map(TransactionEntity.init)
//        try await index.indexAppEntities(transactions)
//    } catch {
//        log.error("Failed to index Transactions for Spotlight: \(error.localizedDescription)")
//    }

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
