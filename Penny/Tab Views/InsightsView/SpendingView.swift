//
//  SpendingView.swift
//  Penny
//
//  Created by Ethan Christo on 6/19/26.
//

import Charts
import SwiftData
import SwiftUI

enum txType: String, CaseIterable {
    case income = "income"
    case expense = "expense"

    var title: String {
        switch self {
        case .income: "Income"
        case .expense: "Expenses"
        }
    }
}

/// One aggregated point on the spending point/line chart: an income or expense
/// total for a single bucket (day, weekday, or month depending on the range).
/// File-scoped so the full `SpendingChartView` and the compact `MiniPointChart`
/// share a single source of truth for both the data shape and the aggregation.
struct SpendingChartPoint: Hashable {
    let label: String
    let amount: Double
    let type: txType

    /// Stable across amount changes so a point slides to its new position
    /// (and the line re-bends) instead of being replaced.
    var id: String { "\(label)-\(type.rawValue)" }

    var color: Color { type == .income ? Color(.systemGreen) : Color(.systemRed) }
}

/// Aggregates transactions into income/expense totals per bucket for the given
/// time range and window. When `filterIsIncomeContribute` is non-nil, only that
/// side is emitted; otherwise both income and expense points are produced.
/// Zero-value buckets are omitted so the line only connects real activity.
@MainActor
func spendingChartPoints(
    transactions: [Transaction],
    timeRange: HomeTimeRange,
    window: (start: Date, end: Date),
    filterIsIncomeContribute: txType?
) -> [SpendingChartPoint] {
    let calendar = Calendar.current
    var points: [SpendingChartPoint] = []

    let incomeTransactions = typedTransactions(for: transactions, income: true)
    let expensesTransactions = typedTransactions(for: transactions, income: false)

    // Appends the income/expense point(s) for one bucket, honoring the type filter.
    func appendPoints(label: String, start: Date, end: Date) {
        if let filterIsIncomeContribute {
            let source = filterIsIncomeContribute == .income ? incomeTransactions : expensesTransactions
            let total = abs(calculateTotal(for: source, start: start, end: end))
            points.append(SpendingChartPoint(label: label, amount: total, type: filterIsIncomeContribute))
        } else {
            let incomeTotal = abs(calculateTotal(for: incomeTransactions, start: start, end: end))
            let expensesTotal = abs(calculateTotal(for: expensesTransactions, start: start, end: end))

            if incomeTotal != 0.0 {
                points.append(SpendingChartPoint(label: label, amount: incomeTotal, type: .income))
            }
            if expensesTotal != 0.0 {
                points.append(SpendingChartPoint(label: label, amount: expensesTotal, type: .expense))
            }
        }
    }

    switch timeRange {
    case .weekly:
        // Breakdown by Day of Week (Mon, Tue...)
        for dayOffset in 0...6 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: window.start) else { continue }
            let label = dayDate.formatted(.dateTime.weekday(.abbreviated))
            appendPoints(label: label, start: dayDate.startOfDay, end: dayDate.endOfDay)
        }
    case .monthly, .payPeriod:
        // Breakdown by Day (1, 2, 3...)
        let numberOfDays = calendar.dateComponents([.day], from: window.start, to: window.end).day ?? 0
        for dayOffset in 0...max(0, numberOfDays) {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: window.start) else { continue }
            let label = dayDate.formatted(.dateTime.day())
            appendPoints(label: label, start: dayDate.startOfDay, end: dayDate.endOfDay)
        }
    case .yearly:
        // Breakdown by Month (Jan, Feb, Mar...)
        for month in 0..<12 {
            guard let monthDate = calendar.date(byAdding: .month, value: month, to: window.start) else { continue }
            let label = monthDate.formatted(.dateTime.month(.abbreviated))
            appendPoints(label: label, start: monthDate.startOfMonth, end: monthDate.endOfMonth)
        }
    default:
        break
    }

    return points
}

