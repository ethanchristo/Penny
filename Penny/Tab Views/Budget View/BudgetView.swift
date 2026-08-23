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
    @AppStorage("showEndedBudgets") private var showEndedBudgets = false

    @Environment(\.modelContext) private var modelContext
    @Environment(OverallBudget.self) private var overallBudget
    @Environment(AppRouter.self) private var router

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Budget.name) private var allBudgets: [Budget]
    @Query private var account: [Account]
    @Query private var transactions: [Transaction]

    @Namespace private var namespace

    @State private var showAddTransaction = false
    @State private var showAddCategoryTransaction: Category?

    @State private var editingOverallBudget = false
    @State private var editingBudget: Category?

    @State private var selectedRoute: BudgetRoute?

    @State private var showAddBudget = false
    
    private enum BudgetRoute: Hashable {
        case overall
        case category(Category)
        case freestanding(Budget)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 10)
    ]

    private var budgetedCategories: [Category] {
        categories.filter { $0.budget?.hasBudget ?? false }
    }

    /// Freestanding (non-category) budgets — the migrated funds and any new custom budgets.
    private var freestandingBudgets: [Budget] {
        allBudgets.filter { $0.isFreestanding && $0.hasBudget }
    }

    /// Recurring freestanding budgets. Shown alongside category budgets in the Recurring section.
    private var recurringFreestandingBudgets: [Budget] {
        freestandingBudgets.filter { $0.isRecurring }
    }

    /// One-time freestanding budgets that are still active.
    private var nonRecurringOngoingBudgets: [Budget] {
        freestandingBudgets.filter { !$0.isRecurring && ($0.end ?? .distantFuture) >= Date.now.startOfDay }
    }

    /// One-time freestanding budgets whose end date has passed. Recurring ones never end.
    private var endedBudgets: [Budget] {
        freestandingBudgets.filter { !$0.isRecurring && ($0.end ?? .distantFuture) < Date.now.startOfDay }
    }

    private var isEmpty: Bool {
        budgetedCategories.isEmpty && freestandingBudgets.isEmpty && !overallBudget.isEnabled
    }

    var body: some View {
        Group {
            if isEmpty {
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
                        .padding(.top)
                        
                    }

                    let recurringCount = budgetedCategories.count + recurringFreestandingBudgets.count
                    if recurringCount > 0 {
                        Section {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(budgetedCategories) { category in
                                    categoryLink(for: category)
                                }
                                ForEach(recurringFreestandingBudgets) { budget in
                                    freestandingLink(for: budget)
                                }
                            }
                            .padding(.horizontal, 10)
                        } header: {
                            sectionHeader("Recurring", count: recurringCount)
                        }
                        .padding(.top, 20)
                    }

                    if !nonRecurringOngoingBudgets.isEmpty {
                        Section {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(nonRecurringOngoingBudgets) { budget in
                                    freestandingLink(for: budget)
                                }
                            }
                            .padding(.horizontal, 10)
                        } header: {
                            sectionHeader("Non-Recurring", count: nonRecurringOngoingBudgets.count)
                        }
                    }

                    if !endedBudgets.isEmpty {
                        Section {
                            if showEndedBudgets {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(endedBudgets) { budget in
                                        freestandingLink(for: budget)
                                    }
                                }
                                .padding(.horizontal, 10)
                            }
                        } header: {
                            HStack {
                                Text("Ended")
                                Text("(\(endedBudgets.count))")
                                    .foregroundStyle(Color.secondary)
                                Spacer()
                                Image(systemName: "chevron.up")
                                    .foregroundStyle(Color.secondary)
                                    .rotationEffect(.degrees(showEndedBudgets ? 180 : 0))
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .onTapGesture {
                                withAnimation(.snappy) { showEndedBudgets.toggle() }
                            }
                            .sensoryFeedback(.impact(weight: .light), trigger: showEndedBudgets)
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
            case .freestanding(let budget):
                FreestandingBudgetInsightsView(budget: budget, namespace: namespace)
            }
        }
        .onChange(of: router.budgetToOpen, initial: true) { _, id in
            guard let id else { return }
            // A budget deep-link id can resolve to either a category budget or a
            // freestanding one; try category first, then freestanding.
            if let category = categories.first(where: { $0.budget?.id == id }) {
                selectedRoute = .category(category)
            } else if let budget = freestandingBudgets.first(where: { $0.id == id }) {
                selectedRoute = .freestanding(budget)
            }
            router.budgetToOpen = nil
        }
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Once an overall budget exists the plus just adds another budget; until
                // then it offers a choice between setting up the overall budget or adding
                // an ordinary one.
                if overallBudget.isEnabled {
                    Button("Add Budget", systemImage: "plus") {
                        showAddBudget = true
                    }
                    .matchedTransitionSource(id: "addBudget", in: namespace)
                } else {
                    Menu {
                        Button {
                            editingOverallBudget = true
                        } label: {
                            Label("Overall Budget", systemImage: "chart.pie")
                        }

                        Button {
                            showAddBudget = true
                        } label: {
                            Label("Other Budget", systemImage: "rectangle.stack.badge.plus")
                        }
                    } label: {
                        Label("Add Budget", systemImage: "plus")
                    }
                    .matchedTransitionSource(id: "addBudget", in: namespace)
                }
            }
        }
        .sheet(item: $showAddCategoryTransaction) { category in
            NavigationStack {
                SingleTransactionView(initialEditMode: true, transaction: nil, category: category, budget: nil)
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
        .sheet(isPresented: $showAddBudget) {
            NavigationStack {
                EditBudgetView(budget: nil)
            }
            .navigationTransition(.zoom(sourceID: "addBudget", in: namespace))
        }
        .sheet(item: $editingBudgetSheet) { budget in
            NavigationStack {
                EditBudgetView(budget: budget)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Text("(\(count))")
                .font(.headline)
                .foregroundStyle(Color.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    @ViewBuilder
    private func categoryLink(for category: Category) -> some View {
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

    @ViewBuilder
    private func freestandingLink(for budget: Budget) -> some View {
        Button {
            selectedRoute = .freestanding(budget)
        } label: {
            FreestandingBudgetCell(budget: budget)
        }
        .matchedTransitionSource(id: budget.id, in: namespace)
        .contextMenu {
            Button {
                editingBudgetSheet = budget
            } label: {
                Label("Edit Budget", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                modelContext.delete(budget)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @State private var editingBudgetSheet: Budget?
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
