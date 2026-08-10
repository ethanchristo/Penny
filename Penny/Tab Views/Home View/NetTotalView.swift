//
//  NetTotalView.swift
//  Penny
//
//  Created by Ethan Christo on 4/8/26.
//

import SwiftData
import SwiftUI

struct NetTotalView: View {
    @AppStorage("net_total_credit_mode", store: .group) private var creditMode: CreditCardBalanceType = .balance

    @Environment(\.colorScheme) private var colorScheme
    
    @State private var netTotalSheet = false
    @State private var netIncomeSheet = false
    @State private var netExpensesSheet = false
    
    @State private var haptics: Int = 0
    
    @Binding var selectedTimeRange: HomeTimeRange
    
    let modelContext: ModelContext
    let scenePhase: ScenePhase
    
    let scriptUrl: String
    let scriptSecret: String
    
    let currencyCode: String
    let currencySymbol: String
    
    // 1. Fetch ALL data here
    let transactions: [Transaction]
    let netIncome: Double
    let netExpenses: Double
    let netTotal: Double
    
    let backgroundColor: Color
                    
    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 15)
    ]
    
    private var totalColor: Color {
        if colorScheme == .dark {
            backgroundColor.mix(with: .white, by: 0.6)
        } else {
            backgroundColor.mix(with: .black, by: 0.6)
        }
    }
    
    var body: some View {    
        HStack(spacing: 12) {
            // LEFT SIDE: The big Net Total Button
            Button {
                haptics += 1
                netTotalSheet = true
            } label: {
                VStack(spacing: 4) {
                    Text("Net Total")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(creditMode.title.uppercased())
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer()

                    Text(amountTruncation(for: netTotal, currencySymbol: currencySymbol))
                        .font(.largeTitle.bold())
                        .foregroundStyle(totalColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .frame(maxWidth: 200, maxHeight: .infinity)
            }
            .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 30))
            .contextMenu {
                Picker("Credit Card Mode", selection: $creditMode) {
                    ForEach([CreditCardBalanceType.balance, .statement]) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsVisibility(.visible)
            }
            
            VStack(spacing: 15) {
                Button {
                    haptics += 1
                    netIncomeSheet = true
                } label: {
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        
                        Spacer()
                        
                        Text(amountTruncation(for: netIncome, currencySymbol: currencySymbol))
                            .bold()
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: 200, maxHeight: .infinity) // Stretch!
                .glassEffect(.clear.interactive())
                
                Button {
                    haptics += 1
                    netExpensesSheet = true
                } label: {
                    HStack {
                        Image(systemName: "tray.and.arrow.up")
                        
                        Spacer()
                        
                        Text(amountTruncation(for: netExpenses, currencySymbol: currencySymbol))
                            .bold()
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: 200, maxHeight: .infinity) // Stretch!
                .glassEffect(.clear.interactive())
            }
        }
        .tint(.primary)
        .frame(height: 160)
        .sensoryFeedback(.impact(weight: .heavy), trigger: haptics)
        
        .sheet(isPresented: $netTotalSheet) {
            NavigationStack {
                Text(netTotal, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Total")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $netIncomeSheet) {
            NavigationStack {
                Text(netIncome, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Income")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $netExpensesSheet) {
            NavigationStack {
                Text(netExpenses, format: .currency(code: currencyCode))
                    .font(Font.largeTitle.bold())
                    .presentationDetents([.fraction(0.2)])
                    .navigationTitle("Net Expenses")
                    .toolbarTitleDisplayMode(.inline)
            }
        }
    }
}
