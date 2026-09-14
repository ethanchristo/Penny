//
//  TransactionView.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import SwiftData
import SwiftUI

struct TransactionView: View {
    @AppStorage("default_checking_name") private var defaultCheckingName: String = "Checking"

    @Environment(\.modelContext) var modelContext
    @Environment(AppRouter.self) private var router
    // 1. Fetch ALL data here
    @Query(sort: \Transaction.date, order: .reverse) var transactions: [Transaction]
    @Query(sort: \Account.name) var accounts: [Account]
    @Query(sort: \Category.name) var categories: [Category]
    @Query(sort: \Budget.name) var budgets: [Budget]

    /// Only freestanding budgets can tag transactions, so only they filter the list.
    private var freestandingBudgets: [Budget] {
        budgets.filter { $0.isFreestanding && $0.hasBudget }
    }

    @State private var showAddTransaction = false
    @State private var editingTransaction: Transaction?

    // Drives the zoom transition from the Add button into the new-transaction sheet.
    @Namespace private var namespace
    
    @State private var searchText = ""
    @State private var filterAccount: Account? = nil
    @State private var filterCategory: Category? = nil
    @State private var filterBudget: Budget? = nil
    @State private var filterIsIncome: Bool? = nil
    
    @State private var sortOrder: CustomSortOrder = .dateReverse
    @State private var grouping: TransactionGrouping = .day

    /// Tints the view's background to match Home's net-total color when shown
    /// side by side with it in the `.regular` size class. Defaults to clear so
    /// standalone pushes (e.g. from "View All") stay untinted.
    var backgroundColor: Color = .clear

    private enum CustomSortOrder {
        case dateReverse
        case dateForward
        case aToZ
        case zToA
    }
    
    private var activeSortName: String {
        switch sortOrder {
        case .dateReverse: return "Newest First"
        case .dateForward: return "Oldest First"
        case .aToZ: return "A to Z"
        case .zToA: return "Z to A"
        }
    }
    
    // The grouping that actually applies: name-based sorts can't be grouped by date,
    // so they fall back to a flat list regardless of the chosen grouping.
    private var effectiveGrouping: TransactionGrouping {
        switch sortOrder {
        case .aToZ, .zToA: return .none
        case .dateReverse, .dateForward: return grouping
        }
    }
    
    // 2. The unified sorting logic
    var dynamicallySortedTransactions: [Transaction] {
        // `transactions` is pre-sorted newest-first by @Query — short-circuit when that matches.
        switch sortOrder {
        case .dateReverse:
            return transactions
        case .dateForward:
            return transactions.reversed()
        case .aToZ, .zToA:
            return transactions.sorted { t1, t2 in
                let name1 = !t1.notes.isEmpty ? t1.notes : (t1.category?.name ?? "")
                let name2 = !t2.notes.isEmpty ? t2.notes : (t2.category?.name ?? "")
                return sortOrder == .aToZ ? name1 < name2 : name1 > name2
            }
        }
    }
    
    // Note: If you want Date Range filtering, you must filter 'transactions' here
    // before passing them to the child view. For now, we pass all sorted transactions.
    
