//
//  CashFlowInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 7/17/26.
//

import SwiftData
import SwiftUI

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
            .filter { $0.budget == nil }
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
