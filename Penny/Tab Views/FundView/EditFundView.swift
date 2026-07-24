//
//  EditFundView.swift
//  Penny
//
//  Created by Ethan Christo on 6/4/26.
//

import SwiftUI
import SwiftData

struct EditFundView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss // Usually needed to close the sheet after saving

    @State private var draft = Draft()
    
    let fund: Fund?

    @State private var showContributionAlert = false
    @State private var deleteContributionsOnSave = false

    private struct Draft {
        var name = ""
        var goal: Double = 0.0
        var preAllocate: Bool = false
        var start: Date = Date()
        var end: Date = Date()
        var symbol: String = "✈️"
        var color: Color = .gray
        var notes = ""

        init(from fund: Fund? = nil) {
            if let existingFund = fund {
                self.name = existingFund.name
                self.goal = existingFund.goal
                self.preAllocate = existingFund.preAllocate
                self.start = existingFund.start
                self.end = existingFund.end
                self.symbol = existingFund.symbol
                self.color = existingFund.color
                self.notes = existingFund.notes
            }
        }
    }

    var body: some View {
        Form {
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

            Section {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(currencySymbol)
                        .font(.title2)
                        .foregroundStyle(Color.secondary)

                    TextField("123.45", value: $draft.goal, format: .number)
                        .font(.largeTitle.bold())
                        .keyboardType(.decimalPad)
                        .labelsHidden()
                }
                
                DatePicker("Start date", selection: $draft.start, displayedComponents: .date)
                    .pickerStyle(.inline)
                DatePicker("End date", selection: $draft.end, displayedComponents: .date)
                    .pickerStyle(.inline)
            } header: {
                Text(draft.preAllocate ? "Amount & Date" : "Goal & Date")
            }

            Section {
                Toggle("Use fixed-amount instead of goal", isOn: Binding(
                    get: { draft.preAllocate },
                    set: { enabling in
                        if enabling {
                            // Ask what to do with existing contributions, but only if there are any.
                            if fund?.transactions?.contains(where: { $0.isIncome }) == true {
                                showContributionAlert = true
                            } else {
                                draft.preAllocate = true
                            }
                        } else {
                            // Disabling pre-allocation cancels any pending contribution delete.
                            draft.preAllocate = false
                            deleteContributionsOnSave = false
                        }
                    }
                ))
            } footer: {
                Text("Treats a fund more like an account with an end-date. Instead of having to put money in the fund, turning on the toggle on will pre-contribute the fund amount and disable future-contributions.")
            }

            Section {
                TextField("Summer vacation", text: $draft.notes)
            } header: {
                Text("Notes")
            }
        }
        .onAppear {
            loadFund()
        }
        .alert("Existing Contributions", isPresented: $showContributionAlert) {
            Button("Delete", role: .destructive) {
                deleteContributionsOnSave = true
                draft.preAllocate = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This plan already has contributions marked as income. Pre-allocating treats the plan as already funded. Delete those contributions? This applies when you save.")
        }
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }

            ToolbarSpacer(.fixed, placement: .topBarLeading)

            if let existingFund = fund {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        modelContext.delete(existingFund)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(Color(.systemRed))
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveFund()
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .disabled(draft.name == "" || draft.goal == 0.0)
            }
        }
    }

    private func loadFund() -> Void {
        // Let the Draft struct handle the heavy lifting
        draft = Draft(from: fund)
    }

    private func saveFund() -> Void {
        if let existingFund = fund {
            // Update existing
            existingFund.name = draft.name
            existingFund.goal = draft.goal
            existingFund.preAllocate = draft.preAllocate
            // If the user chose to delete contributions, remove the income transactions now.
            if deleteContributionsOnSave {
                for contribution in (existingFund.transactions ?? []).filter(\.isIncome) {
                    modelContext.delete(contribution)
                }
            }
            existingFund.start = draft.start
            existingFund.end = draft.end
            existingFund.symbol = draft.symbol
            existingFund.color = draft.color
            existingFund.notes = draft.notes
        } else {
            // Create brand new
            let newFund = Fund(
                name: draft.name,
                goal: draft.goal,
                preAllocate: draft.preAllocate,
                start: draft.start,
                end: draft.end,
                symbol: draft.symbol,
                notes: draft.notes
            )
            newFund.color = draft.color

            modelContext.insert(newFund)
            // Save immediately so the new fund gets its permanent persistentModelID now.
            // Otherwise SwiftData upgrades the temporary ID on the next autosave, which changes
            // the identity .sheet(item:) keys off of and makes the editor dismiss then reopen.
            try? modelContext.save()
        }
    }
}