    var body: some View {
        ScrollView {
            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: dynamicallySortedTransactions,
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: false,
                hideUpcoming: true,
                hideAllTx: false,
                disableDateGrouping: effectiveGrouping == .none,
                grouping: effectiveGrouping,
                dateAscending: sortOrder == .dateForward,
                searchString: searchText,
                filterAccount: filterAccount,
                filterCategory: filterCategory,
                filterBudget: filterBudget,
                filterIsIncome: filterIsIncome
            )
            .searchable(text: $searchText)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background {
            LinearGradient(
                colors: [backgroundColor.opacity(0.7), .clear, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Menu {
                        Picker("Type", selection: $filterIsIncome) {
                            Label("All", systemImage: "tray.full").tag(nil as Bool?)
                            Label("Income", systemImage: "tray.and.arrow.down").tag(true as Bool?)
                            Label("Expense", systemImage: "tray.and.arrow.up").tag(false as Bool?)
                        }
                    } label: {
                        Label("By Type", systemImage: "tray")
                        if filterIsIncome == true {
                            Text("Income")
                                .font(.caption)
                        } else if filterIsIncome == false {
                            Text("Expense")
                                .font(.caption)
                        } else {
                            Text("All")
                                .font(.caption)
                        }
                    }
                    
                    Menu {
                        Picker("All", selection: $filterAccount) {
                            Text("All").tag(nil as Account?)
                        }
                        
                        Picker("Accounts", selection: $filterAccount) {
                            Text(defaultCheckingName).tag(nil as Account?)
                            
                            ForEach(accounts.filter { $0.accountType != .credit }) {
                                Text($0.name).tag($0 as Account?)
                            }
                        }
                        .labelsVisibility(.visible)
                            
                        Divider()

                            
                        Picker("Cards", selection: $filterAccount) {
                            ForEach(accounts.filter { $0.accountType == .credit }) { card in
                                Text(card.name).tag(card as Account?)
                            }
                        }
                        .labelsVisibility(.visible)

                    } label: {
                        Label("By Account", systemImage: "creditcard")
                        Text(filterAccount?.name ?? "All")
                            .font(.caption)
                    }
                    
                    Menu {
                        Picker("Category", selection: $filterCategory) {
                            Text("All").tag(nil as Category?)
                            ForEach(categories) { category in
                                Text("\(category.symbol) \(category.name)").tag(category as Category?)
                                
                            }
                        }
                    } label: {
                        Label("By Category", systemImage: "tag")
                        Text(filterCategory?.name ?? "All")
                            .font(.caption)
                    }
                    
                    Menu {
                        Picker("Budget", selection: $filterBudget) {
                            Text("All").tag(nil as Budget?)
                            ForEach(freestandingBudgets) { budget in
                                Text("\(budget.symbol) \(budget.name)").tag(budget as Budget?)

                            }
                        }
                    } label: {
                        Label("By Budget", systemImage: "rectangle.stack")
                        Text(filterBudget?.name ?? "All")
                            .font(.caption)
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                }
            }
            
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Menu {
                        Picker("Sort by Date", selection: $sortOrder) {
                            Text("Newest First").tag(CustomSortOrder.dateReverse)
                            Text("Oldest First").tag(CustomSortOrder.dateForward)
                        }
                    } label: {
                        Label("By Date", systemImage: "calendar")
                        Group {
                            if activeSortName == "Newest First" {
                                Text("Newest First")
                                    .font(.caption)
                            } else if activeSortName == "Oldest First" {
                                Text("Oldest First")
                                    .font(.caption)
                            } else { }
                        }
                    }
                    
                    Menu {
                        Picker("Sort by Name", selection: $sortOrder) {
                            Text("A to Z").tag(CustomSortOrder.aToZ)
                            Text("Z to A").tag(CustomSortOrder.zToA)
                        }
                    } label: {
                        Label("By Name", systemImage: "person.text.rectangle")
                        Group {
                            if activeSortName == "A to Z" {
                                Text("A to Z")
                                    .font(.caption)
                            } else if activeSortName == "Z to A" {
                                Text("Z to A")
                                    .font(.caption)
                            } else { }
                        }
                    }
                    
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Group by", selection: $grouping) {
                        ForEach(TransactionGrouping.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsVisibility(.visible)
                } label: {
                    Label("Group", systemImage: "ellipsis")
                    Text(effectiveGrouping.rawValue)
                        .font(.caption)
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddTransaction = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .matchedTransitionSource(id: "addTransaction", in: namespace)
            }
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
        .onChange(of: router.transactionToOpen, initial: true) { _, id in
            guard let id, let transaction = transactions.first(where: { $0.id == id }) else { return }
            editingTransaction = transaction
            router.transactionToOpen = nil
        }
    }
}

