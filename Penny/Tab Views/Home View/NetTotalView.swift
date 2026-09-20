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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @State private var netTotalSheet = false

    @State private var breakdown: NetTotalBreakdown?

    @State private var navRoute: NetTotalRoute?
    /// Same destinations as `navRoute`, but presented full-screen. Used instead of
    /// `navRoute` when we're in the regular-width side-by-side layout, where a pushed
    /// destination would otherwise be squeezed into HomeView's own pane instead of
    /// covering the whole screen.
    @State private var coverRoute: NetTotalRoute?
    
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

    /// Destinations reachable from the income/expense buttons. Programmatic
    /// navigation (Button + `navigationDestination`) rather than `NavigationLink`
    /// so the tap can fire a haptic in its action, matching the rest of the app.
    /// `Identifiable` (in addition to `Hashable`) so it can also drive `fullScreenCover(item:)`.
    private enum NetTotalRoute: Hashable, Identifiable {
        case budgets
        case insights

        var id: Self { self }
    }

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
    
    /// Recomputes the components that sum to the net total, using the same helper the
    /// displayed total is derived from so the breakdown always reconciles. Budgets are
    /// fetched on demand (only when the sheet opens) since the reserve depends on them.
    private func computeBreakdown() -> NetTotalBreakdown {
        let budgets = (try? modelContext.fetch(FetchDescriptor<Budget>())) ?? []
        let housings = (try? modelContext.fetch(FetchDescriptor<Housing>())) ?? []
        return netTotalBreakdown(for: transactions, budgets: budgets, housings: housings)
    }

    /// Routes to the destination for `route` — pushed within HomeView's own stack when
    /// compact (already fills the screen), or presented full-screen when regular-width
    /// (side-by-side layout), so it covers both panes instead of just the left one.
    private func open(_ route: NetTotalRoute) {
        haptics += 1
        if horizontalSizeClass == .regular {
            coverRoute = route
        } else {
            navRoute = route
        }
    }

    @ViewBuilder
    private func destination(for route: NetTotalRoute) -> some View {
        switch route {
        case .budgets:  BudgetView()
        case .insights: InsightsView()
        }
    }

    var body: some View {
        VStack {
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
                    .padding(20)
                    .frame(maxWidth: 200, maxHeight: .infinity)
                }
                .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 36))
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
                        open(.budgets)
                    } label: {
                        HStack {
                            Label("Budgets", systemImage: "rectangle.grid.2x2.fill")
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: 200, maxHeight: .infinity) // Stretch!
                    .glassEffect(.clear.interactive())
                    
                    Button {
                        open(.insights)
                    } label: {
                        HStack {
                            Label("Insights", systemImage: "chart.bar.fill")
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
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
            .navigationDestination(item: $navRoute) { route in
                destination(for: route)
            }
        }
        .sheet(isPresented: $netTotalSheet) {
            NavigationStack {
                List {
                    Section {
                        HStack {
                            Text("Net Total")
                                .font(.headline)
                            Spacer()
                            Text(netTotal, format: .currency(code: currencyCode))
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(totalColor)
                        }
                    }

                    if let breakdown {
                        ForEach(breakdown.groups) { group in
                            // Only show a group that has at least one non-negligible item
                            let items = group.items.filter { abs($0.value) >= 0.005 }
                            if !items.isEmpty {
                                Section {
                                    ForEach(items) { item in
                                        HStack {
                                            Text(item.label)
                                            Spacer()
                                            Text(item.value, format: .currency(code: currencyCode))
                                                .monospacedDigit()
                                                .foregroundStyle(item.value < 0 ? Color.red : .primary)
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text(group.title)
                                        Spacer()
                                        Text(group.subtotal, format: .currency(code: currencyCode))
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .navigationTitle("Net Total")
                .toolbarTitleDisplayMode(.inline)
            }
            .task { breakdown = computeBreakdown() }
        }
        .fullScreenCover(item: $coverRoute) { route in
            NavigationStack {
                destination(for: route)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                coverRoute = nil
                            } label: {
                                Label("Close", systemImage: "xmark")
                            }
                        }
                    }
            }
        }
    }
}
