//
//  CategoryRulesView.swift
//  Penny
//
//  Created by Ethan Christo on 3/16/26.
//

import SwiftData
import SwiftUI

struct CategoryRulesView: View {
    @Environment(\.modelContext) var modelContext

    /// Which rule the editor sheet is showing; `.new` adds a rule, `.existing` edits one.
    private enum RuleSheet: Identifiable {
        case new
        case existing(CategoryRules)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let rule): "\(rule.persistentModelID)"
            }
        }
    }

    @State private var activeSheet: RuleSheet?

    let category: Category

    var rules: [CategoryRules] {
        (category.rules ?? []).sorted {
            ($0.inputNotes ?? "").localizedCaseInsensitiveCompare($1.inputNotes ?? "") == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(rules) { rule in
                    Button {
                        activeSheet = .existing(rule)
                    } label: {
                        listText(for: rule)
                            .foregroundStyle(.primary)
                    }
                }
                .onDelete(perform: deleteRules)
            } footer: {
                Text("Imported transactions whose name contains any of these words are assigned to \(category.name).")
            }
        }
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label("No Rules", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                } description: {
                    Text("Add text to automatically assign matching imported transactions to \(category.name).")
                } actions: {
                    Button("Add Rule") { activeSheet = .new }
                }
            }
        }
        .navigationTitle("Category Rules")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .new
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .new:
                    EditCategoryRuleView(category: category, rule: nil)
                case .existing(let rule):
                    EditCategoryRuleView(category: category, rule: rule)
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        let current = rules
        for index in offsets {
            let rule = current[index]
            category.rules?.removeAll { $0.persistentModelID == rule.persistentModelID }
            modelContext.delete(rule)
        }
    }

    private func listText(for rule: CategoryRules) -> some View {
        // Build a single string description based on which input is present, then wrap in Text
        if let notes = rule.inputNotes, !notes.isEmpty {
            return Text(notes)
        } else if let accountName = rule.inputAccount?.name, !accountName.isEmpty {
            return Text(accountName)
        } else if let recurrenceRaw = rule.inputRecurrence?.rawValue, !recurrenceRaw.isEmpty {
            return Text(recurrenceRaw)
        } else if let date = rule.inputDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return Text(formatter.string(from: date))
        } else {
            return Text("Unknown")
        }
    }
}

/// Sheet for adding or editing a text-match rule on a category.
private struct EditCategoryRuleView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss

    @Query private var allCategories: [Category]

    @FocusState private var isFocused: Bool
    @State private var text: String = ""

    let category: Category
    let rule: CategoryRules?

    private var keyword: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesKeyword(_ other: CategoryRules) -> Bool {
        other.persistentModelID != rule?.persistentModelID
            && (other.inputNotes ?? "").caseInsensitiveCompare(keyword) == .orderedSame
    }

    /// This category already has a rule with the same text.
    private var isDuplicate: Bool {
        (category.rules ?? []).contains(where: matchesKeyword)
    }

    /// Other categories that already use this text. Matching picks the first
    /// category it finds, so saving here moves the rule to this category.
    private var conflictingCategories: [Category] {
        guard !keyword.isEmpty else { return [] }
        return allCategories.filter { other in
            other.persistentModelID != category.persistentModelID
                && (other.rules ?? []).contains(where: matchesKeyword)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. Starbucks", text: $text)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        if canSave { save() }
                    }
            } header: {
                Text("Transaction Name Contains")
            } footer: {
                if isDuplicate {
                    Text("\(category.name) already has this rule.")
                        .foregroundStyle(.red)
                } else if let other = conflictingCategories.first {
                    Text("\(other.name) already uses this rule. Saving will move it to \(category.name).")
                        .foregroundStyle(.orange)
                } else {
                    Text("Matching ignores capitalization.")
                }
            }
        }
        .navigationTitle(rule == nil ? "New Rule" : "Edit Rule")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    save()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            text = rule?.inputNotes ?? ""
            isFocused = true
        }
    }

    private var canSave: Bool {
        !keyword.isEmpty && !isDuplicate
    }

    private func save() {
        // Remove the same keyword from other categories so the rule actually applies here.
        for other in conflictingCategories {
            let stale = (other.rules ?? []).filter(matchesKeyword)
            other.rules?.removeAll(where: matchesKeyword)
            stale.forEach(modelContext.delete)
        }

        if let rule {
            rule.inputNotes = keyword
        } else {
            let newRule = CategoryRules(inputNotes: keyword)
            newRule.category = category
            category.rules = (category.rules ?? []) + [newRule]
            modelContext.insert(newRule)
        }

        dismiss()
    }
}

// MARK: - Previews

#Preview("Rules", traits: .sampleData) {
    @Previewable @Query(filter: #Predicate<Category> { $0.name == "Drinks" }) var categories: [Category]
    if let category = categories.first {
        NavigationStack {
            CategoryRulesView(category: category)
        }
    }
}

#Preview("New Rule", traits: .sampleData) {
    @Previewable @Query(filter: #Predicate<Category> { $0.name == "Drinks" }) var categories: [Category]
    if let category = categories.first {
        NavigationStack {
            EditCategoryRuleView(category: category, rule: nil)
        }
    }
}
