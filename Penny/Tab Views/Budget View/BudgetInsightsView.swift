//
//  BudgetInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 1/26/26.
//

import Charts
import SwiftData
import SwiftUI

struct BudgetInsightsView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(OverallBudget.self) private var overallBudget
                    
    @State private var dateOffset: Int? = 0
    @State private var selectedTimeRange: BudgetWindow = .monthly
    @State private var addTransaction = false
    @State private var editBudget = false
    
    @State private var searchText = ""
    @State private var filterAccount: Account? = nil
    @State private var filterCategory: Category? = nil
//    @State private var filterIsIncome: Bool? = nil
    
    let namespace: Namespace.ID

    private let range = -50...0
    
    enum Source {
        case category(Category, filter: [Transaction])
        case overall(OverallBudget, filter: [Transaction])
    }
    
    let source: Source
    
    private var transactions: [Transaction] {
        switch source {
        case .category(_, let txs): return txs
        case .overall(_, let txs): return txs
        }
    }
    
    private var name: String {
        switch source {
        case .category(let cat, _): return cat.name
        case .overall: return "Overall Budget"
        }
    }
    
    private var symbol: String? {
        switch source {
        case .category(let cat, _): return cat.symbol
        case .overall: return nil
        }
    }
    
    private var color: Color {
        switch source {
        case .category(let cat, _): return cat.color
        case .overall: return .gray
        }
    }
    
    private var currentWindow: BudgetWindow {
        switch source {
        case .category(let c, _): return c.budget?.budgetWindow ?? .monthly
        case .overall(let o, _): return o.budgetWindow
        }
    }
    
    private var budgetLimit: Double {
        switch source {
        case .category(let cat, _): return cat.budget?.budget ?? 0.0
        case .overall(let over, _): return over.budget
        }
    }
    
    private var editSheetOverall: Bool {
        switch source {
        case .overall: return true
        case .category: return false
        }
    }
            
    var body: some View {
        // Window + filter the transactions a single time; both the header's "spent"
        // figure and the transaction list below derive from this same slice.
        let pageTransactions = transactions(for: dateOffset ?? 0)

        ScrollView(.vertical, showsIndicators: false) {
            BudgetHeaderView(
                dateOffset: $dateOffset,
                spent: spent(for: dateOffset ?? 0, in: pageTransactions),
                budgetLimit: budgetLimit,
                currencyCode: currencyCode,
                color: color,
                symbol: symbol ?? ""
            )
            .padding(.top, 20)
            
            SquigglyLine(wavelength: 16, amplitude: 2)
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(height: 12) // Height should accommodate the amplitude
                .padding(.horizontal)
                .padding(.top, 8)

            CategoryTransactionPageView(
                transactionsForPage: pageTransactions,
                searchText: searchText,
                filterAccount: filterAccount,
                filterCategory: filterCategory,
                namespace: namespace
            )
            .animation(.smooth, value: dateOffset)
        }
        .navigationTransition(.zoom(sourceID: source.transitionID, in: namespace))
        .onAppear {
            selectedTimeRange = currentWindow
        }
        .background {
            LinearGradient(
                colors: [color.opacity(0.2), .clear, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("\(symbol ?? "") \(name)")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $addTransaction) {
            NavigationStack {
                // 🚨 Extract the category from the source enum!
                if case .category(let cat, _) = source {
                    // Pre-populate the specific category
                    SingleTransactionView(initialEditMode: true, transaction: nil, category: cat, budget: nil)
                } else {
                    // Overall budget doesn't have a specific category, so pass nil
                    SingleTransactionView(initialEditMode: true, transaction: nil, category: nil, budget: nil)
                }
            }
        }
        .sheet(isPresented: $editBudget) {
            if case .category(let cat, _) = source {
                NavigationStack {
                    EditCategoryView(category: cat)
                }
            } else {
                NavigationStack {
                    OverallBudgetSettingsView(bindableOverall: overallBudget)
                }
            }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", systemImage: "pencil") {
                    editBudget = true
                }
            }

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            ToolbarItem(placement: .topBarTrailing) {
                Button("Add transaction", systemImage: "plus") {
                    addTransaction = true
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous Period", systemImage: "chevron.left") {
                    dateOffset? -= 1
                }

                Spacer()

                Button {
                    dateOffset = 0
                } label: {
                    Text(dateDescription(for: dateOffset ?? 0))
                        .contentTransition(.numericText())
                }
                .animation(.bouncy, value: dateOffset)

                Spacer()

                Button("Next Period", systemImage: "chevron.right") {
                    if dateOffset == 0 { return }
                    dateOffset? += 1
                }
                .disabled(dateOffset == 0)
            }
        }
    }
        
    private func transactions(for offset: Int) -> [Transaction] {
        let windowDates = dateWindow(for: offset)
        let start = windowDates.start
        let end = windowDates.end
        
        let calendar = Calendar.current
        return transactions
            .sorted { $0.date > $1.date }
            .filter { occurs($0, from: start, to: end, calendar: calendar) }
    }
    
    private struct ChartPoint: Hashable {
        let label: String
        let amount: Double
    }
    
    private func chartData(for offset: Int) -> [ChartPoint] {
        let dates = dateWindow(for: offset)
        let calendar = Calendar.current
        var points: [ChartPoint] = []
        
        switch selectedTimeRange {
        case .yearly:
            // Breakdown by Month (Jan, Feb, Mar...)
            for month in 0..<12 {
                guard let monthDate = calendar.date(byAdding: .month, value: month, to: dates.start) else { continue }
                let barStart = monthDate.startOfMonth
                let barEnd = monthDate.endOfMonth
                
                let total = calculateTotal(for: transactions, start: barStart, end: barEnd)
                let label = monthDate.formatted(.dateTime.month(.abbreviated))
                
                points.append(ChartPoint(label: label, amount: total))
            }
            
        case .monthly:
            // Breakdown by Day (1, 2, 3...)
            let numberOfDays = calendar.dateComponents([.day], from: dates.start, to: dates.end).day ?? 0
            for dayOffset in 0...max(0, numberOfDays) {
                guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: dates.start) else { continue }
                let barStart = dayDate.startOfDay
                let barEnd = dayDate.endOfDay

                let total = calculateTotal(for: transactions, start: barStart, end: barEnd)
                let label = dayDate.formatted(.dateTime.day())
                points.append(ChartPoint(label: label, amount: total))
            }
            
        case .weekly:
            // Breakdown by Day of Week (Mon, Tue...)
            for dayOffset in 0...6 {
                guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: dates.start) else { continue }
                let barStart = dayDate.startOfDay
                let barEnd = dayDate.endOfDay

                let total = calculateTotal(for: transactions, start: barStart, end: barEnd)
                let label = dayDate.formatted(.dateTime.weekday(.abbreviated))
                points.append(ChartPoint(label: label, amount: total))
            }
            
        default:
            let total = calculateTotal(for: transactions, start: dates.start, end: dates.end)
            points.append(ChartPoint(label: "Total", amount: total))
        }
        
        return points
    }
    
    private func dateWindow(for offset: Int) -> (start: Date, end: Date) {
        // Single source of truth for BudgetWindow windowing, shared with the budget
        // total and its transaction list.
        budgetWindowBounds(for: selectedTimeRange, shiftAmount: offset)
    }
    
    private func dateDescription(for offset: Int) -> String {
        let dates = dateWindow(for: offset)
        if selectedTimeRange == .daily {
            return dates.start.formatted(.dateTime.month().day().year())
        } else if selectedTimeRange == .monthly {
            return dates.start.formatted(.dateTime.month().year())
        } else if selectedTimeRange == .yearly {
            return dates.start.formatted(.dateTime.year())
        } else {
            return "\(dates.start.formatted(.dateTime.month().day().year())) - \(dates.end.formatted(.dateTime.month().day().year()))"
        }
    }
    
    private func spent(for offset: Int, in currentTxs: [Transaction]) -> Double {
        switch source {
        case .category(let cat, _):
            return budgetTotal(for: cat, in: currentTxs, by: offset)
        case .overall(let over, _):
            return overallBudgetTotal(for: over, in: currentTxs, by: offset)
        }
    }
}

