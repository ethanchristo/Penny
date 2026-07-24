//
//  CashFlowInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 7/17/26.
//

import SwiftData
import SwiftUI

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
    }

    // Expense destinations on the right, each fed by the hub.
    for category in categories {
        let amount = abs(calculateTotal(for: expenses.filter { $0.category == category },
                                        start: window.start, end: window.end))
        if amount > 0 {
            let id = "ex-\(category.name)"
            nodes.append(SankeyNode(id: id, label: "\(category.symbol) \(category.name)", color: category.color, column: 2))
            links.append(SankeyLink(source: centerID, target: id, value: amount))
            totalExpense += amount
        }
    }

    let uncategorizedExpense = abs(calculateTotal(for: expenses.filter { $0.category == nil },
                                                  start: window.start, end: window.end))
    if uncategorizedExpense > 0 {
        nodes.append(SankeyNode(id: "ex-none", label: "Other", color: Color(.systemGray), column: 2))
        links.append(SankeyLink(source: centerID, target: "ex-none", value: uncategorizedExpense))
        totalExpense += uncategorizedExpense
    }

    guard totalIncome > 0 || totalExpense > 0 else { return ([], []) }

    // Fund any shortfall (spending more than earned) with an extra "From Savings"
    // inflow so the hub still balances. A surplus is simply left unshown — the
    // expense side just won't fill the full height of the income side.
    let net = totalIncome - totalExpense
    if net < -0.005 {
        nodes.append(SankeyNode(id: "deficit", label: "From Savings", color: Color(.systemOrange), column: 0))
        links.append(SankeyLink(source: "deficit", target: centerID, value: -net))
    }

    nodes.append(SankeyNode(id: centerID, label: "", color: Color(.systemGray2), column: 1))

    return (nodes, links)
}

// MARK: - Cash Flow Insights

struct CashFlowInsightsView: View {
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]

    @Namespace private var namespace

    @State private var windowTimeRange: HomeTimeRange = .monthly
    @State private var dateOffset: Int = 0
    @State private var showAddTransaction: Bool = false
    @State private var editingTransaction: Transaction?
    
    @State private var showNetSheet = false
    @State private var showInSheet = false
    @State private var showOutSheet = false

    private var window: (start: Date, end: Date) {
        dateWindow()
    }

    /// The window's non-fund transactions (both income and expense), newest-first,
    /// feeding the list below the diagram.
    private var windowedTransactions: [Transaction] {
        let calendar = Calendar.current
        return transactions
            .filter { $0.fund == nil }
            .filter { occurs($0, from: window.start, to: window.end, calendar: calendar) }
            .sorted { $0.date > $1.date }
    }
    var body: some View {
        // Compute the diagram data (a full scan over every transaction × category)
        // exactly once per render, then derive the totals from its links. Reading
        // these as locals keeps the body, summary, and sheets consistent without
        // re-running the scan on every access.
        let data = cashFlowSankeyData(transactions: transactions, categories: categories, window: window)
        let totalIn = data.links.filter { $0.target == "cashflow" }.reduce(0.0) { $0 + $1.value }
        let totalOut = data.links.filter { $0.source == "cashflow" }.reduce(0.0) { $0 + $1.value }
        let net = totalIn - totalOut

        return ScrollView(.vertical, showsIndicators: false) {


            if data.nodes.isEmpty {
                ContentUnavailableView(
                    "No Cash Flow",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("There's no income or spending for this period.")
                )
                .frame(height: 300)
            } else {
                ScrollView(.horizontal) {
                    summary(net: net, totalIn: totalIn, totalOut: totalOut)
                }
                .scrollClipDisabled()

                SankeyDiagram(nodes: data.nodes, links: data.links)
                    .frame(height: sankeyHeight(for: data.nodes))
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                    .padding(.horizontal, 12)
                    .animation(.smooth, value: dateOffset)
            }

            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: windowedTransactions,
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: false,
                hideUpcoming: true,
                hideAllTx: false,
                searchString: ""
            )
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Cash Flow")
        .navigationSubtitle(windowTimeRange.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                SingleTransactionView(initialEditMode: true, transaction: nil, category: nil, fund: nil)
            }
            .navigationTransition(.zoom(sourceID: "addTransaction", in: namespace))
        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, fund: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
        .sheet(isPresented: $showNetSheet) {
            NavigationStack {
                Text(net, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showInSheet) {
            NavigationStack {
                Text(totalIn, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showOutSheet) {
            NavigationStack {
                Text(totalOut, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
    }

    /// In / Out / Net chips derived from the diagram's own links, so the summary
    /// can never disagree with the ribbons.
    @ViewBuilder
    private func summary(net: Double, totalIn: Double, totalOut: Double) -> some View {
        HStack {
            Button {
                showNetSheet = true
            } label: {
                summaryChip(title: "NET:", amount: net)
            }
            .buttonStyle(.plain)
            
            Button {
                showInSheet = true
            } label: {
                summaryChip(title: "IN:", amount: totalIn)
            }
            .buttonStyle(.plain)
             
            Button {
                showOutSheet = true
            } label: {
                summaryChip(title: "OUT:", amount: totalOut)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.top, 8)
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

    /// Grow the diagram with the number of nodes so a busy month still has room
    /// to breathe, with a sensible floor for sparse periods.
    private func sankeyHeight(for nodes: [SankeyNode]) -> CGFloat {
        let leftCount = nodes.filter { $0.column == 0 }.count
        let rightCount = nodes.filter { $0.column == 2 }.count
        let busiest = max(leftCount, rightCount, 1)
        return max(300, CGFloat(busiest) * 56)
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
}
