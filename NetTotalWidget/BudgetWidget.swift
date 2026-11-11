//
//  BudgetWidget.swift
//  NetTotalWidget
//
//  A configurable small widget that tracks a single budget — the Overall budget,
//  a category budget, or a custom (freestanding) budget. Add it multiple times and
//  configure each instance to a different budget via long-press → Edit Widget.
//

import AppIntents
import Charts
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Configuration intent

/// The sentinel id used for the Overall budget, which isn't a `Budget` model.
private let overallBudgetID = "overall"

/// A pickable budget for the widget configuration: either the Overall budget or a
/// stored `Budget` (category or freestanding), identified by its stable UUID string.
struct WidgetBudgetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Budget"
    static var defaultQuery = WidgetBudgetQuery()

    var id: String
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(symbol)  \(name)")
    }
}

struct WidgetBudgetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WidgetBudgetEntity] {
        let all = try await suggestedEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    /// Overall budget (when enabled) first, then every active category and custom budget.
    @MainActor
    func suggestedEntities() async throws -> [WidgetBudgetEntity] {
        var results: [WidgetBudgetEntity] = []

        let overall = OverallBudget()
        if overall.isEnabled {
            results.append(WidgetBudgetEntity(id: overallBudgetID, name: "Overall Budget", symbol: "📊"))
        }

        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Budget>(predicate: #Predicate { $0.hasBudget })
        let budgets = (try? context.fetch(descriptor)) ?? []
        for budget in budgets {
            results.append(WidgetBudgetEntity(id: budget.id.uuidString, name: budget.displayName, symbol: budget.displaySymbol))
        }

        return results
    }

    @MainActor
    func defaultResult() async -> WidgetBudgetEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectBudgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Budget"
    static var description = IntentDescription("Choose which budget this widget displays.")

    @Parameter(title: "Budget")
    var budget: WidgetBudgetEntity?
}

// MARK: - Entry

/// Everything the view needs, reduced to plain `Sendable` values so the SwiftData
/// model objects never leave the main actor.
struct BudgetSnapshot: Sendable {
    let title: String
    let symbol: String
    let colorHex: String
    /// Money "used" (fills the faint arc).
    let spent: Double
    /// Money left (fills the solid arc); negative means over budget.
    let remaining: Double
    /// Headline word under the amount ("remaining", "over", "used", "contributed").
    let descriptor: String
    /// Trailing context ("this month", "one-time", …). May be empty.
    let windowText: String
    let currencySymbol: String
}

struct BudgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BudgetSnapshot?
}

// MARK: - Provider

