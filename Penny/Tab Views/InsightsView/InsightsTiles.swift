//
//  InsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 7/16/26.
//

import Charts
import OrderedCollections
import SwiftData
import SwiftUI

enum InsightsOptions: String, CaseIterable, Codable, Identifiable {
    case spending
    case categories
    case cashFlow
    case recurring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spending:
            return "Spending"
        case .categories:
            return "Categories"
        case .cashFlow:
            return "Cash Flow"
        case .recurring:
            return "Recurring"
        }
    }

    var symbol: String {
        switch self {
        case .spending:
            return "chart.line.uptrend.xyaxis"
        case .categories:
            return "chart.pie"
        case .cashFlow:
            return "arrow.down.left.arrow.up.right"
        case .recurring:
            return "arrow.trianglehead.2.clockwise"
        }
    }

    /// Accent for the tile's badge, headline currency glyph, and background
    /// gradient — and for the matching detail screen's chart card.
    var color: Color {
        switch self {
        case .spending:
            return .blue
        case .categories:
            return .purple
        case .cashFlow:
            return .teal
        case .recurring:
            return .orange
        }
    }
}

struct InsightsTiles: View {
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]

    @Namespace private var namespace

    /// Selected navigation target, driven by tile taps. Item-based navigation
    /// (Button sets state → `navigationDestination(item:)`) rather than
    /// `NavigationLink(value:)`, because the Insights grid is now pushed as its
    /// own screen — a type-based `navigationDestination(for:)` declared inside a
    /// pushed view doesn't reliably register, so the tiles wouldn't navigate and
    /// the zoom transition wouldn't resolve. This matches the pattern in `BudgetView`.
    @State private var selectedOption: InsightsOptions?

    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(InsightsOptions.allCases) { option in
                Button {
                    selectedOption = option
                } label: {
                    InsightsCell(
                        option: option,
                        transactions: transactions,
                        categories: categories,
                        timeRange: selectedTimeRange
                    )
                    .matchedTransitionSource(id: option.title, in: namespace)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .navigationDestination(item: $selectedOption) { option in
            Group {
                switch option {
                case .spending:     SpendingView()
                case .categories:   CategoryInsightsView()
                case .cashFlow:     CashFlowInsightsView()
                case .recurring:    RecurringInsightsView()
                }
            }
            .navigationTransition(.zoom(sourceID: option.title, in: namespace))
        }
    }
}

// MARK: - Cell

/// Routes each insight type to its own tile. Every tile computes its data once
/// per render and hands the headline figure, chart, and footer to the shared
/// `InsightTileCard` so all four read as one family.
private struct InsightsCell: View {
    let option: InsightsOptions
    let transactions: [Transaction]
    let categories: [Category]
    let timeRange: HomeTimeRange

    private var window: (start: Date, end: Date) {
        // Single source of truth for HomeTimeRange windowing (handles the pay period,
        // all-time, and the calendar windows identically to the net-total path).
        windowBounds(for: timeRange, offset: 0)
    }

    var body: some View {
        switch option {
        case .spending:
            SpendingTile(transactions: transactions, timeRange: timeRange, window: window)
        case .categories:
            CategoriesTile(transactions: transactions, categories: categories, timeRange: timeRange, window: window)
        case .cashFlow:
            CashFlowTile(transactions: transactions, categories: categories, timeRange: timeRange, window: window)
        case .recurring:
            RecurringTile(transactions: transactions)
        }
    }
}

/// "spent this month" / "saved this pay period" — the phrase after a tile's
/// underlined caption.
private func windowPhrase(for timeRange: HomeTimeRange) -> String {
    switch timeRange {
    case .payPeriod: "this pay period"
    case .allTime:   "all time"
    default:         timeRange.rawValue.lowercased()
    }
}

/// The shared tile chrome, styled after the budget cells: a tinted symbol badge
/// and title, a large headline amount with a tinted currency glyph and an
/// underlined caption, the chart, then an optional footer — all on glass over a
/// top-down accent gradient.
private struct InsightTileCard<ChartContent: View, Footer: View>: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.colorScheme) private var colorScheme

    let option: InsightsOptions
    let badge: String
    let amount: Double
    let caption: String
    let detail: String
    @ViewBuilder let chart: ChartContent
    @ViewBuilder let footer: Footer

    private var budgetButtonColor: Color {
        colorScheme == .light ? .black : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: option.symbol)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(option.color.gradient))
                    .shadow(color: option.color, radius: 5)

                Text(option.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(badge)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect()

                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(currencySymbol)
                        .font(.title3.bold())
                        .foregroundStyle(option.color.mix(with: budgetButtonColor, by: 0.4))

                    Text(amountTruncation(for: amount))
                        .font(.title.bold())
                        .contentTransition(.numericText())
                }

                HStack(spacing: 0) {
                    Text(caption)
                        .underline()
                    Text(" \(detail)")
                }
                .font(.footnote)
                .lineLimit(1)
            }

            chart
                .frame(maxWidth: .infinity)
                .frame(height: 140)

            footer
        }
        .padding(18)
        .foregroundStyle(option.color.mix(with: budgetButtonColor, by: 0.7))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: [option.color.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

/// A small glass legend chip: colored dot, label, and a truncated amount.
private struct TileChip: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    let color: Color
    let title: String
    let amount: Double

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.gradient)
                .frame(width: 7, height: 7)

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
}

