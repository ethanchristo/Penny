//
//  InsightsChartsCore.swift
//  Penny
//
//  Insight chart data models, aggregations, and the self-contained Sankey view,
//  extracted from the Insights screens so they can be shared between the main app
//  and the widget extension. These are the "single source of truth" the full
//  insight screens, the insights-grid mini charts, and the home-screen widgets all
//  build on — none of them depend on any app-only view types.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Spending

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

// MARK: - Categories

/// One slice of the category spending pie: a single category's total expense
/// magnitude for the current window. File-scoped so the full
/// `CategoryInsightsView` and the compact `MiniPieChart` share a single source
/// of truth for both the data shape and the aggregation.
struct CategorySlice: Identifiable, Equatable {
    let category: Category
    let amount: Double

    /// Stable across amount changes so a slice grows/shrinks in place instead
    /// of being replaced when its total changes.
    var id: PersistentIdentifier { category.persistentModelID }

    var name: String { category.name }
    var symbol: String { category.symbol }
    var color: Color { category.color }

    static func == (lhs: CategorySlice, rhs: CategorySlice) -> Bool {
        lhs.id == rhs.id && lhs.amount == rhs.amount
    }
}

/// Sums expense magnitude per category within the window. Funds and (optionally)
/// savings are excluded via `calculateTotal`, which also handles the date
/// windowing — so the full transaction set can be passed in unfiltered.
/// Categories with no spend are omitted, and slices are sorted largest-first so
/// the pie and legend read top-down by size.
@MainActor
func categorySpendData(
    transactions: [Transaction],
    categories: [Category],
    window: (start: Date, end: Date)
) -> [CategorySlice] {
    let expenses = typedTransactions(for: transactions, income: false)

    // Group each category's expense transactions once up front, then window-sum
    // that small slice — rather than rescanning the full set per category.
    var slices: [CategorySlice] = []
    for category in categories {
        let categoryTx = expenses.filter { $0.category == category }
        guard !categoryTx.isEmpty else { continue }

        let amount = abs(calculateTotal(for: categoryTx, start: window.start, end: window.end))
        if amount > 0 {
            slices.append(CategorySlice(category: category, amount: amount))
        }
    }

    return slices.sorted { $0.amount > $1.amount }
}

// MARK: - Recurring

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

// MARK: - Native Sankey

/// One node (a stacked block) in the Sankey diagram. `column` places it in a
/// vertical band: 0 = left, 1 = center, 2 = right. A node's height is derived
/// from the links attached to it, so callers only describe the flows.
struct SankeyNode: Identifiable, Hashable {
    let id: String
    let label: String
    let color: Color
    let column: Int
}

/// A directed flow between two nodes, sized by `value`. Rendered as a curved
/// ribbon whose thickness is proportional to the value at both ends.
struct SankeyLink: Identifiable, Hashable {
    var id: String { "\(source)->\(target)" }
    let source: String
    let target: String
    let value: Double
}

