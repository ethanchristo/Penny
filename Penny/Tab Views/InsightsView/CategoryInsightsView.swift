//
//  CategoryInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 7/17/26.
//

import Charts
import SwiftData
import SwiftUI

struct CategoryInsightsView: View {
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]

    @Namespace private var namespace

    @State private var windowTimeRange: HomeTimeRange = .monthly
    @State private var dateOffset: Int = 0

    @State private var showAddTransaction: Bool = false
    @State private var editingTransaction: Transaction?

    private var window: (start: Date, end: Date) {
        dateWindow()
    }

    /// The window's expense transactions (funds excluded), newest-first, feeding
    /// the list below the chart.
    private var windowedTransactions: [Transaction] {
        let calendar = Calendar.current
        let expenses = typedTransactions(for: transactions, income: false)
        return expenses
            .filter { occurs($0, from: window.start, to: window.end, calendar: calendar) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        AdaptiveSplitLayout {
            CategoryPieChartView(
                transactions: transactions,
                categories: categories,
                window: window
            )
        } transactions: {
            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: windowedTransactions,
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: false,
                hideUpcoming: true,
                hideAllTx: false,
                searchString: "",
                filterIsIncome: false
            )
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Categories")
        .navigationSubtitle(windowTimeRange.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .background {
            LinearGradient(
                colors: [.purple.opacity(0.35), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
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
}

/// The full-size donut chart of spending by category, with the window total in
/// the center and a legend listing each category's share.
struct CategoryPieChartView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    let transactions: [Transaction]
    let categories: [Category]
    let window: (start: Date, end: Date)

    private var slices: [CategorySlice] {
        categorySpendData(transactions: transactions, categories: categories, window: window)
    }

    private var total: Double {
        slices.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 24) {
            if slices.isEmpty {
                ContentUnavailableView(
                    "No Spending",
                    systemImage: "chart.pie",
                    description: Text("There are no categorized expenses for this period.")
                )
                .frame(height: 240)
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Amount", slice.amount),
                        innerRadius: .ratio(0.62),
                        angularInset: 2
                    )
                    .foregroundStyle(slice.color.gradient)
                    .cornerRadius(6)
                    .shadow(color: slice.color, radius: 5)
                }
                .chartLegend(.hidden)
                .frame(height: 240)
                .overlay {
                    VStack(spacing: 2) {
                        Text("Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(amountTruncation(for: total, currencySymbol: currencySymbol))
                            .font(.title2.bold())
                            .contentTransition(.numericText())
                    }
                    .padding()
                    .glassEffect()
                }
                .animation(.smooth, value: slices)
                .padding(.horizontal)

                VStack(spacing: 10) {
                    ForEach(slices) { slice in
                        InsightBreakdownRow(
                            symbol: slice.symbol,
                            name: slice.name,
                            color: slice.color,
                            share: total > 0 ? slice.amount / total : 0,
                            amount: slice.amount
                        )
                    }
                }
                .padding(.horizontal)
                .animation(.smooth, value: slices)
            }
        }
        .padding(.top)
    }
}
