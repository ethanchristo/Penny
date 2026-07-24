//
//  BudgetView.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import Charts
import SwiftData
import SwiftUI

struct BudgetView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(OverallBudget.self) private var overallBudget
    @Environment(AppRouter.self) private var router

    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var account: [Account]
    @Query private var transactions: [Transaction]
    
    @Namespace private var namespace

    @State private var showAddTransaction = false
    @State private var showAddCategoryTransaction: Category?
    
    @State private var editingOverallBudget = false
    @State private var editingBudget: Category?
    
    @State private var selectedRoute: BudgetRoute?

    @State private var showCategorySheet = false
    
    private enum BudgetRoute: Hashable {
        case overall
        case category(Category)
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 10)
    ]
        
    private var budgetedCategories: [Category] {
        categories.filter { $0.budget?.hasBudget ?? true }
    }
    
    var body: some View {
        Group {
            if budgetedCategories.isEmpty && !overallBudget.isEnabled {
                VStack(spacing: 5) {
                    Image(systemName: "xmark.seal")
                        .font(.system(size: 130))
                        .foregroundStyle(.tertiary)
                    
                    Text("No budgets found")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if overallBudget.isEnabled {
                        Button {
                            selectedRoute = .overall
                        } label: {
                            SharedBudgetCell(source: .overall(overallBudget, filter: transactions))
                        }
                        .matchedTransitionSource(id: "overallInsights", in: namespace)
                        .contextMenu {
                            Button {
                                showAddTransaction = true
                            } label: {
                                Label("Add Transaction", systemImage: "list.bullet.rectangle.portrait")
                            }
                            
                            Button {
                                editingOverallBudget = true
                            } label: {
                                Label("Edit Budget", systemImage: "pencil")
                            }
                            .matchedTransitionSource(id: "editOverall", in: namespace)
                            
                            Divider()
                            
                            Button(role: .destructive) {
                                overallBudget.isEnabled = false
                            } label: {
                                Label("Turn Off Overall Budget", systemImage: "minus.circle")
                            }
                        }
                        .padding(.bottom, 26)
                        
                        if !budgetedCategories.isEmpty {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(budgetedCategories) { category in
                                    let filteredTransactions = categoriedTransactions(for: transactions, with: category)
                                    
                                    Button {
                                        selectedRoute = .category(category)
                                    } label: {
                                        SharedBudgetCell(source: .category(category, filter: filteredTransactions))
                                    }
                                    .matchedTransitionSource(id: category.id, in: namespace)
                                    .contextMenu {
                                        Button {
                                            showAddCategoryTransaction = category
                                        } label: {
                                            Label("Add Transaction", systemImage: "list.bullet.rectangle.portrait")
                                        }
                                        .matchedTransitionSource(id: "addCategoryTransaction", in: namespace)
                                        
                                        Button {
                                            editingBudget = category
                                        } label: {
                                            Label("Edit Category", systemImage: "pencil")
                                        }
                                        .matchedTransitionSource(id: "editCategory", in: namespace)
                                        
                                        
                                        Divider()
                                        
                                        Button(role: .destructive) {
                                            category.budget?.hasBudget = false
                                        } label: {
                                            Label("Turn Off Budget", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationDestination(item: $selectedRoute) { route in
            switch route {
            case .overall:
                BudgetInsightsView(namespace: namespace, source: .overall(overallBudget, filter: transactions))
            case .category(let category):
                let filteredTransactions = categoriedTransactions(for: transactions, with: category)
                BudgetInsightsView(namespace: namespace, source: .category(category, filter: filteredTransactions))
            }
        }
        .onChange(of: router.budgetToOpen, initial: true) { _, id in
            guard let id,
                  let category = categories.first(where: { $0.budget?.id == id }) else { return }
            selectedRoute = .category(category)
            router.budgetToOpen = nil
        }
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.large)
//            .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Budget", systemImage: "plus") {
                    showCategorySheet = true
                }
                .matchedTransitionSource(id: "addBudget", in: namespace)
            }
        }
        .sheet(item: $showAddCategoryTransaction) { category in
            NavigationStack {
                SingleTransactionView(initialEditMode: true, transaction: nil, category: category, fund: nil)
            }
            .navigationTransition(.zoom(sourceID: "addCategoryTransaction", in: namespace))
        }
        .sheet(isPresented: $editingOverallBudget) {
            NavigationStack {
                OverallBudgetSettingsView(bindableOverall: overallBudget)
            }
            .navigationTransition(.zoom(sourceID: "editOverall", in: namespace))
        }
        .sheet(item: $editingBudget) { category in
            NavigationStack {
                BudgetSettingsViewInfo(category: category)
            }
            .navigationTransition(.zoom(sourceID: "editCategory", in: namespace))
        }
        .sheet(isPresented: $showCategorySheet) {
            NavigationStack {
                BudgetSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showCategorySheet = false
                            } label: {
                                Label("Dismiss", systemImage: "xmark")
                            }
                        }
                    }
            }
            .navigationTransition(.zoom(sourceID: "addBudget", in: namespace))
        }
    }
}

struct SharedBudgetCell: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.colorScheme) private var colorScheme
    
    let source: BudgetInsightsView.Source
    /// Interactive Liquid Glass installs its own drag recognizer, which competes
    /// with the reorder lift gesture. Callers that host the cell in a reorderable
    /// container pass `false` so drag-to-reorder works.
    var interactive: Bool = true
    
    private var title: String {
        switch source {
        case .category(let cat, _): return "\(cat.symbol)  \(cat.name)"
        case .overall: return "Overall Budget"
        }
    }
    
    private var color: Color {
        switch source {
        case .category(let cat, _): return cat.color
        case .overall: return .gray
        }
    }
    
    private var budgetLimit: Double {
        switch source {
        case .category(let cat, _): return cat.budget?.budget ?? 0.0
        case .overall(let over, _): return over.budget
        }
    }
    
    private var currentWindow: BudgetWindow {
        switch source {
        case .category(let cat, _): return cat.budget?.budgetWindow ?? .monthly
        case .overall(let over, _): return over.budgetWindow
        }
    }
    
    private var spentTotal: Double {
        switch source {
        case .category(let cat, let txs):
            return budgetTotal(for: cat, in: txs, by: 0)
        case .overall(let over, let txs):
            return overallBudgetTotal(for: over, in: txs, by: 0)
        }
    }
    
    private var remainingTotal: Double {
        if spentTotal > budgetLimit {
            0.0
        } else {
            budgetLimit - spentTotal
        }
    }
    
    private var displayTotal: String {
        amountTruncation(for: (abs(budgetLimit - spentTotal)))
    }
    
    private var overBudget: String {
        if budgetLimit - spentTotal < 0 {
            "over"
        } else {
            "remaining"
        }
    }
    
    private var budgetButtonColor: Color {
        colorScheme == .light ? .black : .white
    }
    
    var body: some View {
        VStack {
            HStack {
                Text(title)
                    .font(source.isOverall ? .title3.bold() : .headline)
                    .lineLimit(1)
                
                Spacer()
                
                let data = [
                    (name: "spent", value: spentTotal, color: color.opacity(0.3)),
                    (name: "remaining", value: remainingTotal, color: color)
                ]

                Chart(data, id: \.name) { name, value, color in
                    SectorMark(
                        angle: .value("Value", value),
                        innerRadius: .ratio(0.618),
                        angularInset: 1
                    )
                    .cornerRadius(2)
                    .foregroundStyle(color)
                }
                .frame(width: source.isOverall ? 30 : 20, height: source.isOverall ? 30 : 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top)
            .padding(.bottom, source.isOverall ? 60 : 40)
            
            VStack(alignment: .leading) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(currencySymbol)
                        .foregroundStyle(color.mix(with: budgetButtonColor, by: 0.4))
                        .font(source.isOverall ? .title2.bold() : .title3.bold())
                    
                    Text(displayTotal)
                        .font(source.isOverall ? .largeTitle.bold() : .title.bold())
                }
                
                HStack(spacing: 0) {
                    Text(overBudget)
                        .underline()
                    Text(" \(budgetWindowText(from: currentWindow))")
                }
                .font(source.isOverall ? .callout : .footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom)
        }
        .padding(.leading, source.isOverall ? 20 : 16)
        .padding(.trailing)
        .frame(maxWidth: source.isOverall ? 370 : .infinity)
        .foregroundStyle(color.mix(with: budgetButtonColor, by: 0.7))
        .glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: 26))
        .background {
            RoundedRectangle(cornerRadius: 26)
            .fill(
                LinearGradient(
                    colors: [color, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

extension BudgetInsightsView.Source {
    var isOverall: Bool {
        if case .overall = self { return true }
        return false
    }

    /// The zoom-transition source ID, matching the `matchedTransitionSource`
    /// used on the budget cells in `BudgetView`.
    var transitionID: AnyHashable {
        switch self {
        case .category(let category, _): return category.id
        case .overall: return "overallInsights"
        }
    }
}
