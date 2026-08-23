//
//  InsightWidgets.swift
//  NetTotalWidget
//
//  Four small widgets — one per Insights card (Spending, Categories, Cash Flow,
//  Recurring). Each mirrors the compact chart shown in the app's insights grid,
//  using the shared aggregations in InsightsChartsCore.swift. All data is reduced
//  to Sendable values in the provider so SwiftData models stay on the main actor.
//

import Charts
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Shared loading

/// Fetches the transactions, categories, and the user's selected Insights time
/// range/window from the shared store — the same inputs the in-app cells use.
@MainActor
private func loadInsightsInputs() -> (transactions: [Transaction], categories: [Category], timeRange: HomeTimeRange, window: (start: Date, end: Date)) {
    let context = SharedDatabase.shared.container.mainContext
    let transactions = (try? context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\Transaction.date, order: .reverse)]))) ?? []
    let categories = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\Category.name)]))) ?? []

    let defaults = UserDefaults(suiteName: SharedDatabase.appGroup)
    let timeRange: HomeTimeRange = {
        if let raw = defaults?.string(forKey: "Home Time Range"), let range = HomeTimeRange(rawValue: raw) { return range }
        return .monthly
    }()

    return (transactions, categories, timeRange, windowBounds(for: timeRange, offset: 0))
}

private func nextRefresh() -> Date {
    Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
}

/// Header shown atop every insight widget: the card's glyph and title.
private struct InsightHeader: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            Spacer()
        }
        .font(.headline)
        .fontDesign(.rounded)
    }
}

// MARK: - Spending

struct SpendingInsightEntry: TimelineEntry {
    let date: Date
    let points: [SpendingChartPoint]
}

struct SpendingInsightProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendingInsightEntry {
        SpendingInsightEntry(date: Date(), points: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendingInsightEntry) -> Void) {
        Task { @MainActor in completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendingInsightEntry>) -> Void) {
        Task { @MainActor in
            completion(Timeline(entries: [makeEntry()], policy: .after(nextRefresh())))
        }
    }

    @MainActor
    private func makeEntry() -> SpendingInsightEntry {
        let inputs = loadInsightsInputs()
        let points = spendingChartPoints(
            transactions: inputs.transactions,
            timeRange: inputs.timeRange,
            window: inputs.window,
            filterIsIncomeContribute: nil
        )
        return SpendingInsightEntry(date: Date(), points: points)
    }
}

struct SpendingInsightView: View {
    var entry: SpendingInsightEntry