/// The muted placeholder a tile's chart area shows when there's nothing to plot.
private struct TileEmptyChart: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Spending

private struct SpendingTile: View {
    let transactions: [Transaction]
    let timeRange: HomeTimeRange
    let window: (start: Date, end: Date)

    var body: some View {
        let points = spendingChartPoints(
            transactions: transactions,
            timeRange: timeRange,
            window: window,
            filterIsIncomeContribute: nil
        )
        let income = abs(calculateTotal(for: typedTransactions(for: transactions, income: true),
                                        start: window.start, end: window.end))
        let expenses = abs(calculateTotal(for: typedTransactions(for: transactions, income: false),
                                          start: window.start, end: window.end))

        InsightTileCard(
            option: .spending,
            badge: timeRange.withOffset,
            amount: expenses,
            caption: "spent",
            detail: windowPhrase(for: timeRange)
        ) {
            if points.isEmpty {
                TileEmptyChart(symbol: "chart.line.flattrend.xyaxis", message: "No activity yet")
            } else {
                MiniPointChart(points: points)
            }
        } footer: {
            HStack(spacing: 8) {
                TileChip(color: Color(.systemGreen), title: "In", amount: income)
                TileChip(color: Color(.systemRed), title: "Out", amount: expenses)
                Spacer(minLength: 0)
            }
        }
    }
}

/// A compact version of the Trends point/line chart for the insights grid. Draws
/// the same income/expense series as `SpendingChartView` (sharing its
/// `spendingChartPoints` aggregation) as smooth lines over soft gradient fills,
/// with the latest point of each series called out — no axes or legend, so it
/// reads as a sparkline inside the tile.
private struct MiniPointChart: View {
    let points: [SpendingChartPoint]

    /// The last point of each series, emphasized as the "where it ended" marker.
    private var latestPoints: [SpendingChartPoint] {
        txType.allCases.compactMap { type in points.last { $0.type == type } }
    }

    private var maxAmount: Double {
        points.map(\.amount).max() ?? 0
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.id) { point in
                AreaMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount),
                    series: .value("Type", point.type.rawValue),
                    stacking: .unstacked
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [point.color.opacity(0.35), point.color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount),
                    series: .value("Type", point.type.rawValue)
                )
                .foregroundStyle(point.color)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }

            ForEach(latestPoints, id: \.id) { point in
                PointMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount)
                )
                .symbol {
                    Circle()
                        .fill(point.color)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: point.color, radius: 4)
                }
            }
        }
        // A little headroom so the peak and its marker don't clip the top edge.
        .chartYScale(domain: 0...max(1, maxAmount * 1.15))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - Categories

private struct CategoriesTile: View {
    let transactions: [Transaction]
    let categories: [Category]
    let timeRange: HomeTimeRange
    let window: (start: Date, end: Date)

    var body: some View {
        let slices = categorySpendData(transactions: transactions, categories: categories, window: window)
        let total = slices.reduce(0) { $0 + $1.amount }

        InsightTileCard(
            option: .categories,
            badge: timeRange.withOffset,
            amount: total,
            caption: "spent",
            detail: slices.count == 1 ? "in 1 category" : "across \(slices.count) categories"
        ) {
            if slices.isEmpty {
                TileEmptyChart(symbol: "chart.pie", message: "No categorized spending")
            } else {
                MiniPieChart(slices: slices, total: total)
            }
        } footer: {
            EmptyView()
        }
    }
}

/// A compact donut for the insights grid. Draws the same per-category slices as
/// `CategoryPieChartView` (sharing its `categorySpendData` aggregation) with the
/// biggest category's glyph in the center, beside a key of the top three
/// categories and their share bars.
private struct MiniPieChart: View {
    let slices: [CategorySlice]
    let total: Double

