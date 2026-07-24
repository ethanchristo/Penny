//
//  FundInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 6/5/26.
//

import Charts
import SwiftData
import SwiftUI

struct FundInsightsView: View {
    @Query var transactions: [Transaction]

    @State private var editingFund: Fund?
    @State private var addTransaction = false
    @State private var editingTransaction: Transaction?

    let fund: Fund
    let namespace: Namespace.ID

    var body: some View {
        ScrollView {
            FundInsightsChartView(fund: fund)
                .padding(.top)
            
            SquigglyLine(wavelength: 16, amplitude: 2)
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(height: 12) // Height should accommodate the amplitude
                .padding(.horizontal)
                .padding(.top, 6)

            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: transactions,
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: true,
                hideUpcoming: true,
                hideAllTx: false,
                searchString: "",
                filterFund: fund
            )

        }
        .navigationTransition(.zoom(sourceID: fund.id, in: namespace))
        .background {
            LinearGradient(
                colors: [fund.color.opacity(0.2), .clear, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("\(fund.symbol)  \(fund.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingFund = fund
                } label: {
                    Label("Edit Fund", systemImage: "pencil")
                }
            }
            
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            
            ToolbarItem(placement: .topBarTrailing) {
                Button{
                    addTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingFund) { fund in
            NavigationStack {
                EditFundView(fund: fund)
            }
        }
        .sheet(isPresented: $addTransaction) {
            NavigationStack {
                SingleTransactionView(initialEditMode: true, transaction: nil as Transaction?, category: nil as Category?, fund: fund)
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, fund: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
    }
}

struct FundInsightsChartView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @State private var showContributedSheet = false
    @State private var showGoalRemainingSheet = false
    @State private var showUsedSheet = false
    @State private var showRemainingSheet = false

    @State private var showSavingInfoSheet = false
    @State private var showUtilizationInfoSheet = false

    let fund: Fund

    var color: Color {
        fund.color
    }

    var contributedTotal: Double {
        if fund.contributed > fund.goal {
            fund.goal
        } else {
            fund.contributed
        }
    }

    var goalRemaining: Double {
        if fund.progress < 0.0 {
            0.0
        } else {
            fund.progress
        }
    }

    var remainingTotal: Double {
        if fund.remaining < 0.0 {
            0.0
        } else {
            fund.remaining
        }
    }
    
    var remainingText: String {
        if fund.remaining < 0.0 {
            "over"
        } else {
            "remaining"
        }
    }

    var body: some View {
        VStack(spacing: 25) {
            if !fund.preAllocate {
                HStack {
                    Text("Contribution")
                        .font(.title3).bold()

                    Button {
                        showSavingInfoSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .tint(.secondary)

                    Spacer()
                }

                Chart {
                    let gapAmount = gapAmount(total: fund.goal)
                    let arrowPosition = contributedTotal + (gapAmount / 2)

                    BarMark(
                        xStart: .value("Start", 0.0),
                        xEnd: .value("Contributed", contributedTotal)
                    )
                    .foregroundStyle(color.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: color, radius: 8)

                    BarMark(
                        xStart: .value("Goal Remaining", contributedTotal + gapAmount),
                        xEnd: .value("End", contributedTotal + gapAmount + goalRemaining)
                    )
                    .foregroundStyle(color.gradient.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    RuleMark(x: .value("Goal Remaining", arrowPosition))
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

                // THE BUTTONS (Now side-by-side below the chart)
                HStack(spacing: 20) {
                    Button {
                        showContributedSheet = true
                    } label: {
                        VStack {
                            Text(amountTruncation(for: fund.contributed, currencySymbol: currencySymbol))
                                .font(.title2.bold())

                            Text("contributed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tint(.primary)
                        .frame(maxWidth: .infinity) // Forces the buttons to be perfectly equal width
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                        .contentTransition(.numericText())
                    }

                    Button {
                        showGoalRemainingSheet = true
                    } label: {
                        VStack {
                            Text(amountTruncation(for: goalRemaining, currencySymbol: currencySymbol))
                                .font(.title2.bold())

                            Text("left to go")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tint(.primary)
                        .frame(maxWidth: .infinity) // Forces the buttons to be perfectly equal width
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                        .contentTransition(.numericText())
                    }
                }
                .padding(.bottom)
            }

            HStack {
                Text("Utilization")
                    .font(.title3).bold()

                Button {
                    showUtilizationInfoSheet = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .tint(.secondary)

                Spacer()
            }

            Chart {
                // Use the displayed total (which becomes `used` once over budget)
                // so the gap stays visible no matter how far over we go.
                let gapAmount = gapAmount(total: (fund.used + remainingTotal))
                let arrowPosition = remainingTotal + (gapAmount / 2)

                BarMark(
                    xStart: .value("Start", 0.0),
                    xEnd: .value("Remaining", remainingTotal)
                )
                .foregroundStyle(color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: color, radius: 8)

                BarMark(
                    xStart: .value("Remaining", remainingTotal + gapAmount),
                    xEnd: .value("End", remainingTotal + gapAmount + fund.used)
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

            HStack(spacing: 20) {
                Button {
                     showRemainingSheet = true
                } label: {
                    VStack {
                        Text(amountTruncation(for: abs(fund.remaining), currencySymbol: currencySymbol))
                            .font(.title2.bold())

                        Text(remainingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.primary)
                    .frame(maxWidth: .infinity) // Forces the buttons to be perfectly equal width
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    .contentTransition(.numericText())
                }
                
                Button {
                    showUsedSheet = true
                } label: {
                    VStack {
                        Text(amountTruncation(for: fund.used, currencySymbol: currencySymbol))
                            .font(.title2.bold())

                        Text("used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.primary)
                    .frame(maxWidth: .infinity) // Forces the buttons to be perfectly equal width
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    .contentTransition(.numericText())
                }
            }
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)

        .sheet(isPresented: $showContributedSheet) {
            NavigationStack {
                Text(fund.contributed, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Contributed")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showGoalRemainingSheet) {
            NavigationStack {
                Text(goalRemaining, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Goal Remaining")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showUsedSheet) {
            NavigationStack {
                Text(fund.used, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Used")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showRemainingSheet) {
            NavigationStack {
                Text(fund.remaining, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Remaining")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showSavingInfoSheet) {
            NavigationStack {
                Text("Savings will show you how much you saved to this fund and your progress to this fund's goal.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .presentationDetents([.fraction(0.3)])
                    .navigationTitle("Saving Info")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showUtilizationInfoSheet) {
            NavigationStack {
                Text("If \"Use Fixed Amount Instead of Goal\" is turned off, utilization will show you how much you've used out of the amount contributed to this fund. If turned on, utilization will show you how much you've used out of the fund amount.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .presentationDetents([.fraction(0.3)])
                    .navigationTitle("Utilization Info")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
    }

    private func gapAmount(total: Double) -> Double {
        total * 0.05
    }
}
