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
    @Environment(\.dismiss) var dismiss
    
    @State private var addRule = false
    
    let category: Category
    
    var rules: [CategoryRules] { category.rules ?? [] }
    
    var body: some View {
        List {
            ForEach(rules) { rule in
                Button {
                    
                } label: {
                    listText(for: rule)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addRule.toggle()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $addRule) {
            NavigationStack {
                Text("Stuff")
            }
            .presentationDetents([.medium])
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
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

