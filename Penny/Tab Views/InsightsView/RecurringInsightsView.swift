//
//  RecurringInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 7/19/26.
//

import SwiftData
import SwiftUI

// MARK: - Recurring model

/// One recurring transaction, wrapped with the display attributes the calendar
/// needs (name, glyph, color, sign, grouping key) so the aggregation is a single
/// source of truth for the full `RecurringInsightsView`, its calendar, and the
/// compact `MiniRecurringChart` in the insights grid.
struct RecurringItem: Identifiable {
    let transaction: Transaction

    var id: UUID { transaction.id }

    /// The user's note wins, falling back to the tagged category/fund name.
    var name: String {
        if !transaction.notes.isEmpty { return transaction.notes }
        return transaction.category?.name ?? transaction.budget?.name ?? "Recurring"
    }

    var symbol: String {
        transaction.category?.symbol ?? transaction.budget?.symbol ?? (transaction.isIncome ? "💵" : "🔁")
    }

    /// The category/fund color, or a green/red fallback keyed on the sign so an
    /// uncategorized recurring transaction still reads as income vs. expense.
    var color: Color {
        if let category = transaction.category { return category.color }
        if let fund = transaction.budget { return fund.color }
        return transaction.isIncome ? Color(.systemGreen) : Color(.systemRed)
    }

    /// Glyph + name, used as a display label where a single line is needed.
    var label: String { "\(symbol) \(name)" }

    /// Groups occurrences into one calendar dot per distinct category/fund, so two
    /// transactions in the same category on the same day show a single dot while
    /// different categories each get their own.
    var dotKey: String {
        if let category = transaction.category { return "c-\(category.name)" }
        if let fund = transaction.budget { return "f-\(fund.name)" }
        return transaction.isIncome ? "income" : "expense"
    }

    var isIncome: Bool { transaction.isIncome }
    var recurrence: Recurrence { transaction.recurrence }

    /// This recurring transaction normalized to a per-month cost, so a $1,200/yr
    /// policy and a $100/mo bill compare on the same axis.
    var monthlyAmount: Double {
        let amount = abs(transaction.amount)
        switch transaction.recurrence {
        case .none:         return 0
        case .daily:        return amount * 365.0 / 12.0
        case .weekly:       return amount * 52.0 / 12.0
        case .biweekly:     return amount * 26.0 / 12.0
        case .monthly:      return amount
        case .quarterly:    return amount / 3.0
        case .semiAnnually: return amount / 6.0
        case .yearly:       return amount / 12.0
        }
    }
}

/// The recurring transactions (recurrence != none) wrapped as `RecurringItem`s,
/// soonest next-occurrence first so every consumer shares one ordering.
@MainActor
func recurringItems(from transactions: [Transaction]) -> [RecurringItem] {
    transactions
        .filter { $0.recurrence != .none }
        .map(RecurringItem.init)
        .sorted { ($0.transaction.nextOccurrence ?? .distantFuture) < ($1.transaction.nextOccurrence ?? .distantFuture) }
}

/// Every occurrence date of `transaction` within [from, to], expanding its
/// recurrence and honoring its end date. Midnight-aligned so day comparisons in
/// the calendar line up. Mirrors `occurrenceCount`'s expansion so the charts and
/// the windowed totals can never drift apart.
func recurringOccurrenceDates(of transaction: Transaction, from: Date, to: Date, calendar: Calendar = .current) -> [Date] {
    let start = calendar.startOfDay(for: from)
    let end = calendar.startOfDay(for: to)
    var next = calendar.startOfDay(for: transaction.date)
    let limit = transaction.endDate.map { min(end, calendar.startOfDay(for: $0)) } ?? end

    if transaction.recurrence == .none {
        return (next >= start && next <= limit) ? [next] : []
    }

    // Fast-forward to the first occurrence on or after the window start.
    while next < start {
        guard let future = calculateNextDate(from: next, frequency: transaction.recurrence) else { return [] }
        next = calendar.startOfDay(for: future)
    }

    var dates: [Date] = []
    while next <= limit {
        dates.append(next)
        guard let future = calculateNextDate(from: next, frequency: transaction.recurrence) else { break }
        next = calendar.startOfDay(for: future)
    }
    return dates
}

// MARK: - Recurring Insights

struct RecurringInsightsView: View {
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    @Namespace private var namespace

