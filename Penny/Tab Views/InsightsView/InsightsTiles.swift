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

/// Identifies what a single tile in the Insights grid renders. Built-in tiles are
/// the four chart summaries; the others reference a user-added budget or fund by
/// its persistent model `id` so the layout survives relaunches.
enum InsightTileKind: Codable, Hashable {
    case builtin(InsightsOptions)
    case categoryBudget(PersistentIdentifier)
    case overallBudget
    case fund(PersistentIdentifier)

    /// A stable string identity used both for `ForEach`/reorder diffing and for
    /// deduping when adding tiles. Keyed off SwiftData's `PersistentIdentifier`
    /// (guaranteed unique per object) rather than the models' own `UUID`, which
    /// isn't reliably unique across the store.
    var id: String {
        switch self {
        case .builtin(let option): return "builtin.\(option.rawValue)"
        case .categoryBudget(let pid): return "budget.\(pid.hashValue)"
        case .overallBudget: return "overall"
        case .fund(let pid): return "fund.\(pid.hashValue)"
        }
    }
}

/// One entry in the persisted Insights layout: what to show, whether it's hidden,
/// and — via array order — where it sits in the grid.
struct InsightTile: Codable, Hashable, Identifiable {
    var kind: InsightTileKind
    var isHidden: Bool = false

    var id: String { kind.id }
}

/// Navigation targets for budget/fund tiles. Value-based navigation (rather than
/// eager `NavigationLink(destination:)`) is required inside a `LazyVGrid` — the
/// eager form mis-associates destinations in lazy containers, pushing the wrong
/// detail (e.g. tapping "Food" opening "Drinks").
enum InsightsRoute: Hashable {
    case categoryBudget(PersistentIdentifier)
    case overallBudget
    case fund(PersistentIdentifier)
}

struct InsightsTiles: View {
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly
    @AppStorage("show_insights") private var showInsights: Bool = true
    /// JSON-encoded `[InsightTile]` describing the user's customised layout.
    @AppStorage("insights_layout_v1") private var layoutStore: Data = Data()