    var body: some View {
        VStack(alignment: .leading) {
            InsightHeader(symbol: "chart.line.uptrend.xyaxis", title: "Spending")

            Spacer(minLength: 8)

            Chart {
                ForEach(entry.points, id: \.id) { point in
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
                    .symbolSize(16)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(maxHeight: .infinity)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SpendingInsightWidget: Widget {
    let kind = "SpendingInsightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpendingInsightProvider()) { entry in
            SpendingInsightView(entry: entry)
        }
        .configurationDisplayName("Spending")
        .description("Income and expenses over your selected range.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Categories

/// A Sendable pie slice — `CategorySlice` holds a live `Category`, so it can't
/// cross out of the main actor into the timeline entry.
struct WidgetPieSlice: Identifiable, Sendable {
    let name: String
    let amount: Double
    let color: Color

    var id: String { name }
}

struct CategoriesInsightEntry: TimelineEntry {
    let date: Date
    let slices: [WidgetPieSlice]
}

struct CategoriesInsightProvider: TimelineProvider {
    func placeholder(in context: Context) -> CategoriesInsightEntry {
        CategoriesInsightEntry(date: Date(), slices: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (CategoriesInsightEntry) -> Void) {
        Task { @MainActor in completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CategoriesInsightEntry>) -> Void) {
        Task { @MainActor in
            completion(Timeline(entries: [makeEntry()], policy: .after(nextRefresh())))
        }
    }

    @MainActor
    private func makeEntry() -> CategoriesInsightEntry {
        let inputs = loadInsightsInputs()
        let slices = categorySpendData(
            transactions: inputs.transactions,
            categories: inputs.categories,
            window: inputs.window
        ).map { WidgetPieSlice(name: $0.name, amount: $0.amount, color: $0.color) }
        return CategoriesInsightEntry(date: Date(), slices: slices)
    }
}

struct CategoriesInsightView: View {
    var entry: CategoriesInsightEntry

    var body: some View {
        VStack(alignment: .leading) {
            InsightHeader(symbol: "chart.pie", title: "Categories")

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Chart(entry.slices) { slice in
                    SectorMark(
                        angle: .value("Amount", slice.amount),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(slice.color.gradient)
                    .cornerRadius(4)
                }
                .chartLegend(.hidden)
                .frame(width: 70, height: 70)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.slices.prefix(3)) { slice in
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
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct CategoriesInsightWidget: Widget {
    let kind = "CategoriesInsightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CategoriesInsightProvider()) { entry in
            CategoriesInsightView(entry: entry)
        }
        .configurationDisplayName("Categories")
        .description("Top spending categories for your selected range.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Cash Flow

struct CashFlowInsightEntry: TimelineEntry {
    let date: Date
    let nodes: [SankeyNode]
    let links: [SankeyLink]
}

struct CashFlowInsightProvider: TimelineProvider {
    func placeholder(in context: Context) -> CashFlowInsightEntry {
        CashFlowInsightEntry(date: Date(), nodes: [], links: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (CashFlowInsightEntry) -> Void) {
        Task { @MainActor in completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CashFlowInsightEntry>) -> Void) {
        Task { @MainActor in
            completion(Timeline(entries: [makeEntry()], policy: .after(nextRefresh())))
        }
    }

    @MainActor
    private func makeEntry() -> CashFlowInsightEntry {
        let inputs = loadInsightsInputs()
        let data = cashFlowSankeyData(
            transactions: inputs.transactions,
            categories: inputs.categories,
            window: inputs.window
        )
        return CashFlowInsightEntry(date: Date(), nodes: data.nodes, links: data.links)
    }
}

struct CashFlowInsightView: View {
    var entry: CashFlowInsightEntry

    var body: some View {
        VStack(alignment: .leading) {
            InsightHeader(symbol: "arrow.down.left.arrow.up.right", title: "Cash Flow")

            Spacer(minLength: 8)

            SankeyDiagram(
                nodes: entry.nodes,
                links: entry.links,
                showLabels: false,
                nodeWidth: 6,
                vGap: 3
            )
            .frame(maxHeight: .infinity)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct CashFlowInsightWidget: Widget {
    let kind = "CashFlowInsightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CashFlowInsightProvider()) { entry in
            CashFlowInsightView(entry: entry)
        }
        .configurationDisplayName("Cash Flow")
        .description("How income flows into your spending this range.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Recurring

/// One day cell in the recurring mini calendar — just whether something recurs
/// and, if so, the color of the first recurring item that day.
struct WidgetRecurringDay: Identifiable, Sendable {
    let index: Int
    let color: Color?

    var id: Int { index }
}

struct RecurringInsightEntry: TimelineEntry {
    let date: Date
    let leadingBlanks: Int
    let days: [WidgetRecurringDay]
}

struct RecurringInsightProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecurringInsightEntry {
        RecurringInsightEntry(date: Date(), leadingBlanks: 0, days: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecurringInsightEntry) -> Void) {
        Task { @MainActor in completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecurringInsightEntry>) -> Void) {
        Task { @MainActor in
            completion(Timeline(entries: [makeEntry()], policy: .after(nextRefresh())))
        }
    }

    @MainActor
    private func makeEntry() -> RecurringInsightEntry {
        let inputs = loadInsightsInputs()
        let items = recurringItems(from: inputs.transactions)

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: Date())
        let firstOfMonth = calendar.date(from: components) ?? Date()
        let dayCount = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = (weekday - calendar.firstWeekday + 7) % 7

        var days: [WidgetRecurringDay] = []
        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstOfMonth) else { continue }
            let start = calendar.startOfDay(for: day)
            let end = start.endOfDay
            let color = items.first { occurrenceCount(of: $0.transaction, from: start, to: end, calendar: calendar) > 0 }?.color
            days.append(WidgetRecurringDay(index: offset, color: color))
        }

        return RecurringInsightEntry(date: Date(), leadingBlanks: leadingBlanks, days: days)
    }
}

struct RecurringInsightView: View {
    var entry: RecurringInsightEntry

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(alignment: .leading) {
            InsightHeader(symbol: "arrow.trianglehead.2.clockwise", title: "Recurring")

            Spacer(minLength: 8)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<entry.leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 10)
                }

                ForEach(entry.days) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 10)
                        .overlay {
                            if let color = day.color {
                                Circle()
                                    .fill(color)
                                    .frame(width: 5, height: 5)
                            }
                        }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct RecurringInsightWidget: Widget {
    let kind = "RecurringInsightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecurringInsightProvider()) { entry in
            RecurringInsightView(entry: entry)
        }
        .configurationDisplayName("Recurring")
        .description("This month's recurring transactions at a glance.")
        .supportedFamilies([.systemSmall])
    }
}
