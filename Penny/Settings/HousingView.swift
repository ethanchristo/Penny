//
//  HousingView.swift
//  Penny
//
//  Created by Ethan Christo on 9/9/26.
//

import SwiftData
import SwiftUI

struct HousingView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Housing.startDate) private var housing: [Housing]

    @State private var editHousing: Housing?
    @State private var newHousing = false
    
    private var mortgages: [Housing] {
        housing.filter( { $0.mortgage })
    }
    
    private var apartments: [Housing] {
        housing.filter( { !$0.mortgage })
    }

    var body: some View {
        List {
            if housing.isEmpty {
                ContentUnavailableView(
                    "No Housing",
                    systemImage: "house",
                    description: Text("Add rent or mortgage payments to include them in your net total.")
                )
            } else {
                if !mortgages.isEmpty {
                    Section {
                        ForEach(mortgages) { place in
                            Button {
                                editHousing = place
                            } label: {
                                HStack {
                                    Text(place.name)
                                    Spacer()
                                    Text(place.amount, format: .currency(code: currencyCode))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Text("Mortgages")
                    }
                }
                
                if !apartments.isEmpty {
                    Section {
                        ForEach(apartments) { place in
                            Button {
                                editHousing = place
                            } label: {
                                HStack {
                                    Text(place.name)
                                    Spacer()
                                    Text(place.amount, format: .currency(code: currencyCode))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Text("Apartments")
                    }
                }
            }

        }
        .navigationTitle("Housing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("New Housing", systemImage: "plus") {
                    newHousing.toggle()
                }
            }
        }
        .sheet(item: $editHousing) { place in
            NavigationStack {
                editHousingView(
                    modelContext: modelContext,
                    housing: place
                )
            }
        }

        .sheet(isPresented: $newHousing) {
            NavigationStack {
                editHousingView(
                    modelContext: modelContext,
                    housing: nil
                )
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(housing[index])
        }
    }
}

struct editHousingView: View {
    @AppStorage("default_checking_name") private var defaultCheckingName: String = "Checking"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Account.name) private var accounts: [Account]

    let modelContext: ModelContext
    let housing: Housing?

    @State private var draft = Draft()
    @State private var showMatchPicker = false

    private struct Draft {
        var name = ""
        var mortgage = false
        var amount: Double = 0
        var account: Account? = nil
        var frequency: HousingFrequency = .monthly
        var startDate = Date.now
        var hasEndDate = false
        var endDate = Date.now
        var includeUpcoming = true
        var leadDays = 14
        var matchNotes: String? = nil

        init() {}

        init(from housing: Housing) {
            self.name = housing.name
            self.mortgage = housing.mortgage
            self.amount = housing.amount
            self.account = housing.account
            self.frequency = housing.frequency
            self.startDate = housing.startDate
            self.hasEndDate = housing.endDate != nil
            self.endDate = housing.endDate ?? housing.startDate
            self.includeUpcoming = housing.includeUpcoming
            self.leadDays = housing.leadDays
            self.matchNotes = housing.matchNotes
        }
    }

    /// Whether the selected account has a real bank feed behind it — either a specific
    /// imported `Account`, or the primary checking account (`draft.account == nil`, this
    /// app's convention — see `defaultCheckingName`) when it has a SimpleFIN/FinanceKit
    /// checking feed designated. Automatic payment matching only makes sense against a
    /// real feed.
    private var isImportLinked: Bool {
        if let account = draft.account { return account.externalID != nil }
        return BankSyncMapping.primaryCheckingID != nil
    }

    /// Display name for the selected account, used in the Match Transaction copy.
    private var accountLabel: String {
        guard let account = draft.account else { return defaultCheckingName }
        return account.name.isEmpty ? "Account" : account.name
    }

    private var canSave: Bool {
        !draft.name.isEmpty && draft.amount != 0
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
            }

            Section {
                Picker("Mortage", selection: $draft.mortgage) {
                    Text("Rent").tag(false)
                    Text("Mortgage").tag(true)
                }
                .pickerStyle(.segmented)
                
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
                Text("Amount")
            }

            Section {
                Picker("Account", selection: $draft.account) {
                    Text(defaultCheckingName).tag(nil as Account?)
                    ForEach(accounts) { account in
                        Text(account.name.isEmpty ? "Account" : account.name).tag(Account?.some(account))
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Linking an imported account lets Penny automatically detect once the real payment posts, so it isn't double-counted. See Match Transaction below.")
            }

            Section {
                DatePicker("Payment Date", selection: $draft.startDate, displayedComponents: .date)

                Toggle("End Date", isOn: $draft.hasEndDate)
                if draft.hasEndDate {
                    DatePicker("End Date", selection: $draft.endDate, displayedComponents: .date)
                }

                Picker("Frequency", selection: $draft.frequency) {
                    ForEach(HousingFrequency.allCases, id: \.self) { frequency in
                        Text(frequency.rawValue.capitalized).tag(frequency)
                    }
                }
            } header: {
                Text("Schedule")
            }

            Section {
                Toggle("Include Upcoming Payment", isOn: $draft.includeUpcoming)

                if draft.includeUpcoming {
                    Stepper(value: $draft.leadDays, in: 1...14) {
                        Text("\(draft.leadDays) day\(draft.leadDays == 1 ? "" : "s") before due")
                    }
                }
            } header: {
                Text("Upcoming")
            } footer: {
                Text("When on, an upcoming payment counts against your net total starting this many days before it's due, instead of only once it's actually happened.")
            }

            if isImportLinked {
                Section {
                    if let matchNotes = draft.matchNotes, !matchNotes.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Matching")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(matchNotes)
                            }
                            Spacer()
                            Button("Unlink", role: .destructive) {
                                draft.matchNotes = nil
                            }
                            .font(.caption)
                        }
                    } else {
                        Button("Link a Transaction") {
                            showMatchPicker = true
                        }
                    }
                } header: {
                    Text("Match Transaction")
                } footer: {
                    Text("Link one real \(accountLabel) transaction so Penny recognizes this payment once it posts, and stops counting the projected payment for that period.")
                }
            }
        }
        .onAppear(perform: load)
        .navigationTitle(housing == nil ? "New Housing" : (draft.name.isEmpty ? "Housing" : draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
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
        .sheet(isPresented: $showMatchPicker) {
            NavigationStack {
                MatchTransactionPickerView(modelContext: modelContext, account: draft.account, accountLabel: accountLabel) { transaction in
                    draft.matchNotes = transaction.notes
                }
            }
        }
    }

    private func load() {
        if let housing {
            draft = Draft(from: housing)
        }
    }

    private func save() {
        let target: Housing
        if let housing {
            target = housing
        } else {
            let created = Housing()
            modelContext.insert(created)
            target = created
        }

        target.name = draft.name
        target.mortgage = draft.mortgage
        target.amount = draft.amount
        target.account = draft.account
        target.frequency = draft.frequency
        // Monthly payments anchor to the start of the month, mirroring `Housing.init`,
        // so occurrences land on calendar-month boundaries instead of drifting.
        target.startDate = draft.frequency == .monthly ? draft.startDate.startOfMonth : draft.startDate
        target.endDate = draft.hasEndDate ? draft.endDate : nil
        target.includeUpcoming = draft.includeUpcoming
        target.leadDays = draft.leadDays
        target.matchNotes = draft.matchNotes

        try? modelContext.save()
    }
}

/// One-time picker for linking a real transaction to a `Housing` entry: the user
/// selects a single transaction on the linked (imported) account, and its `notes` text
/// becomes the template Penny matches future postings against (see
/// `housingAllTimeTotal` / `housingPaymentMatches` in Functions.swift). Only the notes
/// text is kept — not a reference to this specific transaction — since each period's
/// real payment is a different `Transaction` row.
private struct MatchTransactionPickerView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @Environment(\.dismiss) private var dismiss

    let modelContext: ModelContext
    /// `nil` means the primary checking account, per this app's convention.
    let account: Account?
    let accountLabel: String
    let onSelect: (Transaction) -> Void

    @State private var transactions: [Transaction] = []

    var body: some View {
        List(transactions) { transaction in
            Button {
                onSelect(transaction)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(transaction.notes.isEmpty ? "(No notes)" : transaction.notes)
                        Text(transaction.date, format: .dateTime.month().day().year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(transaction.amount, format: .currency(code: currencyCode))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        }
        .overlay {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet",
                    description: Text("\(accountLabel) has no transactions yet.")
                )
            }
        }
        .onAppear {
            let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
            transactions = all
                .filter { $0.account == account }
                .sorted { $0.date > $1.date }
        }
        .navigationTitle("Select Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
