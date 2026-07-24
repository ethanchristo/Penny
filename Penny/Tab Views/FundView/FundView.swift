//
//  FundView.swift
//  Penny
//
//  Created by Ethan Christo on 6/4/26.
//

import Charts
import SwiftData
import SwiftUI

struct FundView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) var modelContext

    @Query(sort: \Fund.name) private var funds: [Fund]
    
    @Namespace private var namespace

    @State private var showAddFund = false
    @State private var editingFund: Fund?
    @State private var deepLinkedFund: Fund?

    @State private var showEndedFunds = false
    
    private var endedFunds: [Fund] {
        funds.filter { $0.end < Date.now.startOfDay }
    }

    private var ongoingFunds: [Fund] {
        funds.filter { $0.end >= Date.now.startOfDay }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 10)
    ]

    var body: some View {
        Group {
            if funds.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "xmark.seal")
                        .font(.system(size: 130))
                        .foregroundStyle(.tertiary)
                    
                    Text("No funds found")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        if !endedFunds.isEmpty {
                            Section {
                                if showEndedFunds {
                                    ForEach(endedFunds) { fund in
                                        fundLink(for: fund)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("Ended")
                                    
                                    Text("(\(endedFunds.count))")
                                        .foregroundStyle(Color.secondary)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.up")
                                        .foregroundStyle(Color.secondary)
                                        .rotationEffect(.degrees(showEndedFunds ? 180 : 0))
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .onTapGesture {
                                    withAnimation(.snappy) {
                                        showEndedFunds.toggle()
                                    }
                                }
                            }
                        }
                        
                        if !ongoingFunds.isEmpty {
                            Section {
                                ForEach(ongoingFunds) { fund in
                                    fundLink(for: fund)
                                }
                            } header: {
                                HStack {
                                    Text("Ongoing")
                                        .font(.headline)
                                    
                                    Text("(\(ongoingFunds.count))")
                                        .font(.headline)
                                        .foregroundStyle(Color.secondary)
                                    
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Funds")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddFund = true
                } label: {
                    Label("Add Fund", systemImage: "plus")
                }
                .matchedTransitionSource(id: "addFund", in: namespace)
            }
        }
        .navigationDestination(item: $deepLinkedFund) { fund in
            FundInsightsView(fund: fund, namespace: namespace)
        }
        .onChange(of: router.fundToOpen, initial: true) { _, id in
            guard let id, let fund = funds.first(where: { $0.id == id }) else { return }
            deepLinkedFund = fund
            router.fundToOpen = nil
        }
        .sheet(isPresented: $showAddFund) {
            NavigationStack {
                EditFundView(fund: nil)
            }
            .navigationTransition(.zoom(sourceID: "addFund", in: namespace))
        }
        .sheet(item: $editingFund) { fund in
            NavigationStack {
                EditFundView(fund: fund)
            }
        }
    }

    @ViewBuilder
    private func fundLink(for fund: Fund) -> some View {
        NavigationLink {
            FundInsightsView(fund: fund, namespace: namespace)
        } label: {
            FundCell(fund: fund)
        }
        .matchedTransitionSource(id: fund.id, in: namespace)
        .contextMenu {
            Button(role: .destructive) {
                modelContext.delete(fund)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct FundCell: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.colorScheme) private var colorScheme

    let fund: Fund
    /// Interactive Liquid Glass installs its own drag recognizer, which competes
    /// with the reorder lift gesture. Callers that host the cell in a reorderable
    /// container pass `false` so drag-to-reorder works.
    var interactive: Bool = true

    private var displayTotal: String {
        if fund.remaining >= 0 {
            amountTruncation(for: fund.remaining)
        } else {
            amountTruncation(for: abs(fund.remaining))
        }
    }
    private var description: String {
        if fund.preAllocate {
            if fund.used <= fund.goal {
                "remaining"
            } else {
                "over"
            }
        } else {
            if fund.used == 0 {
                "contributed"
            } else {
                if fund.remaining >= 0 {
                    "used"
                } else {
                    "over"
                }
            }
        }
    }
    
    private var explanation: String {
        if !fund.preAllocate {
            if fund.used == 0 {
                " of the \(amountTruncation(for: fund.goal, currencySymbol: currencySymbol)) goal"
            } else {
                if fund.remaining >= 0 {
                    " of the \(amountTruncation(for: fund.contributed, currencySymbol: currencySymbol)) contributed"
                } else {
                    " the \(amountTruncation(for: fund.contributed, currencySymbol: currencySymbol)) contributed"
                }
            }
        } else {
            if fund.used <= fund.goal {
                " of the \(amountTruncation(for: fund.goal, currencySymbol: currencySymbol)) allocated"
            } else {
                " the \(amountTruncation(for: fund.goal, currencySymbol: currencySymbol)) allocated"
            }
        }
    }

    private var fundButtonColor: Color {
        colorScheme == .light ? .black : .white
    }

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                HStack {
                    Text(fund.symbol)
                    Text(fund.name)
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
//            .padding(.bottom, 40)
            Spacer(minLength: 40)

            VStack(alignment: .leading) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(currencySymbol)
                        .font(.title3.bold())
                        .foregroundStyle(fund.color.mix(with: fundButtonColor, by: 0.4))
                    
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
        .foregroundStyle(fund.color.mix(with: fundButtonColor, by: 0.7))
        .glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: 26))
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: [fund.color, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
    
    private func chartData() -> [(String, Double, Color)] {
        var first = (name: "", value: 0.0, color: Color.clear)
        var second = (name: "", value: 0.0, color: Color.clear)
        
        if fund.preAllocate || fund.used != 0 {
            let name1 = "remaining"
            let value1 = fund.remaining
            let color1 = fund.color
            
            let name2 = "used"
            let value2 = fund.used
            let color2 = fund.color.opacity(0.3)
            
            first = (name: name1, value: value1, color: color1)
            second = (name: name2, value: value2, color: color2)
        } else {
            let name1 = "progress"
            let value1 = fund.progress
            let color1 = fund.color
            
            let name2 = "remaining"
            let value2 = fund.remaining
            let color2 = fund.color.opacity(0.3)
            
            first = (name: name1, value: value1, color: color1)
            second = (name: name2, value: value2, color: color2)
        }
        
        return [first, second]
    }
}
