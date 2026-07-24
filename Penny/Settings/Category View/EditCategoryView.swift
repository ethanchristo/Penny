//
//  EditCategoryView.swift
//  Penny
//
//  Created by Ethan Christo on 6/14/26.
//

import SwiftData
import SwiftUI

struct EditCategoryView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss

    @FocusState private var isBudgetFocused: Bool

    @State private var draft = Draft()

    let category: Category?

    private struct Draft {
        var name: String = ""
        var symbol: String = "💰"
        var color: Color = .green
        var isPreBuilt: Bool = false

        // Budget is a separate @Model (reference type), so the draft holds plain
        // value copies of its fields. Nothing touches the persisted Budget until save.
        var hasBudget: Bool = false
        var budgetAmount: Double = 0.0
        var budgetWindow: BudgetWindow = .monthly

        // An elegant initializer that automatically populates the draft
        // if you pass it an existing category!
        init(from category: Category? = nil) {
            if let cat = category {
                self.name = cat.name
                self.symbol = cat.symbol
                self.color = cat.color
                self.isPreBuilt = cat.isPreBuilt

                if let budget = cat.budget {
                    self.hasBudget = budget.hasBudget
                    self.budgetAmount = budget.budget ?? 0.0
                    self.budgetWindow = budget.budgetWindow ?? .monthly
                }
            }
        }
    }

    var body: some View {
        VStack {
            Text(draft.symbol)
                .font(.system(size: 60))
                .frame(width: 100, height: 100)
                .background(draft.color.gradient)
                .clipShape(Circle())

            Form {
                Section("Name & Symbol") {
                    TextField("Account Name", text: $draft.name)
                        .disabled((draft.name == "Miscellaneous" || draft.name == "Payroll") && draft.isPreBuilt)

                    HStack {
                        TextField("?", text: $draft.symbol)
                            .font(.largeTitle)
                            .onChange(of: draft.symbol) {
                                if draft.symbol.count > 1 {
                                    draft.symbol = String(draft.symbol.prefix(1))
                                }
                            }

                        ColorPicker(selection: $draft.color, supportsOpacity: false) { }
                    }
                }

                Section("Budget") {
                    Toggle("Enable Budget", isOn: $draft.hasBudget)

                    if draft.hasBudget {
                        HStack {
                            HStack(alignment: .lastTextBaseline, spacing: 1) {
                                Text(currencySymbol)
                                    .foregroundStyle(Color.secondary)
                                    .font(.title2)

                                TextField("123.45", value: $draft.budgetAmount, format: .number)
                                    .keyboardType(.decimalPad)
                                    .font(.largeTitle.bold())
                                    .focused($isBudgetFocused)
                            }

                            Spacer()

                            Picker("", selection: $draft.budgetWindow) {
                                ForEach(BudgetWindow.allCases, id: \.self) { window in
                                    Text(window.rawValue).tag(window)
                                }
                            }
                        }
                    }
                }

                // Rules attach to a persisted Category, so this is only available
                // once the category exists (i.e. when editing, not while drafting a new one).
                if let category {
                    Section {
                        NavigationLink {
                            CategoryRulesView(category: category)
                        } label: {
                            Label("Category Rules", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                                .tint(.primary)
                        }
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .interactiveDismissDisabled(draft.name.isEmpty)
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(draft.name.isEmpty ? "New Category" : draft.name)
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Dismiss", systemImage: "xmark") {
                    dismiss()
                }
            }

            ToolbarSpacer(.fixed, placement: .topBarLeading)
            
            if let existingCat = category, existingCat.name != "Miscellaneous", existingCat.name != "Payroll" {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        modelContext.delete(existingCat)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(Color(.systemRed))
                }
            }


            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    saveCategory()
                    isBudgetFocused = false
                    dismiss()
                }
                .disabled(draft.name.isEmpty)
            }
        }
        .onAppear {
            loadCategory()
        }
    }

    private func loadCategory() -> Void {
        draft = Draft(from: category)
    }

    private func saveCategory() -> Void {
        if let category {
            // Update existing
            category.name = draft.name
            category.symbol = draft.symbol
            category.color = draft.color
            applyBudget(to: category)
        } else {
            // Create brand new
            let newCategory = Category(
                name: draft.name,
                symbol: draft.symbol,
                isPreBuilt: draft.isPreBuilt
            )
            newCategory.color = draft.color
            applyBudget(to: newCategory)

            modelContext.insert(newCategory)
            // Save immediately so the new category gets its permanent persistentModelID now.
            // Otherwise SwiftData upgrades the temporary ID on the next autosave, which changes
            // the identity .sheet(item:) keys off of and makes the editor dismiss then reopen.
            try? modelContext.save()
        }
    }

    // Commits the draft's budget fields onto the category's Budget model,
    // creating one if it doesn't exist yet.
    private func applyBudget(to category: Category) -> Void {
        if let budget = category.budget {
            budget.hasBudget = draft.hasBudget
            budget.budget = draft.hasBudget ? draft.budgetAmount : nil
            budget.budgetWindow = draft.hasBudget ? draft.budgetWindow : nil
        } else {
            category.budget = Budget(
                hasBudget: draft.hasBudget,
                budget: draft.hasBudget ? draft.budgetAmount : nil,
                budgetWindow: draft.hasBudget ? draft.budgetWindow : nil
            )
        }
    }
}