// 1. The Static Chart View (Hovering on top)
struct BudgetHeaderView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    
    @Binding var dateOffset: Int?
    
    @State private var showRemainingSheet = false
    @State private var showSpentSheet = false
    
    let spent: Double
    let budgetLimit: Double
    let currencyCode: String
    let color: Color
    let symbol: String // We keep this here so the parent view doesn't throw a missing parameter error!
    
    // 1. Pulled the exact math from your SharedBudgetCell!
    private var remainingTotal: Double {
        if spent > budgetLimit {
            0.0
        } else {
            budgetLimit - spent
        }
    }
    
    private var spentTotal: Double {
        if spent > budgetLimit {
            budgetLimit
        } else {
            spent
        }
    }
    
    private var gapAmount: Double {
        budgetLimit * 0.04
    }
    
    private var arrowPosition: Double {
        remainingTotal + (gapAmount / 2)
    }
    
    private var isOverBudget: String {
        if budgetLimit - spent < 0.0 { return "over budget" }
        return "remaining"
    }
    
    var body: some View {
        VStack(spacing: 25) {
            
            // THE NEW BAR CHART
            Chart {
                BarMark(
                    xStart: .value("Start", 0),
                    xEnd: .value("Remaining", remainingTotal)
                )
                .foregroundStyle(color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: color, radius: 8)
                
                BarMark(
                    xStart: .value("Spent", remainingTotal + gapAmount),
                    xEnd: .value("End", remainingTotal + gapAmount + spentTotal)
                )
                .foregroundStyle(color.gradient.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                RuleMark(x: .value("Remaining", arrowPosition))
                    .foregroundStyle(color.mix(with: .black, by: 0.2))
                    .annotation(position: .top) {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(color.mix(with: .black, by: 0.2).opacity(0.5))
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: 25) // Slightly taller than the home screen for emphasis!
            .padding(.horizontal, 10)
            .animation(.snappy(duration: 0.5), value: dateOffset ?? 0)
            
            // THE BUTTONS (Now side-by-side below the chart)
            HStack(spacing: 20) {
                Button {
                    showRemainingSheet = true
                } label: {
                    VStack {
                        // abs() prevents a negative sign if they go over budget!
                        Text(amountTruncation(for: abs(budgetLimit - spent), currencySymbol: currencySymbol))
                            .font(.title2.bold())
//                            .contentTransition(.numericText()) // Rolls the numbers!
                        
                        Text(isOverBudget)
                            .font(.caption)
                            .foregroundStyle(.secondary)
//                            .contentTransition(.numericText())
                    }
                    .tint(.primary)
                    .frame(maxWidth: .infinity) // Forces the buttons to be perfectly equal width
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    .contentTransition(.numericText())
//                    .animation(.bouncy, value: spent)
                }
                
                Button {
                    showSpentSheet = true
                } label: {
                    VStack {
                        Text(amountTruncation(for: spent, currencySymbol: currencySymbol))
                            .font(.title2.bold())
                        
                        Text("spent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.primary)
                    .frame(maxWidth: .infinity) // Forces the buttons to be perfectly equal width
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    .contentTransition(.numericText())
//                    .animation(.bouncy, value: spent)
                }
            }
            .animation(.bouncy, value: spent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        
        // SHEETS
        .sheet(isPresented: $showRemainingSheet) {
            NavigationStack {
                Text(abs(budgetLimit - spent), format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle(isOverBudget.capitalized)
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showSpentSheet) {
            NavigationStack {
                Text(spent, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Spent")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
    }
}

// 2. The Isolated Page View (Inside the TabView)
struct CategoryTransactionPageView: View {
    let transactionsForPage: [Transaction]
    let searchText: String
    let filterAccount: Account?
    let filterCategory: Category?
    let namespace: Namespace.ID
    
    @State private var editingTransaction: Transaction?
    
    var body: some View {
        TransactionFilteredView(
            editingTransaction: $editingTransaction,
            transactions: transactionsForPage,
            namespace: namespace,
            hideRecent: true,
            hideRecurrence: false,
            hideUpcoming: true,
            hideAllTx: false,
            searchString: searchText,
            filterAccount: filterAccount,
            filterCategory: filterCategory,
            filterIsIncome: false
        )
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, budget: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
    }
}