/// A dependency-free, native SwiftUI Sankey diagram. Ribbons and node bars are
/// drawn in a single `Canvas` (fast, no per-mark views), while labels are real
/// SwiftUI `Text` positioned over the canvas so they get Dynamic Type and crisp
/// rendering. Because it draws with `Category.color` and the app's own palette,
/// it matches the rest of Insights — which a web-view Sankey couldn't.
struct SankeyDiagram: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    /// The node the user is pressing on, for the inspect tooltip.
    @State private var hoveredNodeID: String?

    let nodes: [SankeyNode]
    let links: [SankeyLink]

    var showLabels: Bool = true
    var nodeWidth: CGFloat = 12
    var vGap: CGFloat = 6

    /// Horizontal room reserved on each side for the outer-column labels.
    private var labelInset: CGFloat { showLabels ? 92 : 8 }

    private var maxColumn: Int { nodes.map(\.column).max() ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let layout = SankeyLayout(
                size: geo.size,
                nodes: nodes,
                links: links,
                nodeWidth: nodeWidth,
                vGap: vGap,
                inset: labelInset
            )

            let content = ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    // Ribbons first, so the solid node bars sit on top of them.
                    for ribbon in layout.ribbons {
                        context.fill(
                            ribbon.path,
                            with: .linearGradient(
                                Gradient(colors: [
                                    ribbon.sourceColor.opacity(0.45),
                                    ribbon.targetColor.opacity(0.45)
                                ]),
                                startPoint: ribbon.start,
                                endPoint: ribbon.end
                            )
                        )
                    }

                    for placed in layout.nodes {
                        context.fill(
                            Path(roundedRect: placed.rect, cornerRadius: 3),
                            with: .color(placed.node.color)
                        )
                    }
                }

                if showLabels {
                    ForEach(layout.nodes) { placed in
                        // Skip labels for slivers too small to read — keeps the
                        // outer columns from turning into a wall of text.
                        if placed.rect.height >= 9 {
                            label(for: placed, size: geo.size)
                        }
                    }
                }

                if let hoveredNodeID, let placed = layout.nodes.first(where: { $0.node.id == hoveredNodeID }) {
                    tooltip(for: placed, in: geo.size)
                }
            }
            .contentShape(.rect)
            .animation(.easeOut(duration: 0.12), value: hoveredNodeID)

            // Press-and-hold, then drag to inspect a category's amount. Gated to
            // the full diagram so the decorative mini (inside a NavigationLink)
            // keeps its tap. The long-press activation means a normal scroll or
            // tap is never captured.
            if showLabels {
                content.gesture(
                    LongPressGesture(minimumDuration: 0.15)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            if case .second(true, let drag?) = value {
                                hoveredNodeID = node(at: drag.location, in: layout)?.node.id
                            }
                        }
                        .onEnded { _ in hoveredNodeID = nil }
                )
            } else {
                content
            }
        }
    }

    /// The node whose bar contains `point`, with a generous horizontal margin so
    /// the thin bars are easy to land on.
    private func node(at point: CGPoint, in layout: SankeyLayout) -> SankeyLayout.PlacedNode? {
        layout.nodes.first { $0.rect.insetBy(dx: -18, dy: -2).contains(point) }
    }

    /// A floating label with the pressed node's category and amount, clamped to
    /// stay on screen and sitting just above the bar.
    private func tooltip(for placed: SankeyLayout.PlacedNode, in size: CGSize) -> some View {
        let x = min(max(placed.rect.midX, 70), size.width - 70)
        let y = max(28, placed.rect.minY - 10)

        return VStack(spacing: 2) {
            Text(placed.node.label)
                .font(.caption2.bold())
                .lineLimit(1)
            Text(amountTruncation(for: placed.value, currencySymbol: currencySymbol))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(placed.node.color.opacity(0.6), lineWidth: 1)
        )
        .shadow(radius: 4)
        .fixedSize()
        .position(x: x, y: y)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    @ViewBuilder
    private func label(for placed: SankeyLayout.PlacedNode, size: CGSize) -> some View {
        // Only the category name is shown at rest — the amount is revealed by
        // pressing and holding over the node (see the inspect tooltip).
        let content = VStack(alignment: placed.node.column == 0 ? .trailing : .leading, spacing: 0) {
            Text(placed.node.label)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)

        let inset = labelInset

        if placed.node.column == 0 {
            content
                .frame(width: inset - 8, alignment: .trailing)
                .position(x: (inset - 8) / 2, y: placed.rect.midY)
        } else if placed.node.column == maxColumn {
            content
                .frame(width: inset - 8, alignment: .leading)
                .position(x: size.width - (inset - 8) / 2, y: placed.rect.midY)
        } else {
            // Center column: sit just above the top of the bar.
            content
                .frame(width: 120)
                .multilineTextAlignment(.center)
                .position(x: placed.rect.midX, y: max(10, placed.rect.minY - 12))
        }
    }
}

