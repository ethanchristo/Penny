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
    
    var color: Color {
        switch self {
        case .spending:
            return .gray
        case .categories:
            return .gray
        case .cashFlow:
            return .gray
        case .recurring:
            return .gray
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

private struct InsightsCell: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.colorScheme) private var colorScheme
    
    let option: InsightsOptions
    let transactions: [Transaction]
    let categories: [Category]
    let timeRange: HomeTimeRange
    
    private var budgetButtonColor: Color {
        colorScheme == .light ? .black : .white
    }
    
    private var subtitle: String? {
        switch option {
        case .spending:
            return nil
        case .categories: return nil
        case .cashFlow: return nil
        case .recurring: return nil
        }
    }
    
    var body: some View {
        VStack {
            VStack {
                HStack {
                    Image(systemName: option.symbol)
                        .foregroundStyle(.secondary)
                    
                    Text(option.title)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                
                .font(.headline)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                
                if let subtitle {
                    HStack {
                        Text(subtitle)
                            .font(.caption)
                            .padding(4)
                            .glassEffect()
                        
                        Spacer()
                    }
                }

            }
//            .padding(.bottom, 30)
            Spacer(minLength: 20)
            
            Group {
                switch option {
                case .spending:
                    MiniPointChart(
                        transactions: transactions,
                        timeRange: timeRange,
                        window: dateWindow()
                    )
                case .categories:
                    MiniPieChart(
                        transactions: transactions,
                        categories: categories,
                        window: dateWindow()
                    )
                case .cashFlow:
                    MiniSankey(
                        transactions: transactions,
                        categories: categories,
                        window: dateWindow()
                    )
                case .recurring:
                    MiniRecurringChart(transactions: transactions)
                }
            }
            .frame(height: 200)
        }
        .padding()
        .foregroundStyle(option.color.mix(with: budgetButtonColor, by: 0.7))
        .glassEffect(in: RoundedRectangle(cornerRadius: 26))
//        .background {
//            RoundedRectangle(cornerRadius: 26)
//            .fill(
//                LinearGradient(
//                    colors: [option.color, .clear],
//                    startPoint: .top,
//                    endPoint: .bottom
//                )
//            )
//        }
    }
    
    private func dateWindow() -> (start: Date, end: Date) {
        // Single source of truth for HomeTimeRange windowing (handles the pay period,
        // all-time, and the calendar windows identically to the net-total path).
        windowBounds(for: timeRange, offset: 0)
    }
    
    private func average() -> Double {
        let total = netTotalType(for: transactions, budgets: [], in: timeRange, offset: 0, type: .timeRange)
        return transactions.isEmpty ? 0 : total / Double(transactions.count)
    }
}

/// A compact, decoration-only version of the Trends point/line chart for the
/// insights grid cells. Draws the same income/expense points and connecting
/// lines as `SpendingChartView` (sharing its `spendingChartPoints` aggregation),
/// but strips every bit of chrome — no axes, grid, legend, or glass container —
/// so it reads as a small sparkline inside the cell's own glass background.
private struct MiniPointChart: View {
    let transactions: [Transaction]
    let timeRange: HomeTimeRange
    let window: (start: Date, end: Date)

    private var points: [SpendingChartPoint] {
        spendingChartPoints(
            transactions: transactions,
            timeRange: timeRange,
            window: window,
            filterIsIncomeContribute: nil
        )
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.id) { point in
                LineMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount),
                    series: .value("Type", point.type.rawValue)
                )
                .foregroundStyle(point.color)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", point.label),
                    y: .value("Amount", point.amount)
                )
                .foregroundStyle(point.color)
                .symbolSize(18)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(maxHeight: .infinity)
    }
}

/// A compact, decoration-only donut for the insights grid cell. Draws the same
/// per-category spending slices as `CategoryPieChartView` (sharing its
/// `categorySpendData` aggregation), but strips the legend and center total so
/// it reads as a small ring inside the cell's own glass background.
private struct MiniPieChart: View {
    let transactions: [Transaction]
    let categories: [Category]
    let window: (start: Date, end: Date)

    private var slices: [CategorySlice] {
        categorySpendData(transactions: transactions, categories: categories, window: window)
    }

    var body: some View {
        HStack(spacing: 12) {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Amount", slice.amount),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.5
                )
                .foregroundStyle(slice.color.gradient)
                .cornerRadius(4)
            }
            .chartLegend(.hidden)
            .aspectRatio(1, contentMode: .fit)

            // Compact key listing the top 3 categories by spend (slices are
            // already sorted largest-first).
            VStack(alignment: .leading, spacing: 4) {
                ForEach(slices.prefix(3)) { slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(slice.color.gradient)
                            .frame(width: 8, height: 8)

                        Text(slice.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A compact, decoration-only cash-flow Sankey for the insights grid cell.
/// Reuses the full `SankeyDiagram` and its `cashFlowSankeyData`, but hides labels
/// and uses thinner bars so the ribbons read as a small flow inside the cell.
private struct MiniSankey: View {
    let transactions: [Transaction]
    let categories: [Category]
    let window: (start: Date, end: Date)

    var body: some View {
        let data = cashFlowSankeyData(transactions: transactions, categories: categories, window: window)
        SankeyDiagram(
            nodes: data.nodes,
            links: data.links,
            showLabels: false,
            nodeWidth: 6,
            vGap: 3
        )
        .frame(maxHeight: .infinity)
    }
}