struct BudgetProvider: AppIntentTimelineProvider {
    typealias Intent = SelectBudgetIntent
    typealias Entry = BudgetEntry

    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: Date(), snapshot: BudgetSnapshot(
            title: "Groceries", symbol: "🛒", colorHex: "#32D74B",
            spent: 320, remaining: 180, descriptor: "remaining",
            windowText: "this month", currencySymbol: "$"
        ))
    }

    func snapshot(for configuration: SelectBudgetIntent, in context: Context) async -> BudgetEntry {
        await makeEntry(for: configuration)
    }

    func timeline(for configuration: SelectBudgetIntent, in context: Context) async -> Timeline<BudgetEntry> {
        let entry = await makeEntry(for: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    /// Resolves the configured (or default) budget id to a snapshot, computed on the
    /// main actor where the shared SwiftData context lives.
    @MainActor
    private func makeEntry(for configuration: SelectBudgetIntent) async -> BudgetEntry {
        let id: String?
        if let configured = configuration.budget?.id {
            id = configured
        } else {
            id = await WidgetBudgetQuery().defaultResult()?.id
        }
        guard let id else { return BudgetEntry(date: Date(), snapshot: nil) }
        return BudgetEntry(date: Date(), snapshot: snapshot(forID: id))
    }

    private var currencySymbol: String {
        UserDefaults(suiteName: SharedDatabase.appGroup)?.string(forKey: "currency_symbol") ?? "$"
    }

    @MainActor
    private func snapshot(forID id: String) -> BudgetSnapshot? {
        let context = SharedDatabase.shared.container.mainContext
        let symbol = currencySymbol

        if id == overallBudgetID {
            let overall = OverallBudget()
            guard overall.isEnabled else { return nil }
            let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
            let spent = overallBudgetTotal(for: overall, in: transactions, by: 0)
            let remaining = overall.budget - spent
            return BudgetSnapshot(
                title: "Overall Budget", symbol: "📊", colorHex: "#8E8E93",
                spent: spent, remaining: remaining,
                descriptor: remaining < 0 ? "over" : "remaining",
                windowText: budgetWindowText(from: overall.budgetWindow),
                currencySymbol: symbol
            )
        }

        guard let uuid = UUID(uuidString: id) else { return nil }
        let descriptor = FetchDescriptor<Budget>(predicate: #Predicate { $0.id == uuid })
        guard let budget = (try? context.fetch(descriptor))?.first else { return nil }

        // Category budget: spend is derived from the category's transactions.
        if let category = budget.category {
            let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
            let spent = budgetTotal(for: category, in: transactions, by: 0)
            let remaining = budget.amount - spent
            return BudgetSnapshot(
                title: category.name, symbol: category.symbol, colorHex: category.hexColor,
                spent: spent, remaining: remaining,
                descriptor: remaining < 0 ? "over" : "remaining",
                windowText: budgetWindowText(from: budget.budgetWindow ?? .monthly),
                currencySymbol: symbol
            )
        }

        // Freestanding budget: spend/remaining come off its own tagged transactions.
        let used = budget.used
        let remaining = budget.remaining
        let windowText = budget.isRecurring ? budgetWindowText(from: budget.budgetWindow ?? .monthly) : "one-time"
        return BudgetSnapshot(
            title: budget.name, symbol: budget.symbol, colorHex: budget.hexColor,
            spent: used, remaining: remaining,
            descriptor: freestandingDescriptor(for: budget),
            windowText: windowText,
            currencySymbol: symbol
        )
    }

    /// Mirrors `FreestandingBudgetCell`'s headline word.
    private func freestandingDescriptor(for budget: Budget) -> String {
        if budget.preFunding {
            return budget.used <= budget.amount ? "remaining" : "over"
        } else if budget.used == 0 {
            return "contributed"
        } else {
            return budget.remaining >= 0 ? "used" : "over"
        }
    }
}

// MARK: - View

struct BudgetWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family
    var entry: BudgetEntry

    var body: some View {
        switch (family, entry.snapshot) {
        case (.accessoryCircular, let snapshot?):
            circular(snapshot)
        case (.accessoryRectangular, let snapshot?):
            rectangular(snapshot)
        case (.accessoryInline, let snapshot?):
            Text("\(snapshot.symbol) \(snapshot.currencySymbol)\(amountTruncation(for: abs(snapshot.remaining))) \(snapshot.descriptor)")
                .containerBackground(.clear, for: .widget)
        case (.accessoryCircular, nil), (.accessoryRectangular, nil), (.accessoryInline, nil):
            Label("Pick a budget", systemImage: "chart.bar")
                .font(.caption)
                .containerBackground(.clear, for: .widget)
        case (_, let snapshot?):
            filled(snapshot)
        case (_, nil):
            unconfigured
        }
    }

    // MARK: Lock Screen

    /// Share of the budget used so far, clamped to 0...1 for the gauges.
    private func usedFraction(_ snapshot: BudgetSnapshot) -> Double {
        let total = max(snapshot.spent, 0) + max(snapshot.remaining, 0)
        guard total > 0 else { return 0 }
        return min(max(snapshot.spent / total, 0), 1)
    }

    private func circular(_ snapshot: BudgetSnapshot) -> some View {
        Gauge(value: usedFraction(snapshot)) {
            Text(snapshot.symbol)
        } currentValueLabel: {
            Text(amountTruncation(for: abs(snapshot.remaining)))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircular)
        .fontDesign(.rounded)
        .containerBackground(.clear, for: .widget)
    }

    private func rectangular(_ snapshot: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(snapshot.symbol) \(snapshot.title)")
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()

            Text("\(snapshot.currencySymbol)\(amountTruncation(for: abs(snapshot.remaining))) \(snapshot.descriptor)")
                .font(.body.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Gauge(value: usedFraction(snapshot)) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fontDesign(.rounded)
        .containerBackground(.clear, for: .widget)
    }

    // MARK: Home Screen

    private func color(_ hex: String) -> Color { Color(hex: hex) ?? .green }

    private func filled(_ snapshot: BudgetSnapshot) -> some View {
        let color = color(snapshot.colorHex)
        let accent = color.mix(with: colorScheme == .light ? .black : .white, by: 0.4)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("\(snapshot.symbol)  \(snapshot.title)")
                    .font(.subheadline.bold())
                    .lineLimit(2)

                Spacer(minLength: 4)

                donut(spent: snapshot.spent, remaining: snapshot.remaining, color: color)
                    .frame(width: 24, height: 24)
            }

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(snapshot.currencySymbol)
                    .font(.title3.bold())
                    .foregroundStyle(accent)

                Text(amountTruncation(for: abs(snapshot.remaining)))
                    .font(.title.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Text("\(Text(snapshot.descriptor).underline()) \(snapshot.windowText)")
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .fontDesign(.rounded)
        .foregroundStyle(color.mix(with: colorScheme == .light ? .black : .white, by: 0.7))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [color.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
        }
    }

    /// A spent-vs-remaining ring matching the app's budget cells.
    private func donut(spent: Double, remaining: Double, color: Color) -> some View {
        let data = [
            (name: "spent", value: max(spent, 0), color: color.opacity(0.3)),
            (name: "remaining", value: max(remaining, 0), color: color)
        ]
        return Chart(data, id: \.name) { _, value, sliceColor in
            SectorMark(angle: .value("Value", value), innerRadius: .ratio(0.6), angularInset: 1)
                .cornerRadius(2)
                .foregroundStyle(sliceColor)
        }
    }

    private var unconfigured: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Pick a budget")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fontDesign(.rounded)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget

struct BudgetWidget: Widget {
    let kind = "BudgetWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectBudgetIntent.self, provider: BudgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
        }
        .configurationDisplayName("Budget")
        .description("Track a budget's remaining balance.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    BudgetWidget()
} timeline: {
    BudgetEntry(date: .now, snapshot: BudgetSnapshot(
        title: "Groceries", symbol: "🛒", colorHex: "#32D74B",
        spent: 320, remaining: 180, descriptor: "remaining",
        windowText: "this month", currencySymbol: "$"
    ))
    BudgetEntry(date: .now, snapshot: nil)
}

#Preview("Lock Screen Circular", as: .accessoryCircular) {
    BudgetWidget()
} timeline: {
    BudgetEntry(date: .now, snapshot: BudgetSnapshot(
        title: "Groceries", symbol: "🛒", colorHex: "#32D74B",
        spent: 320, remaining: 180, descriptor: "remaining",
        windowText: "this month", currencySymbol: "$"
    ))
}

#Preview("Lock Screen Rectangular", as: .accessoryRectangular) {
    BudgetWidget()
} timeline: {
    BudgetEntry(date: .now, snapshot: BudgetSnapshot(
        title: "Groceries", symbol: "🛒", colorHex: "#32D74B",
        spent: 320, remaining: 180, descriptor: "remaining",
        windowText: "this month", currencySymbol: "$"
    ))
}

#Preview("Lock Screen Inline", as: .accessoryInline) {
    BudgetWidget()
} timeline: {
    BudgetEntry(date: .now, snapshot: BudgetSnapshot(
        title: "Groceries", symbol: "🛒", colorHex: "#32D74B",
        spent: 320, remaining: 180, descriptor: "remaining",
        windowText: "this month", currencySymbol: "$"
    ))
}