/// Pure geometry for a Sankey render: turns nodes + links into positioned bars
/// and ribbon paths for a given size. Kept separate from the view so the layout
/// math is self-contained and easy to reason about.
private struct SankeyLayout {
    struct PlacedNode: Identifiable {
        let node: SankeyNode
        let rect: CGRect
        let value: Double
        var id: String { node.id }
    }

    struct Ribbon {
        let path: Path
        let sourceColor: Color
        let targetColor: Color
        let start: CGPoint
        let end: CGPoint
    }

    let nodes: [PlacedNode]
    let ribbons: [Ribbon]

    init(size: CGSize, nodes: [SankeyNode], links: [SankeyLink], nodeWidth: CGFloat, vGap: CGFloat, inset: CGFloat) {
        // A node's flow is the larger of what enters and what leaves it. For
        // terminal nodes one side is zero; for the center both should match.
        var inflow: [String: Double] = [:]
        var outflow: [String: Double] = [:]
        for link in links {
            outflow[link.source, default: 0] += link.value
            inflow[link.target, default: 0] += link.value
        }
        func value(_ id: String) -> Double { max(inflow[id] ?? 0, outflow[id] ?? 0) }

        let maxColumn = nodes.map(\.column).max() ?? 0

        // Group by column, biggest flow first so the stacks read top-down by size.
        var columns: [Int: [SankeyNode]] = [:]
        for node in nodes { columns[node.column, default: []].append(node) }
        for key in columns.keys {
            columns[key]?.sort { value($0.id) > value($1.id) }
        }

        let columnTotals = columns.mapValues { $0.reduce(0.0) { $0 + value($1.id) } }
        let total = columnTotals.values.max() ?? 0

        guard total > 0, size.height > 0, size.width > 0 else {
            self.nodes = []
            self.ribbons = []
            return
        }

        // One shared value→pixel scale so a given flow is the same thickness at
        // both ends of every ribbon. The tallest column fills the height; shorter
        // columns are centered vertically.
        let maxCount = columns.values.map(\.count).max() ?? 1
        let maxGapTotal = CGFloat(max(0, maxCount - 1)) * vGap
        let scale = (size.height - maxGapTotal) / total

        let leftX = inset
        let rightX = size.width - inset - nodeWidth
        func columnX(_ column: Int) -> CGFloat {
            guard maxColumn > 0 else { return leftX }
            return leftX + (rightX - leftX) * CGFloat(column) / CGFloat(maxColumn)
        }

        var rects: [String: CGRect] = [:]
        var placed: [PlacedNode] = []
        for column in 0...maxColumn {
            let colNodes = columns[column] ?? []
            guard !colNodes.isEmpty else { continue }

            let colTotal = columnTotals[column] ?? 0
            let colHeight = CGFloat(colTotal) * scale + CGFloat(colNodes.count - 1) * vGap
            var y = (size.height - colHeight) / 2
            let x = columnX(column)

            for node in colNodes {
                let height = CGFloat(value(node.id)) * scale
                let rect = CGRect(x: x, y: y, width: nodeWidth, height: height)
                rects[node.id] = rect
                placed.append(PlacedNode(node: node, rect: rect, value: value(node.id)))
                y += height + vGap
            }
        }

        // Stack each node's links on its edges. Outgoing links are ordered by the
        // target's vertical position (and incoming by the source's) so ribbons
        // fan out without crossing.
        var sourceSeg: [String: (CGFloat, CGFloat)] = [:]
        for (sid, group) in Dictionary(grouping: links, by: \.source) {
            let ordered = group.sorted { (rects[$0.target]?.minY ?? 0) < (rects[$1.target]?.minY ?? 0) }
            var cursor = rects[sid]?.minY ?? 0
            for link in ordered {
                let thickness = CGFloat(link.value) * scale
                sourceSeg[link.id] = (cursor, cursor + thickness)
                cursor += thickness
            }
        }

        var targetSeg: [String: (CGFloat, CGFloat)] = [:]
        for (tid, group) in Dictionary(grouping: links, by: \.target) {
            let ordered = group.sorted { (rects[$0.source]?.minY ?? 0) < (rects[$1.source]?.minY ?? 0) }
            var cursor = rects[tid]?.minY ?? 0
            for link in ordered {
                let thickness = CGFloat(link.value) * scale
                targetSeg[link.id] = (cursor, cursor + thickness)
                cursor += thickness
            }
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var ribbons: [Ribbon] = []
        for link in links {
            guard let s = rects[link.source], let t = rects[link.target],
                  let ss = sourceSeg[link.id], let ts = targetSeg[link.id] else { continue }

            let x0 = s.maxX
            let x1 = t.minX
            let cx = (x0 + x1) / 2

            var path = Path()
            path.move(to: CGPoint(x: x0, y: ss.0))
            path.addCurve(to: CGPoint(x: x1, y: ts.0),
                          control1: CGPoint(x: cx, y: ss.0),
                          control2: CGPoint(x: cx, y: ts.0))
            path.addLine(to: CGPoint(x: x1, y: ts.1))
            path.addCurve(to: CGPoint(x: x0, y: ss.1),
                          control1: CGPoint(x: cx, y: ts.1),
                          control2: CGPoint(x: cx, y: ss.1))
            path.closeSubpath()

            ribbons.append(Ribbon(
                path: path,
                sourceColor: nodeByID[link.source]?.color ?? .gray,
                targetColor: nodeByID[link.target]?.color ?? .gray,
                start: CGPoint(x: x0, y: (ss.0 + ss.1) / 2),
                end: CGPoint(x: x1, y: (ts.0 + ts.1) / 2)
            ))
        }

        self.nodes = placed
        self.ribbons = ribbons
    }
}

// MARK: - Cash Flow data

/// Builds the income → cash-flow → expenses Sankey for the window. Income
/// categories feed a central hub, which fans back out to expense categories.
/// The books are balanced with a surplus ("Leftover") on the right or a
/// draw-down ("From Savings") on the left, so total inflow always equals total
/// outflow. Funds/savings are excluded exactly as they are elsewhere in Insights
/// (via `calculateTotal`). Returns empty arrays when there's nothing to show.
@MainActor
func cashFlowSankeyData(
    transactions: [Transaction],
    categories: [Category],
    window: (start: Date, end: Date)
) -> (nodes: [SankeyNode], links: [SankeyLink]) {
    let income = typedTransactions(for: transactions, income: true)
    let expenses = typedTransactions(for: transactions, income: false)

    let centerID = "cashflow"
    var nodes: [SankeyNode] = []
    var links: [SankeyLink] = []
    var totalIncome = 0.0
    var totalExpense = 0.0

    // Income sources on the left, each flowing into the hub.
    for category in categories {
        let amount = abs(calculateTotal(for: income.filter { $0.category == category },
                                        start: window.start, end: window.end))
        if amount > 0 {
            let id = "in-\(category.name)"
            nodes.append(SankeyNode(id: id, label: "\(category.symbol) \(category.name)", color: category.color, column: 0))
            links.append(SankeyLink(source: id, target: centerID, value: amount))
            totalIncome += amount
        }
    }

    let uncategorizedIncome = abs(calculateTotal(for: income.filter { $0.category == nil },
                                                 start: window.start, end: window.end))
    if uncategorizedIncome > 0 {
        nodes.append(SankeyNode(id: "in-none", label: "Income", color: Color(.systemGreen), column: 0))
        links.append(SankeyLink(source: "in-none", target: centerID, value: uncategorizedIncome))
        totalIncome += uncategorizedIncome