    var body: some View {
        HStack(spacing: 16) {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Amount", slice.amount),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .foregroundStyle(slice.color.gradient)
                .cornerRadius(4)
                .shadow(color: slice.color, radius: 3)
            }
            .chartLegend(.hidden)
            .overlay {
                if let top = slices.first {
                    Text(top.symbol)
                        .font(.title2)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            // Slices are already sorted largest-first.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slices.prefix(3)) { slice in
                    let share = total > 0 ? slice.amount / total : 0

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(slice.symbol)
                                .font(.caption)

                            Text(slice.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Text(share.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption2.bold())
                                .monospacedDigit()
                        }

                        ShareBar(share: share, color: slice.color, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Cash Flow

private struct CashFlowTile: View {
    let transactions: [Transaction]
    let categories: [Category]
    let timeRange: HomeTimeRange
    let window: (start: Date, end: Date)

    var body: some View {
        // Totals come from the diagram's own links so the tile can never disagree
        // with its ribbons. The balancing "From Savings" inflow is left out of
        // "In" so an overspent window reports its real shortfall instead of zero.
        let data = cashFlowSankeyData(transactions: transactions, categories: categories, window: window)
        let totalIn = data.links.filter { $0.target == "cashflow" && $0.source != "deficit" }.reduce(0.0) { $0 + $1.value }
        let totalOut = data.links.filter { $0.source == "cashflow" }.reduce(0.0) { $0 + $1.value }
        let net = totalIn - totalOut

        InsightTileCard(
            option: .cashFlow,
            badge: timeRange.withOffset,
            amount: net,
            caption: net < 0 ? "overspent" : "saved",
            detail: windowPhrase(for: timeRange)
        ) {
            if data.nodes.isEmpty {
                TileEmptyChart(symbol: "arrow.left.arrow.right", message: "No cash flow yet")
            } else {
                // Reuses the full `SankeyDiagram`, unlabeled with slimmer bars so
                // the ribbons read as a small flow inside the tile.
                SankeyDiagram(
                    nodes: data.nodes,
                    links: data.links,
                    showLabels: false,
                    nodeWidth: 8,
                    vGap: 3
                )
            }
        } footer: {
            HStack(spacing: 8) {
                TileChip(color: Color(.systemGreen), title: "In", amount: totalIn)
                TileChip(color: Color(.systemRed), title: "Out", amount: totalOut)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Recurring

private struct RecurringTile: View {
    let transactions: [Transaction]

    var body: some View {
        let items = recurringItems(from: transactions)
        let now = Date.now

        // Still-active recurring expenses, normalized to a monthly cost.
        let active = items.filter { item in
            !item.isIncome && (item.transaction.endDate.map { $0 >= now } ?? true)
        }
        let monthly = active.reduce(0.0) { $0 + $1.monthlyAmount }

        // Items are already soonest-first; skip any whose series has ended.
        let next = items.first { item in
            guard let date = item.transaction.nextOccurrence else { return false }
            return item.transaction.endDate.map { date <= $0 } ?? true
        }

        InsightTileCard(
            option: .recurring,
            badge: now.formatted(.dateTime.month(.wide)),
            amount: monthly,
            caption: "per month",
            detail: active.count == 1 ? "in 1 recurring bill" : "in \(active.count) recurring bills"
        ) {
            if items.isEmpty {
                TileEmptyChart(symbol: "repeat", message: "No recurring transactions")
            } else {
                MiniRecurringChart(items: items, tint: InsightsOptions.recurring.color)
            }
        } footer: {
            if let next, let date = next.transaction.nextOccurrence {
                HStack(spacing: 6) {
                    Text("Next")
                        .font(.caption.bold())

                    Text(next.label)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect()
            }
        }
    }
}

// MARK: - Shared rows

/// A thin capsule filled to `share` (0...1) in `color` over a faint track.
struct ShareBar: View {
    let share: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        Capsule()
            .fill(color.opacity(0.18))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(height, geo.size.width * min(max(share, 0), 1)))
                }
            }
    }
}

/// One line of a breakdown list on the Categories and Cash Flow screens: an
/// emoji badge (or a color dot when there's no glyph), the name with a share bar
/// beneath it, then the share and the amount — on the same tinted glass as before.
struct InsightBreakdownRow: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    let symbol: String?
    let name: String
    let color: Color
    let share: Double
    let amount: Double

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbol {
                    Text(symbol)
                        .font(.title3)
                } else {
                    Circle()
                        .fill(color.gradient)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 38, height: 38)
            .background(Circle().fill(color.opacity(0.5).gradient))
            .shadow(color: color, radius: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(name)
                        .lineLimit(1)

                    Spacer()

                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Text(amountTruncation(for: amount, currencySymbol: currencySymbol))
                        .font(.subheadline.bold())
                        .contentTransition(.numericText())
                }

                ShareBar(share: share, color: color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(color.opacity(0.1)))
    }
}