struct SpendingView: View {
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly
    @AppStorage("default_checking_name") private var defaultCheckingName: String = "Checking"


    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Account.name) private var accounts: [Account]

    @Namespace private var namespace

    @State private var windowTimeRange: HomeTimeRange = .monthly
    @State private var dateOffset: Int = 0

    @State private var filterAccount: Account? = nil
    @State private var filterIsIncomeContribute: txType? = nil

    @State private var showAddTransaction: Bool = false
    @State private var editingTransaction: Transaction?
    
    private let range = -50...0
    
    private var filterIsIncome: Bool? {
        switch filterIsIncomeContribute {
        case .income: true
        case .expense: false
        case nil: nil
        }
    }
    
    private var filteredTransactions: [Transaction] {
        filterTransactions()
    }
    
    private var window: (start: Date, end: Date) {
        dateWindow()
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ScrollView(.horizontal, showsIndicators: false) {
                SpendingOverview(
                    transactions: transactions,
                    timeRange: windowTimeRange,
                    offset: dateOffset,
                    window: window
                )
            }
            .scrollClipDisabled()
            .animation(.bouncy, value: dateOffset)
            
            SpendingChartView(
                transactions: filteredTransactions,
                filterIsIncomeContribute: filterIsIncomeContribute,
                timeRange: windowTimeRange,
                window: window
            )

            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: filteredTransactions,
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: false,
                hideUpcoming: true,
                hideAllTx: false,
                searchString: "",
                filterAccount: filterAccount,
                filterCategory: nil,
                filterIsIncome: filterIsIncome
            )
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Spending")
        .navigationSubtitle(windowTimeRange.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        Picker("Time Range", selection: $windowTimeRange) {
                            ForEach(HomeTimeRange.allCases
                                .filter { $0 != .daily }
                                .filter { $0 != .allTime }
                            ) { range in
                                Text(range.withOffset).tag(range)
                            }
                        }
                    } label: {
                        Label("Time Range", systemImage: "calendar")
                        Text(selectedTimeRange.withOffset)
                    }
                    
                    Menu {
                        Picker("By Type", selection: $filterIsIncomeContribute) {
                            Text("All").tag(nil as txType?)
                            ForEach(txType.allCases, id: \.self) { type in
                                Text(type.title).tag(type as txType?)
                            }
                        }
                    } label: {
                        Label("By Type", systemImage: "tray")
                        Text(filterIsIncomeContribute?.title ?? "All")
                            .font(.caption)
                    }
                    
                    Menu {
                        Picker("All", selection: $filterAccount) {
                            Text("All").tag(nil as Account?)
                        }
                        
                        Picker("Accounts", selection: $filterAccount) {
                            Text(defaultCheckingName).tag(nil as Account?)

                            ForEach(accounts.filter { $0.accountType != .credit }) {
                                Text($0.name).tag($0 as Account?)
                            }
                        }
                        .labelsVisibility(.visible)
                            
                        Divider()
                            
                        Picker("Cards", selection: $filterAccount) {
                            ForEach(accounts.filter { $0.accountType == .credit }) { card in
                                Text(card.name).tag(card as Account?)
                            }
                        }
                        .labelsVisibility(.visible)
                    } label: {
                        Label("By Account", systemImage: "creditcard")
                        Text(filterAccount?.name ?? "All")
                            .font(.caption)
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
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
                .disabled(dateOffset == 0)
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
    }
    
    private func dateDescription() -> String {
        let dates = dateWindow()
        
        if windowTimeRange == .monthly {
            return dates.start.formatted(.dateTime.month().year())
        } else if windowTimeRange == .yearly {
            return dates.start.formatted(.dateTime.year())
        } else {
            return "\(dates.start.formatted(.dateTime.month().day().year())) - \(dates.end.formatted(.dateTime.month().day().year()))"
        }
    }
    
    private func dateWindow() -> (start: Date, end: Date) {
        // Single source of truth for HomeTimeRange windowing (handles the pay period,
        // all-time, and the calendar windows identically to the net-total path).
        windowBounds(for: windowTimeRange, offset: dateOffset)
    }
    
    private func filterTransactions() -> [Transaction] {
        let windowDates = window
        let start = windowDates.start
        let end = windowDates.end

        // Funds are excluded entirely from Trends: only non-fund income/expense
        // transactions feed the stats, charts, and list.
        let transactionsOfType = typedTransactions(for: transactions, income: filterIsIncome)

        let sorted = transactionsOfType.sorted { $0.date > $1.date }

        let calendar = Calendar.current
        return sorted.filter { occurs($0, from: start, to: end, calendar: calendar) }
    }
}