    @State private var windowTimeRange: HomeTimeRange = .monthly
    @State private var dateOffset: Int = 0

    @State private var showAddTransaction: Bool = false
    @State private var editingTransaction: Transaction?

    /// The calendar tile the user tapped to filter the list below. Day start for
    /// day-granular ranges, month start for the yearly (month-tile) range.
    @State private var selectedDate: Date?
    
    @State private var showNetSheet = false
    @State private var showInSheet = false
    @State private var showOutSheet = false


    private var items: [RecurringItem] {
        recurringItems(from: transactions)
    }

    /// The recurring transactions themselves, feeding the list below the calendar.
    private var recurringTransactions: [Transaction] {
        transactions.filter { $0.recurrence != .none }
    }

    /// The [start, end] the current selection filters to: the selected day, or the
    /// selected month when the yearly range is showing month tiles.
    private var selectionInterval: (start: Date, end: Date)? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        if windowTimeRange == .yearly {
            let end = (calendar.date(byAdding: .month, value: 1, to: start) ?? start).endOfDay
            return (start, end)
        }
        return (start, start.endOfDay)
    }

    /// The recurring transactions shown below the calendar — all of them, or just
    /// those with an occurrence on the selected day/month.
    private var displayedTransactions: [Transaction] {
        guard let interval = selectionInterval else { return recurringTransactions }
        let calendar = Calendar.current
        return recurringTransactions.filter { occurs($0, from: interval.start, to: interval.end, calendar: calendar) }
    }

    private var window: (start: Date, end: Date) {
        windowBounds(for: windowTimeRange, offset: dateOffset)
    }

    /// The recurring income (or expense) that actually occurs in the selected
    /// window, expanding each transaction's recurrence — so the chips track the
    /// period the calendar is showing rather than a fixed monthly rate.
    private func windowedRecurringTotal(income: Bool) -> Double {
        let calendar = Calendar.current
        return items
            .filter { $0.isIncome == income }
            .reduce(0.0) { sum, item in
                let occurrences = occurrenceCount(of: item.transaction, from: window.start, to: window.end, calendar: calendar)
                return sum + abs(item.transaction.amount) * Double(occurrences)
            }
    }

    private var windowIncome: Double { windowedRecurringTotal(income: true) }
    private var windowExpense: Double { windowedRecurringTotal(income: false) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Recurring Transactions",
                    systemImage: "repeat",
                    description: Text("Transactions set to repeat will show up here.")
                )
                .frame(height: 300)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    summary
                }
                .scrollClipDisabled()

                RecurringCalendarChart(
                    items: items,
                    window: window,
                    timeRange: windowTimeRange,
                    selectedDate: $selectedDate
                )
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                    .padding(.horizontal, 12)
                    .animation(.smooth, value: dateOffset)
                    .animation(.smooth, value: windowTimeRange)

                if selectedDate != nil {
                    selectionChip
                }
            }

            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: displayedTransactions,
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: true,
                hideUpcoming: false,
                hideAllTx: true,
                searchString: ""
            )
        }
        // A selected day only makes sense within the visible window, so drop it
        // whenever the window changes.
        .onChange(of: dateOffset) { selectedDate = nil }
        .onChange(of: windowTimeRange) { selectedDate = nil }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Recurring")
        .navigationSubtitle(windowTimeRange.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Time Range", selection: $windowTimeRange) {
                        ForEach(HomeTimeRange.allCases.filter { $0 != .allTime }) { range in
                            Text(range.withOffset).tag(range)
                        }
                    }
                } label: {
                    Label("Time Range", systemImage: "calendar")
                }
            }

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .matchedTransitionSource(id: "addTransaction", in: namespace)
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous Period", systemImage: "chevron.left") {
                    dateOffset -= 1
                }

                Spacer()

                Button {
                    dateOffset = 0
                } label: {
                    Text(dateDescription())
                        .contentTransition(.numericText())
                }
                .animation(.bouncy, value: dateOffset)

                Spacer()

                Button("Next Period", systemImage: "chevron.right") {
                    dateOffset += 1
                }
            }
        }
        .onAppear {
            windowTimeRange = selectedTimeRange
        }
        .sheet(isPresented: $showAddTransaction) {
            NavigationStack {
                SingleTransactionView(initialEditMode: true, transaction: nil, category: nil, budget: nil)
            }
            .navigationTransition(.zoom(sourceID: "addTransaction", in: namespace))
        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, budget: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
        .sheet(isPresented: $showNetSheet) {
            NavigationStack {
                Text(windowIncome-windowExpense, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showInSheet) {
            NavigationStack {
                Text(windowIncome, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showOutSheet) {
            NavigationStack {
                Text(windowExpense, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
    }

    /// Recurring in/out/net for the selected window, so the "how much" is answered
    /// alongside the calendar's "when".
    private var summary: some View {
        HStack {
            Button {
                showNetSheet = true
            } label: {
                summaryChip(title: "NET:", amount: windowIncome - windowExpense)
            }
            .buttonStyle(.plain)
            
            Button {
                showInSheet = true
            } label: {
                summaryChip(title: "INC:", amount: windowIncome)
            }
            .buttonStyle(.plain)
            
            Button {
                showOutSheet = true
            } label: {
                summaryChip(title: "EXP:", amount: windowExpense)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// A chip naming the selected day/month with a clear button, shown only while
    /// the list below is filtered to a selection.
    @ViewBuilder
    private var selectionChip: some View {
        if let selectedDate {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(Color.accentColor)
                
                Text(selectionLabel(for: selectedDate))
                    .font(.subheadline.bold())

                Button {
                    withAnimation(.snappy) { self.selectedDate = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .tint(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect()
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    private func selectionLabel(for date: Date) -> String {
        windowTimeRange == .yearly
            ? date.formatted(.dateTime.month().year())
            : date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    private func summaryChip(title: String, amount: Double) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption)
            Text(amountTruncation(for: amount, currencySymbol: currencySymbol))
                .font(.caption.bold())
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect()
    }

    private func dateDescription() -> String {
        let dates = window

        if windowTimeRange == .monthly {
            return dates.start.formatted(.dateTime.month().year())
        } else if windowTimeRange == .yearly {
            return dates.start.formatted(.dateTime.year())
        } else {
            return "\(dates.start.formatted(.dateTime.month().day().year())) - \(dates.end.formatted(.dateTime.month().day().year()))"
        }
    }
}

// MARK: - Calendar

/// A dot for one distinct category/fund that recurs within a tile's date range.
private struct CalendarDot: Identifiable {
    let id: String
    let color: Color
}

/// A calendar of when recurring transactions occur across the selected window.
/// Day-granular windows (daily/weekly/monthly/pay period) render weekday-aligned
/// day tiles; the yearly window renders twelve month tiles instead, since 365 day
/// tiles wouldn't be legible. Each tile shows a colored dot per distinct category,
/// so a day with rent + a subscription reads as two dots of different colors.
private struct RecurringCalendarChart: View {
    let items: [RecurringItem]
    let window: (start: Date, end: Date)
    let timeRange: HomeTimeRange
    @Binding var selectedDate: Date?

    private var calendar: Calendar { Calendar.current }

    private let dayColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    private let monthColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        Group {
            if timeRange == .yearly {
                monthGrid
            } else {
                dayGrid
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.snappy, value: selectedDate)
    }

    // MARK: Day-granular grid

    /// Every day in the window, midnight-aligned.
    private var days: [Date] {
        let start = calendar.startOfDay(for: window.start)
        let end = calendar.startOfDay(for: window.end)
        let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return (0..<max(1, count)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Empty cells before the first day so it lands under its weekday column.
    private var leadingBlanks: Int {
        guard let first = days.first else { return 0 }
        let weekday = calendar.component(.weekday, from: first)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// Weekday headers rotated to honor the user's `firstWeekday`.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var dayGrid: some View {
        LazyVGrid(columns: dayColumns, spacing: 6) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            ForEach(0..<leadingBlanks, id: \.self) { _ in
                Color.clear.frame(height: 48)
            }

            ForEach(days, id: \.self) { day in
                dayTile(day)
            }
        }
    }

    private func dayTile(_ day: Date) -> some View {
        let start = calendar.startOfDay(for: day)
        let dots = dots(from: start, to: start.endOfDay)
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        return VStack(spacing: 3) {
            Text(day.formatted(.dateTime.day()))
                .font(.caption)
                .fontWeight(isToday ? .bold : .regular)

            dotRow(dots)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .glassEffect(.regular.tint(isToday ? Color(.systemGray4) : .clear), in: RoundedRectangle(cornerRadius: 8))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        .contentShape(.rect)
        .onTapGesture { toggleSelection(start) }
    }

    // MARK: Month-granular grid (yearly)

    /// The twelve months of the window's year.
    private var months: [Date] {
        let start = calendar.startOfDay(for: window.start)
        let components = calendar.dateComponents([.year], from: start)
        let yearStart = calendar.date(from: components) ?? start
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: yearStart) }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: monthColumns, spacing: 8) {
            ForEach(months, id: \.self) { month in
                monthTile(month)
            }
        }
    }

    private func monthTile(_ month: Date) -> some View {
        let start = calendar.startOfDay(for: month)
        let end = (calendar.date(byAdding: .month, value: 1, to: start) ?? start).endOfDay
        let dots = dots(from: start, to: end)
        let isCurrent = calendar.isDate(month, equalTo: .now, toGranularity: .month)
        let isSelected = selectedDate.map { calendar.isDate($0, equalTo: month, toGranularity: .month) } ?? false

        return VStack(spacing: 4) {
            Text(month.formatted(.dateTime.month(.abbreviated)))
                .font(.caption)
                .fontWeight(isCurrent ? .bold : .regular)

            dotRow(dots)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : (isCurrent ? 1.5 : 0))
        )
        .contentShape(.rect)
        .onTapGesture { toggleSelection(start) }
    }

    /// Selects the tapped tile, or clears the selection when tapping the tile that
    /// is already selected.
    private func toggleSelection(_ date: Date) {
        if let selectedDate, calendar.isDate(selectedDate, inSameDayAs: date) {
            self.selectedDate = nil
        } else {
            selectedDate = date
        }
    }

    // MARK: Dots

    /// A capped row of category dots, with a "+N" overflow marker so a busy tile
    /// stays legible.
    @ViewBuilder
    private func dotRow(_ dots: [CalendarDot]) -> some View {
        HStack(spacing: 2) {
            ForEach(dots.prefix(4)) { dot in
                Circle()
                    .fill(dot.color)
                    .frame(width: 5, height: 5)
            }
            if dots.count > 4 {
                Text("+\(dots.count - 4)")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 6)
    }

    /// One dot per distinct category/fund that recurs in [start, end], preserving
    /// the soonest-first item ordering.
    private func dots(from start: Date, to end: Date) -> [CalendarDot] {
        var colorByKey: [String: Color] = [:]
        var order: [String] = []
        for item in items where occurrenceCount(of: item.transaction, from: start, to: end, calendar: calendar) > 0 {
            if colorByKey[item.dotKey] == nil {
                colorByKey[item.dotKey] = item.color
                order.append(item.dotKey)
            }
        }
        return order.map { CalendarDot(id: $0, color: colorByKey[$0] ?? .accentColor) }
    }
}

// MARK: - Mini chart for the insights grid

/// A compact, decoration-only preview of the recurring calendar for the insights
/// grid cell — the current month as a tiny weekday-aligned dot grid, stripped of
/// day numbers and chrome so it reads as a miniature of the full calendar.
struct MiniRecurringChart: View {
    let transactions: [Transaction]

    private var calendar: Calendar { Calendar.current }

    private var items: [RecurringItem] {
        recurringItems(from: transactions)
    }

    private var firstOfMonth: Date {
        let components = calendar.dateComponents([.year, .month], from: .now)
        return calendar.date(from: components) ?? .now
    }

    private var days: [Date] {
        let count = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: firstOfMonth) }
    }

    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// The first recurring category's color for a day, or nil when nothing recurs.
    private func dotColor(for day: Date) -> Color? {
        let start = calendar.startOfDay(for: day)
        let end = start.endOfDay
        return items.first { occurrenceCount(of: $0.transaction, from: start, to: end, calendar: calendar) > 0 }?.color
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
            ForEach(0..<leadingBlanks, id: \.self) { _ in
                Color.clear.frame(height: 9)
            }

            ForEach(days, id: \.self) { day in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.12))
                    .frame(height: 9)
                    .overlay {
                        if let color = dotColor(for: day) {
                            Circle()
                                .fill(color)
                                .frame(width: 4, height: 4)
                        }
                    }
            }
        }
        .frame(height: 70)
    }
}
