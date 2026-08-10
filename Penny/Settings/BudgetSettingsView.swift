//
//  BudgetSettings.swift
//  Penny
//
//  Created by Ethan Christo on 1/24/26.
//

import SwiftData
import SwiftUI

struct BudgetSettingsView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(OverallBudget.self) private var overallSettings

    @Query(sort: \Category.name) var categories: [Category]
    
    @State private var showOverallBudget = false
    @State private var selectedCategory: Category?
        
    var body: some View {
        Form {
            Section {
                Button {
                    showOverallBudget = true
                } label: {
                    Text("Overall Budget")
                        .tint(.primary)
                }
            }
            
            if categories.filter({ $0.budget?.hasBudget ?? true }).count != 0 {
                Section("Budgets") {
                    ForEach(categories.filter { $0.budget?.hasBudget ?? true }) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            HStack {
                                Text(category.symbol)
                                Text(category.name)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            
            if categories.filter({ !($0.budget?.hasBudget ?? false) }).count != 0 {
                Section("Categories Without a Budget") {
                    ForEach(categories.filter { !($0.budget?.hasBudget ?? false) }) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            HStack {
                                Text(category.symbol)
                                Text(category.name)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
        }
        .listRowSpacing(12)
        .navigationTitle("Budgets")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOverallBudget) {
            NavigationStack {
                OverallBudgetSettingsView(bindableOverall: overallSettings)
            }
        }
        .sheet(item: $selectedCategory) { category in
            NavigationStack {
                BudgetSettingsViewInfo(category: category)
            }
        }
    }
}

struct OverallBudgetSettingsView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.dismiss) var dismiss

    @Bindable var bindableOverall: OverallBudget
    
    @State private var hasBudget: Bool = false
    @State private var budget: Double = 0
    @State private var budgetWindow: BudgetWindow = .monthly

    var body: some View {
        Form {
            Section {
                Toggle("Overall Budget", isOn: $hasBudget)
            } footer: {
                Text("Turn this on to enable a budget for your overall spending")
            }
            
            Section {
                if hasBudget {
                    HStack {
                        HStack(alignment: .lastTextBaseline, spacing: 1) {
                            Text(currencySymbol)
                                .foregroundStyle(Color.secondary)
                                .font(.title2)

                            TextField("123.45", value: $budget, format: .number)
                                .keyboardType(.decimalPad)
                                .font(.largeTitle.bold())

                        }
                        
                        Picker("", selection: $budgetWindow) {
                            ForEach(BudgetWindow.allCases) { window in
                                Text(window.rawValue).tag(window)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
        }
        .navigationTitle("Overall Budget")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveBudget()
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .disabled(hasBudget && budget.isZero)
            }
        }
        .onAppear {
            loadBudget()
        }
    }
    
    private func loadBudget() {
        hasBudget = bindableOverall.isEnabled
        budget = bindableOverall.budget
        budgetWindow = bindableOverall.budgetWindow
    }
    
    private func saveBudget() {
        bindableOverall.isEnabled = hasBudget
        bindableOverall.budget = budget
        bindableOverall.budgetWindow = budgetWindow
    }
}

struct BudgetSettingsViewInfo: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    
    @Environment(\.dismiss) var dismiss
    
    @Bindable var category: Category
    
    @State private var hasBudget: Bool = false
    @State private var budget: Double = 0
    @State private var budgetWindow: BudgetWindow = .monthly
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Budget", isOn: $hasBudget)
            } footer: {
                Text("Turn this on to enable a budget for this category.")
            }
            
            Section {
                if hasBudget {
                    HStack {
                        HStack(alignment: .lastTextBaseline, spacing: 1) {
                            Text(currencySymbol)
                                .foregroundStyle(Color.secondary)
                                .font(.title2)

                            TextField("123.45", value: $budget, format: .number)
                                .keyboardType(.decimalPad)
                                .font(.largeTitle.bold())

                        }
                        
                        Picker("", selection: $budgetWindow) {
                            ForEach(BudgetWindow.allCases) { window in
                                Text(window.rawValue).tag(window)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(category.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveBudget()
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .disabled(hasBudget && budget.isZero)
            }
        }
        .onAppear {
            loadBudget()
        }
    }
    
    private func loadBudget() {
        hasBudget = category.budget?.hasBudget ?? false
        budget = category.budget?.budget ?? 0.0
        budgetWindow = category.budget?.budgetWindow ?? .monthly
    }
    
    private func saveBudget() {
        category.budget?.hasBudget = hasBudget
        category.budget?.budget = budget
        category.budget?.budgetWindow = budgetWindow
    }
}
