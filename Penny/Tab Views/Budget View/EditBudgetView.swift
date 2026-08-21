//
//  EditBudgetView.swift
//  Penny
//
//  Created by Ethan Christo on 8/15/26.
//

import SwiftData
import SwiftUI

/// The unified budget editor. Handles both kinds of budget:
///  • **Category-linked** — pick a category; always recurring; no pre-funding and no
///    contributions (spend-vs-limit only).
///  • **Freestanding** ("custom") — its own name/symbol/color; recurring OR one-time;
///    optionally pre-funded (spend down) vs. contributed toward.
struct EditBudgetView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Category.name) private var categories: [Category]

    /// The budget being edited, or `nil` when creating a new one.
    let budget: Budget?
    /// Preselect (and lock to) a category — e.g. when adding a budget for a category.
    var presetCategory: Category? = nil

    @State private var draft = Draft()
    @State private var showContributionAlert = false
    @State private var deleteContributionsOnSave = false

    enum PeriodKind: String, CaseIterable, Identifiable {
        case recurring = "Recurring"
        case oneTime = "One-time"
        var id: String { rawValue }
    }

    private struct Draft {
        var isCategoryLinked = false
        var category: Category? = nil
        var name = ""
        var symbol = "✈️"
        var color: Color = .gray
        var amount: Double = 0.0
        var periodKind: PeriodKind = .recurring
        var window: BudgetWindow = .monthly
        var start = Date()
        var end = Date()
        var preFunding = false
        var notes = ""

        init() {}

        init(from budget: Budget) {
            self.isCategoryLinked = budget.category != nil
            self.category = budget.category
            self.name = budget.name
            self.symbol = budget.symbol
            self.color = budget.color
            self.amount = budget.amount
            self.periodKind = budget.isRecurring ? .recurring : .oneTime
            self.window = budget.budgetWindow ?? .monthly
            self.start = budget.start ?? Date()
            self.end = budget.end ?? Date()
            self.preFunding = budget.preFunding
            self.notes = budget.notes
        }
    }

    /// Whether the scope (category vs. freestanding) can still be changed. Locked once a
    /// budget exists so we never strand a freestanding budget's tagged transactions.
    private var scopeIsEditable: Bool { budget == nil && presetCategory == nil }

    /// Categories available to link: those without an active budget, plus the one
    /// currently selected (so it stays visible while editing).
    private var linkableCategories: [Category] {
        categories.filter { !($0.budget?.hasBudget ?? false) || $0.id == draft.category?.id }
    }

    private var canSave: Bool {
        guard draft.amount != 0 else { return false }
        return draft.isCategoryLinked ? draft.category != nil : !draft.name.isEmpty
    }

    var body: some View {
        Form {
            // MARK: Scope
            Section {
                Toggle("Link to a category", isOn: Binding(
                    get: { draft.isCategoryLinked },
                    set: { linked in
                        draft.isCategoryLinked = linked
                        // Reset the picker to None when the budget isn't linked to a category.
                        if !linked { draft.category = nil }
                    }
                ))
                .disabled(!scopeIsEditable)

                if draft.isCategoryLinked {
                    Picker("Category", selection: $draft.category) {
                        Text("None").tag(Category?.none)
                        ForEach(linkableCategories) { category in
                            Text("\(category.symbol)  \(category.name)").tag(Category?.some(category))
                        }
                    }
                    .disabled(!scopeIsEditable)
                }
            } footer: {
                Text(draft.isCategoryLinked
                     ? "Spending is pulled from this category's transactions. Category budgets always recur."
                     : "A freestanding budget you tag transactions to directly. Can recur or run once, and can be pre-funded.")
            }

            // MARK: Name & color (freestanding only)
            if !draft.isCategoryLinked {
                Section {
                    TextField("Vacation", text: $draft.name)

                    HStack {
                        TextField("?", text: $draft.symbol)
                            .onChange(of: draft.symbol) {
                                if draft.symbol.count > 1 {
                                    draft.symbol = String(draft.symbol.prefix(1))
                                }
                            }

                        ColorPicker("Accent Color", selection: $draft.color)
                            .labelsHidden()
                    }
                } header: {
                    Text("Name & Color")
                }
            }

            // MARK: Amount
            Section {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(currencySymbol)
                        .font(.title2)
                        .foregroundStyle(Color.secondary)

                    TextField("123.45", value: $draft.amount, format: .number)
                        .font(.largeTitle.bold())
                        .keyboardType(.decimalPad)
                        .labelsHidden()
                }
            } header: {
                Text(draft.preFunding ? "Amount" : "Goal")
            }

            // MARK: Period
            Section {
                if draft.isCategoryLinked {
                    // Category budgets are always recurring — just the window.
                    Picker("Resets", selection: $draft.window) {
                        ForEach(BudgetWindow.allCases) { window in
                            Text(window.rawValue).tag(window)
                        }
                    }
                } else {
                    Picker("Period", selection: $draft.periodKind) {
                        ForEach(PeriodKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.periodKind == .recurring {
                        Picker("Resets", selection: $draft.window) {
                            ForEach(BudgetWindow.allCases) { window in
                                Text(window.rawValue).tag(window)
                            }
                        }
                    } else {
                        DatePicker("Start date", selection: $draft.start, displayedComponents: .date)
                        DatePicker("End date", selection: $draft.end, displayedComponents: .date)
                    }
                }
            } header: {
                Text("Period")
            }

            // MARK: Pre-Funding
            Section {
                Toggle("Pre-Funding", isOn: Binding(
                    get: { draft.preFunding },
                    set: { enabling in
                        if enabling {
                            // Only freestanding budgets have contributions to reconcile;
                            // category income isn't a contribution, so skip the prompt there.
                            if !draft.isCategoryLinked, budget?.transactions?.contains(where: { $0.isIncome }) == true {
                                showContributionAlert = true
                            } else {
                                draft.preFunding = true
                            }
                        } else {
                            draft.preFunding = false
                            deleteContributionsOnSave = false
                        }
                    }
                ))
            } footer: {
                Text(draft.isCategoryLinked
                     ? "Sets the full budgeted amount aside up front and treats this category's spending as spending it down — reserved from your net total like a pre-funded fund, rather than a plain spend-vs-limit budget."
                     : "Treats the budget like an account that's already funded: instead of contributing money over time, the full amount is set aside up front and you spend it down. Turning this on disables future contributions.")
            }

            // MARK: Notes (freestanding only)
            if !draft.isCategoryLinked {
                Section {
                    TextField("Summer vacation", text: $draft.notes)
                } header: {
                    Text("Notes")
                }
            }
        }
        .onAppear(perform: load)
        .alert("Existing Contributions", isPresented: $showContributionAlert) {
            Button("Delete", role: .destructive) {
                deleteContributionsOnSave = true
                draft.preFunding = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This budget already has contributions marked as income. Pre-funding treats the budget as already funded. Delete those contributions? This applies when you save.")
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }

            if let existing = budget {
                ToolbarSpacer(.fixed, placement: .topBarLeading)

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        delete(existing)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(Color(.systemRed))
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .disabled(!canSave)
            }
        }
    }

    private var navigationTitle: String {
        if draft.isCategoryLinked { return draft.category?.name ?? "Budget" }
        return draft.name.isEmpty ? "Budget" : draft.name
    }

    private func load() {
        if let budget {
            draft = Draft(from: budget)
        } else if let presetCategory {
            draft.isCategoryLinked = true
            draft.category = presetCategory
        }
    }

    private func save() {
        if draft.isCategoryLinked {
            guard let category = draft.category else { return }
            // Category budgets live on the category's own Budget object (auto-created
            // with the category). Reuse it rather than inserting a second budget.
            let target = budget ?? category.budget ?? {
                let created = Budget()
                category.budget = created
                return created
            }()
            target.category = category
            target.hasBudget = true
            target.budget = draft.amount
            target.isRecurring = true
            target.budgetWindow = draft.window
            // Category budgets are always recurring, but may be pre-funded (an envelope
            // reserved from the net total like the old pre-allocate funds).
            target.preFunding = draft.preFunding
            target.start = nil
            target.end = nil
        } else {
            let target: Budget
            if let budget {
                target = budget
            } else {
                let created = Budget(name: draft.name, amount: draft.amount)
                modelContext.insert(created)
                target = created
            }

            target.category = nil
            target.hasBudget = true
            target.name = draft.name
            target.symbol = draft.symbol
            target.color = draft.color
            target.budget = draft.amount
            target.isRecurring = (draft.periodKind == .recurring)
            target.budgetWindow = draft.periodKind == .recurring ? draft.window : nil
            target.start = draft.periodKind == .oneTime ? draft.start : nil
            target.end = draft.periodKind == .oneTime ? draft.end : nil
            target.preFunding = draft.preFunding
            target.notes = draft.notes

            if deleteContributionsOnSave {
                for contribution in (target.transactions ?? []).filter(\.isIncome) {
                    modelContext.delete(contribution)
                }
            }
        }

        // Save immediately so a new budget gets its permanent persistentModelID now,
        // keeping .sheet(item:) identity stable (mirrors the old fund editor).
        try? modelContext.save()
    }

    private func delete(_ budget: Budget) {
        if budget.category != nil {
            // Don't delete the category's Budget object — just turn the budget off.
            budget.hasBudget = false
        } else {
            modelContext.delete(budget)
        }
    }
}
