//
//  FreestandingBudgetInsightsView.swift
//  Penny
//
//  Created by Ethan Christo on 8/15/26.
//
//  The detail + cell for a freestanding (non-category) budget — the presentation
//  formerly provided by FundInsightsView / FundCell, retyped onto the unified Budget
//  model (goal → amount, preAllocate → preFunding).

import Charts
import SwiftData
import SwiftUI

struct FreestandingBudgetInsightsView: View {
    @Query var transactions: [Transaction]

    @State private var editingBudget: Budget?
    @State private var addTransaction = false
    @State private var editingTransaction: Transaction?

    let budget: Budget
    let namespace: Namespace.ID

    var body: some View {
        ScrollView {
            FreestandingBudgetChartView(budget: budget)
                .padding(.top)

            SquigglyLine(wavelength: 16, amplitude: 2)
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(height: 12)
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
                filterBudget: budget
            )
        }
        .navigationTransition(.zoom(sourceID: budget.id, in: namespace))
        .background {
            LinearGradient(
                colors: [budget.color.opacity(0.2), .clear, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("\(budget.symbol)  \(budget.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingBudget = budget
                } label: {
                    Label("Edit Budget", systemImage: "pencil")
                }
            }

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingBudget) { budget in
            NavigationStack {
                EditBudgetView(budget: budget)
            }
        }
        .sheet(isPresented: $addTransaction) {
            NavigationStack {
                SingleTransactionView(initialEditMode: true, transaction: nil as Transaction?, category: nil as Category?, budget: budget)
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, budget: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
    }
}

struct FreestandingBudgetChartView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @State private var showContributedSheet = false
    @State private var showGoalRemainingSheet = false
    @State private var showUsedSheet = false
    @State private var showRemainingSheet = false

    @State private var showSavingInfoSheet = false
    @State private var showUtilizationInfoSheet = false

    let budget: Budget

    var color: Color { budget.color }

    var contributedTotal: Double {
        budget.contributed > budget.amount ? budget.amount : budget.contributed
    }

    var goalRemaining: Double {
        budget.progress < 0.0 ? 0.0 : budget.progress
    }

    var remainingTotal: Double {
        budget.remaining < 0.0 ? 0.0 : budget.remaining
    }

    var remainingText: String {
        budget.remaining < 0.0 ? "over" : "remaining"
    }

    var body: some View {
        VStack(spacing: 25) {
            if !budget.preFunding {
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
                    let gapAmount = gapAmount(total: budget.amount)
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
                .frame(height: 25)
                .padding(.horizontal, 10)

                HStack(spacing: 20) {
                    Button {
                        showContributedSheet = true
                    } label: {
                        VStack {
                            Text(amountTruncation(for: budget.contributed, currencySymbol: currencySymbol))
                                .font(.title2.bold())

                            Text("contributed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tint(.primary)
                        .frame(maxWidth: .infinity)
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
                        .frame(maxWidth: .infinity)
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
                let gapAmount = gapAmount(total: (budget.used + remainingTotal))
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
                    xEnd: .value("End", remainingTotal + gapAmount + budget.used)
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
            .frame(height: 25)
            .padding(.horizontal, 10)

            HStack(spacing: 20) {
                Button {
                    showRemainingSheet = true
                } label: {
                    VStack {
                        Text(amountTruncation(for: abs(budget.remaining), currencySymbol: currencySymbol))
                            .font(.title2.bold())

                        Text(remainingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
                    .contentTransition(.numericText())
                }

                Button {
                    showUsedSheet = true
                } label: {
                    VStack {
                        Text(amountTruncation(for: budget.used, currencySymbol: currencySymbol))
                            .font(.title2.bold())

                        Text("used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.primary)
                    .frame(maxWidth: .infinity)
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
                Text(budget.contributed, format: .currency(code: currencyCode))
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
                Text(budget.used, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Used")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showRemainingSheet) {
            NavigationStack {
                Text(budget.remaining, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Remaining")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showSavingInfoSheet) {
            NavigationStack {
                Text("Contribution will show you how much you contributed to this budget and your progress toward its amount.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .presentationDetents([.fraction(0.3)])
                    .navigationTitle("Contribution Info")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showUtilizationInfoSheet) {
            NavigationStack {
                Text("If Pre-Funding is off, utilization shows how much you've used out of the amount contributed. If on, it shows how much you've used out of the budget amount.")
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

/// Grid cell for a freestanding budget (formerly `FundCell`).
struct FreestandingBudgetCell: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.colorScheme) private var colorScheme

    let budget: Budget
    /// Interactive Liquid Glass installs its own drag recognizer, which competes with a
    /// reorder lift gesture. Reorderable hosts pass `false`.
    var interactive: Bool = true

    private var displayTotal: String {
        budget.remaining >= 0
            ? amountTruncation(for: budget.remaining)
            : amountTruncation(for: abs(budget.remaining))
    }

    private var description: String {
        if budget.preFunding {
            return budget.used <= budget.amount ? "remaining" : "over"
        } else {
            if budget.used == 0 {
                return "contributed"
            } else {
                return budget.remaining >= 0 ? "used" : "over"
            }
        }
    }

    private var explanation: String {
        if !budget.preFunding {
            if budget.used == 0 {
                return " of the \(amountTruncation(for: budget.amount, currencySymbol: currencySymbol)) goal"
            } else {
                return budget.remaining >= 0
                    ? " of the \(amountTruncation(for: budget.contributed, currencySymbol: currencySymbol)) contributed"
                    : " the \(amountTruncation(for: budget.contributed, currencySymbol: currencySymbol)) contributed"
            }
        } else {
            return budget.used <= budget.amount
                ? " of the \(amountTruncation(for: budget.amount, currencySymbol: currencySymbol)) allocated"
                : " the \(amountTruncation(for: budget.amount, currencySymbol: currencySymbol)) allocated"
        }
    }

    private var buttonColor: Color {
        colorScheme == .light ? .black : .white
    }

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                HStack {
                    Text(budget.symbol)
                    Text(budget.name)
                }
                .font(.headline)
                .lineLimit(1)

                Spacer()

                let data: [(name: String, value: Double, color: Color)] = chartData()

                Chart(data, id: \.name) { name, value, color in
                    SectorMark(
                        angle: .value("Value", value),
                        innerRadius: .ratio(0.618),
                        angularInset: 1
                    )
                    .cornerRadius(2)
                    .foregroundStyle(color)
                }
                .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Spacer(minLength: 40)

            VStack(alignment: .leading) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(currencySymbol)
                        .font(.title3.bold())
                        .foregroundStyle(budget.color.mix(with: buttonColor, by: 0.4))

                    Text(displayTotal)
                        .font(.title.bold())
                }

                Text("\(Text(description).underline())\(explanation)")
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .foregroundStyle(budget.color.mix(with: buttonColor, by: 0.7))
        .glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: 26))
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: [budget.color, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private func chartData() -> [(String, Double, Color)] {
        var first = (name: "", value: 0.0, color: Color.clear)
        var second = (name: "", value: 0.0, color: Color.clear)

        if budget.preFunding || budget.used != 0 {
            first = (name: "remaining", value: budget.remaining, color: budget.color)
            second = (name: "used", value: budget.used, color: budget.color.opacity(0.3))
        } else {
            first = (name: "progress", value: budget.progress, color: budget.color)
            second = (name: "remaining", value: budget.remaining, color: budget.color.opacity(0.3))
        }

        return [first, second]
    }
}