    @Environment(OverallBudget.self) private var overallBudget

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Budget.name) private var budgets: [Budget]

    /// Freestanding (non-category) budgets — the only ones shown as standalone tiles.
    private var freestandingBudgets: [Budget] {
        budgets.filter { $0.isFreestanding && $0.hasBudget }
    }

    @Namespace private var namespace

    /// The working copy of the layout. Seeded from `layoutStore` on appear and
    /// written back on every mutation.
    @State private var tiles: [InsightTile] = []
    @State private var isEditing = false

    /// Selected navigation targets, driven by tile taps. Item-based navigation
    /// (Button sets state → `navigationDestination(item:)`) rather than
    /// `NavigationLink(value:)`, because the Insights grid is now pushed as its
    /// own screen — a type-based `navigationDestination(for:)` declared inside a
    /// pushed view doesn't reliably register, so the tiles wouldn't navigate and
    /// the zoom transition wouldn't resolve. This matches the pattern in `BudgetView`.
    @State private var selectedOption: InsightsOptions?
    @State private var selectedRoute: InsightsRoute?

    /// Transactions grouped by category name, rebuilt only when the transactions change
    /// (see `.task(id:)`). Lets each category tile look up its slice in O(1) instead of
    /// re-scanning the whole transactions array per tile on every render.
    @State private var transactionsByCategory: [String: [Transaction]] = [:]

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 10)
    ]

    /// Tiles that can currently be resolved to a live model (or are built-in).
    /// Deleted budgets/funds and a disabled overall budget fall away automatically.
    private var editTiles: [InsightTile] {
        tiles.filter(isResolvable)
    }

    /// Non-hidden, resolvable tiles — what the grid shows when not editing.
    private var displayTiles: [InsightTile] {
        editTiles.filter { !$0.isHidden }
    }
    
    var body: some View {
        Group {
            if isEditing {
                if #available(iOS 27.0, *) {
                    reorderableEditGrid
                } else {
                    staticEditGrid
                }
            } else {
                displayGrid
            }
        }
        .padding(.top, 8)
        .animation(.snappy, value: isEditing)
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
        .navigationDestination(item: $selectedRoute) { route in
            switch route {
            case .categoryBudget(let id):
                if let category = categories.first(where: { $0.persistentModelID == id }) {
                    BudgetInsightsView(
                        namespace: namespace,
                        source: .category(category, filter: categoriedTransactions(for: transactions, with: category))
                    )
                }
            case .overallBudget:
                BudgetInsightsView(namespace: namespace, source: .overall(overallBudget, filter: transactions))
            case .fund(let id):
                if let fund = freestandingBudgets.first(where: { $0.persistentModelID == id }) {
                    FreestandingBudgetInsightsView(budget: fund, namespace: namespace)
                }
            }
        }
        .task { loadTiles() }
        // Rebuild the category → transactions index only when the transactions change,
        // not per tile per render (transactionsFingerprint folds in category name, so
        // re-categorizing a transaction refires this too).
        .task(id: transactionsFingerprint(transactions)) { rebuildCategoryIndex() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Group {
                    if isEditing {
                        Menu {
                            // Compute each addable list once — they filter categories/budgets
                            // against the current tiles, and were previously read twice (the
                            // `.isEmpty` check and the `ForEach`).
                            let addableCats = addableCategories
                            let addableFunds = addableFreestandingBudgets

                            Button("Edit Layout", systemImage: "arrow.up.arrow.down") {
                                isEditing = true
                            }
                            
                            Divider()
                            
                            if addableOverall || !addableCats.isEmpty {
                                Menu("Add Budget", systemImage: "chart.bar") {
                                    if addableOverall {
                                        Button("Overall Budget") { add(.overallBudget) }
                                    }
                                    ForEach(addableCats) { category in
                                        Button("\(category.symbol)  \(category.name)") {
                                            add(.categoryBudget(category.persistentModelID))
                                        }
                                    }
                                }
                            }
                            
                            if !addableFunds.isEmpty {
                                Menu("Add Custom Budget", systemImage: "rectangle.stack") {
                                    ForEach(addableFunds) { budget in
                                        Button("\(budget.symbol)  \(budget.name)") {
                                            add(.fund(budget.persistentModelID))
                                        }
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Button("Hide Insights", systemImage: "eye.slash", role: .destructive) {
                                showInsights = false
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .tint(.primary)
                    } else {
                        Button("Done") {
                            isEditing.toggle()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Grids

    private var displayGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(displayTiles) { tile in
                navigableTile(for: tile)
            }
        }
        .padding(.horizontal, 24)
    }

    @available(iOS 27.0, *)
    private var reorderableEditGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(editTiles) { tile in
                editTile(for: tile)
            }
            .reorderable()
        }
        .reorderContainer(for: InsightTile.self) { difference in
            // Call the Apple extension, passing your master array as an inout reference
            difference.apply(to: &tiles)
            persist()
        }
        .padding(.horizontal, 10)
    }

    private var staticEditGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(editTiles) { tile in
                editTile(for: tile)
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Tile builders

    @ViewBuilder
    private func navigableTile(for tile: InsightTile) -> some View {
        switch tile.kind {
        case .builtin(let option):
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
            .transition(.blurReplace)

        case .categoryBudget(let id):
            if let category = categories.first(where: { $0.persistentModelID == id }) {
                let filtered = transactionsByCategory[category.name] ?? []
                Button {
                    selectedRoute = .categoryBudget(id)
                } label: {
                    SharedBudgetCell(source: .category(category, filter: filtered))
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: category.id, in: namespace)
            }

        case .overallBudget:
            Button {
                selectedRoute = .overallBudget
            } label: {
                SharedBudgetCell(source: .overall(overallBudget, filter: transactions))
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: "overallInsights", in: namespace)

        case .fund(let id):
            if let fund = freestandingBudgets.first(where: { $0.persistentModelID == id }) {
                Button {
                    selectedRoute = .fund(id)
                } label: {
                    FreestandingBudgetCell(budget: fund)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: fund.id, in: namespace)
            }
        }
    }

    private func editTile(for tile: InsightTile) -> some View {
        reorderCard(for: tile)
            .opacity(tile.isHidden ? 0.4 : 1)
            .overlay(alignment: .topLeading) {
                editBadge(for: tile)
            }
    }

    /// A lightweight, chart-free representation shown only while reordering. The
    /// live cells embed Swift Charts, and — crucially — any *view-level*
    /// branching (`switch`/`if`) inside a reorderable item makes SwiftUI's drag
    /// payload builder resolve the wrong identity and crash on lift. So the label
    /// is built entirely in value space (returning a single `Text`) and rendered
    /// as one concrete view with no conditional content.
    private func reorderCard(for tile: InsightTile) -> some View {
        HStack(spacing: 8) {
            reorderLabel(for: tile)
                .lineLimit(1)
            Spacer()
        }
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .padding()
        .glassEffect(in: RoundedRectangle(cornerRadius: 26))
    }

    /// Builds the tile's icon + title as a single `Text` (value space, no view
    /// branching). Built-ins use an SF Symbol; budgets/funds use their emoji.
    private func reorderLabel(for tile: InsightTile) -> Text {
        switch tile.kind {
        case .builtin(let option):
            return Text("\(Image(systemName: option.symbol))  \(option.title)")
        case .overallBudget:
            return Text("\(Image(systemName: "chart.bar"))  Overall Budget")
        case .categoryBudget(let id):
            let category = categories.first { $0.persistentModelID == id }
            return Text("\(category?.symbol ?? "")  \(category?.name ?? "")")
        case .fund(let id):
            let fund = freestandingBudgets.first { $0.persistentModelID == id }
            return Text("\(fund?.symbol ?? "")  \(fund?.name ?? "")")
        }
    }

    @ViewBuilder
    private func staticTile(for tile: InsightTile) -> some View {
        switch tile.kind {
        case .builtin(let option):
            InsightsCell(
                option: option,
                transactions: transactions,
                categories: categories,
                timeRange: selectedTimeRange
            )

        case .categoryBudget(let id):
            if let category = categories.first(where: { $0.persistentModelID == id }) {
                SharedBudgetCell(source: .category(category, filter: transactionsByCategory[category.name] ?? []), interactive: false)
            }

        case .overallBudget:
            SharedBudgetCell(source: .overall(overallBudget, filter: transactions), interactive: false)

        case .fund(let id):
            if let fund = freestandingBudgets.first(where: { $0.persistentModelID == id }) {
                FreestandingBudgetCell(budget: fund, interactive: false)
            }
        }
    }

    /// The corner control shown in edit mode: built-in tiles toggle hidden (eye),
    /// user-added budget/fund tiles are removed outright (minus).
    private func editBadge(for tile: InsightTile) -> some View {
        // Built-in tiles toggle hidden (eye); user-added budget/fund tiles are
        // removed (minus). All per-kind decisions are made in value space and
        // rendered as a single Button — view-level branching inside a reorderable
        // item crashes SwiftUI's drag payload builder on lift.
        let isBuiltin: Bool = { if case .builtin = tile.kind { return true }; return false }()
        let symbol = isBuiltin ? (tile.isHidden ? "eye.fill" : "eye.slash.fill") : "minus"
//        let tint: Color = isBuiltin ? (tile.isHidden ? Color(.systemGreen) : .clear) : Color(.systemRed)

        return Button {
            if isBuiltin {
                toggleHidden(tile)
            } else {
                remove(tile)
            }
        } label: {
            Image(systemName: symbol)
        }
        .padding(isBuiltin ? 6 : 10)
        .glassEffect(in: Circle())
        .font(.caption.bold())
        .tint(.primary)
        .offset(x: -6, y: -6)
    }

    // MARK: - Layout resolution

    private func isResolvable(_ tile: InsightTile) -> Bool {
        switch tile.kind {
        case .builtin:
            return true
        case .categoryBudget(let id):
            return categories.contains { $0.persistentModelID == id }
        case .overallBudget:
            return overallBudget.isEnabled
        case .fund(let id):
            return freestandingBudgets.contains { $0.persistentModelID == id }
        }
    }

    /// Rebuilds `transactionsByCategory` (keyed by category name, matching
    /// `categoriedTransactions`) so category tiles look up their slice instead of
    /// re-scanning all transactions per tile.
    private func rebuildCategoryIndex() {
        var grouped: [String: [Transaction]] = [:]
        for transaction in transactions {
            guard let name = transaction.category?.name else { continue }
            grouped[name, default: []].append(transaction)
        }
        transactionsByCategory = grouped
    }

    // MARK: - Add menu contents

    private var addableOverall: Bool {
        overallBudget.isEnabled && !tiles.contains { $0.kind == .overallBudget }
    }

    private var addableCategories: [Category] {
        categories.filter { category in
            (category.budget?.hasBudget ?? false)
                && !tiles.contains { $0.kind == .categoryBudget(category.persistentModelID) }
        }
    }

    private var addableFreestandingBudgets: [Budget] {
        freestandingBudgets.filter { budget in
            !tiles.contains { $0.kind == .fund(budget.persistentModelID) }
        }
    }

    // MARK: - Mutations

    private func add(_ kind: InsightTileKind) {
        guard !tiles.contains(where: { $0.kind == kind }) else { return }
        tiles.append(InsightTile(kind: kind))
        persist()
    }

    private func remove(_ tile: InsightTile) {
        tiles.removeAll { $0.id == tile.id }
        persist()
    }

    private func toggleHidden(_ tile: InsightTile) {
        guard let index = tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        tiles[index].isHidden.toggle()
        persist()
    }

    // MARK: - Persistence

    private func loadTiles() {
        var loaded: [InsightTile]
        if let decoded = try? JSONDecoder().decode([InsightTile].self, from: layoutStore), !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = InsightsOptions.allCases.map { InsightTile(kind: .builtin($0)) }
        }

        // Future-proof: make sure every built-in option is present even if the
        // stored layout predates a newly added one.
        for option in InsightsOptions.allCases where !loaded.contains(where: { $0.kind == .builtin(option) }) {
            loaded.append(InsightTile(kind: .builtin(option)))
        }

        tiles = loaded
    }

    private func persist() {
        layoutStore = (try? JSONEncoder().encode(tiles)) ?? Data()
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
        .frame(height: 70)
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
            .frame(width: 70, height: 70)

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
        .frame(height: 70)
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
        .frame(height: 70)
    }
}