struct SpendingOverview: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @State private var showTotalSheet = false
    @State private var showAvgSheet = false
    
    let transactions: [Transaction]
    let timeRange: HomeTimeRange
    let offset: Int
    let window: (start: Date, end: Date)

    private var total: Double {
        // Pass an empty budgets array so no reserve is applied — Trends
        // excludes freestanding budgets entirely.
        netTotalType(for: transactions, budgets: [], in: timeRange, offset: offset, type: .timeRange)
    }

    private var average: Double {
        transactions.isEmpty ? 0 : total / Double(transactions.count)
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Button {
                showTotalSheet = true
            } label: {
                HStack(spacing: 3) {
                    Text("NET:")
                        .font(.caption)
                    
                    Text(amountTruncation(for: total, currencySymbol: currencySymbol))
                        .font(.caption.bold())
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect()
            }
            
            Button {
                showAvgSheet = true
            } label: {
                HStack(spacing: 3) {
                    Text("AVG:")
                        .font(.caption)
                    
                    Text(amountTruncation(for: average, currencySymbol: currencySymbol))
                        .font(.caption.bold())
                        .contentTransition(.numericText())

                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect()

            }
        }
        .tint(.primary)
        .padding(.horizontal)
        
        .sheet(isPresented: $showTotalSheet) {
            NavigationStack {
                Text(total, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showAvgSheet) {
            NavigationStack {
                Text(average, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Average")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
    }
}

struct SpendingChartView: View {
    let transactions: [Transaction]
    let filterIsIncomeContribute: txType?
    let timeRange: HomeTimeRange
    let window: (start: Date, end: Date)

    /// How much of the connecting line is revealed, left to right (0...1). The
    /// line is masked to this fraction so it appears to draw itself on.
    @State private var lineReveal: CGFloat = 0
    /// Opacity of the connecting line. Faded to zero while the points slide to
    /// new positions, so the line never visibly re-bends mid-move.
    @State private var lineOpacity: Double = 0
    /// The points the line is currently drawn through. Deliberately lags
    /// `pointData`: it's only swapped to the new points once the line has faded
    /// out, so a freshly-changed line never flashes on screen fully drawn.
    @State private var lineData: [ChartPoint] = []

    /// Alias to the file-scoped model so this view's existing animation code
    /// (which refers to `ChartPoint` throughout) is untouched while the data
    /// itself comes from the shared `spendingChartPoints` aggregation.
    private typealias ChartPoint = SpendingChartPoint

    private var pointData: [ChartPoint] {
        pointChartData()
    }

    var body: some View {
        pointChart
    }

    // The points and the connecting line live in two stacked charts that share
    // identical data, scales, and axes (so they line up perfectly). Splitting
    // them lets the line fade/draw on its own while the points just slide.
    private var pointChart: some View {
        ZStack {
            lineLayer
            pointLayer
        }
        .modifier(ChartContainer(timeRange: timeRange, filterIsIncomeContribute: filterIsIncomeContribute))
        .onAppear { drawLineOn() }
        .onChange(of: pointData) { _, _ in animateLineForDataChange() }
    }

    /// The points only. These slide to their new positions whenever the data
    /// changes — the behaviour we want to keep.
    private var pointLayer: some View {
        // Compute once so `ForEach` and the `.animation(value:)` comparison share the
        // same result instead of each re-running the aggregation.
        let points = pointData
        return Chart {
            ForEach(points, id: \.id) { point in
                PointMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount)
                )
                // Keep zero-value points in the data so the categorical x-axis
                // domain stays identical to the line layer (which uses the full
                // data set) — otherwise the two stacked charts fall out of
                // alignment. Just hide the mark instead of removing it.
                .foregroundStyle(pointColor(point: point))
                .opacity(point.amount == 0 ? 0 : 1)
            }
        }
        .modifier(ChartXAxisStyle(timeRange: timeRange))
        .animation(.smooth, value: points)
    }

    /// The connecting line only, masked to `lineReveal` (left-to-right draw-on)
    /// and dimmed by `lineOpacity` while the points are in motion.
    private var lineLayer: some View {
        Chart {
            ForEach(lineData, id: \.id) { point in
                LineMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount),
                    series: .value("Type", point.type.rawValue)
                )
                .foregroundStyle(pointColor(point: point))
                .interpolationMethod(.catmullRom)
            }
        }
        .modifier(ChartXAxisStyle(timeRange: timeRange))
        .opacity(lineOpacity)
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .frame(width: geo.size.width * lineReveal)
            }
        }
    }

    /// Draw the line on from left to right (used on first appearance).
    private func drawLineOn() {
        lineData = pointData
        lineReveal = 0
        lineOpacity = 1
        withAnimation(.easeInOut(duration: 0.6)) {
            lineReveal = 1
        }
    }

    /// On a data change: fade the old line out while the points slide, then
    /// swap in the new points (while invisible) and draw the line back on from
    /// left to right.
    private func animateLineForDataChange() {
        withAnimation(.easeInOut(duration: 0.4)) {
            lineOpacity = 0
        } completion: {
            lineData = pointData
            lineReveal = 0
            withAnimation(.easeInOut(duration: 0.6)) {
                lineOpacity = 1
                lineReveal = 1
            }
        }
    }

    private func pointChartData() -> [ChartPoint] {
        spendingChartPoints(
            transactions: transactions,
            timeRange: timeRange,
            window: window,
            filterIsIncomeContribute: filterIsIncomeContribute
        )
    }

    private func pointColor(point: ChartPoint) -> Color {
        point.color
    }
}

/// Shared x-axis configuration for the insights charts. Kept separate from
/// `ChartContainer` so it can be applied directly to each `Chart` — the layered
/// point/line charts both need identical axes to stay aligned.
private struct ChartXAxisStyle: ViewModifier {
    let timeRange: HomeTimeRange

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                if timeRange == .monthly {
                    AxisMarks { AxisGridLine() }
                } else {
                    AxisMarks {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
            }
    }
}

/// Shared styling for the insights charts: sizing and glass background.
private struct ChartContainer: ViewModifier {
    let timeRange: HomeTimeRange
    let filterIsIncomeContribute: txType?

    func body(content: Content) -> some View {
        content
            .padding(15)
            .frame(height: 250)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
            // Pin the label to the card's top-leading padding band so it sits
            // clear of the y-axis value labels and the rounded glass corner,
            // rather than inside the plot area as `.chartOverlay` would place it.
            .overlay(alignment: .topLeading) {
                Label(filterIsIncomeContribute?.title ?? "All", systemImage: "tray.full")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .glassEffect(.regular)
                    .padding(.top, 12)
                    .padding(.leading, 12)
            }
            .padding(.horizontal, 12)
    }
}
