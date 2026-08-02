//
//  SingleTransactionView.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import OSLog
import SwiftData
import SwiftUI

private let log = Logger(subsystem: "com.opal.Penny", category: "editTransaction")

private struct Draft {
    var amount: Double = 0.0
    var isIncome: Bool = false
    var date: Date = Date()
    var account: Account? = nil
    // A transaction is tagged with EITHER a category OR a fund, never both.
    // `Draft` is a plain struct (not an @Model), so didSet fires normally here
    // and — because `draft` lives in @State — the view re-renders on any change.
    var category: Category? = nil {
        didSet { if category != nil { fund = nil } }
    }
    var fund: Fund? = nil {
        didSet { if fund != nil { category = nil } }
    }
    var notes: String = ""
    var recurrence: Recurrence = .none
    var endDate: Date? = nil
    
    // An elegant initializer that automatically populates the draft
    // if you pass it an existing transaction!
    init(from transaction: Transaction? = nil, defaultCategory: Category? = nil, defaultFund: Fund? = nil) {
        if let tx = transaction {
            self.amount = tx.amount
            self.isIncome = tx.isIncome
            self.date = tx.date
            self.account = tx.account
            self.category = tx.amount == 0.0 ? defaultCategory : tx.category
            self.fund = tx.fund
            self.notes = tx.notes
            self.recurrence = tx.recurrence
            self.endDate = tx.endDate
        } else if let defaultFund {
            // New transaction pre-tagged with the passed-in fund
            self.fund = defaultFund
        } else {
            // New transaction gets the fallback default category
            self.category = defaultCategory
        }
    }
}

struct SingleTransactionView: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("default_checking_name") private var defaultCheckingName: String = "Checking"
    
    @Query(sort: \Category.name) var categories: [Category]
    
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss

    @ScaledMetric(relativeTo: .largeTitle) private var amountFontSize: CGFloat = 64
    
    @State private var editMode: Bool = false
    @State private var draft = Draft()

    let initialEditMode: Bool
    let transaction: Transaction?
    let category: Category?
    let fund: Fund?
    
    private var title: String {
        if editMode {
            if let transaction {
                if !transaction.notes.isEmpty {
                    return transaction.notes
                } else if let cat = transaction.category {
                    return cat.name
                } else if let fund = transaction.fund {
                    return fund.name
                }
            } else {
                return "New Transaction"
            }
        }
        return ""
    }

    var body: some View {
        Group {
            if editMode {
                EditTransactionView(
                    draft: $draft,
                    transaction: transaction,
                    category: category,
                    fund: fund,
                    dismiss: dismiss,
                    currencySymbol: currencySymbol,
                    amountFontSize: amountFontSize,
                    defaultCheckingName: defaultCheckingName
                )
            } else {
                ShowTransactionView(
                    editMode: $editMode,
                    draft: $draft,
                    transaction: transaction,
                    dismiss: dismiss,
                    currencySymbol: currencySymbol,
                    amountFontSize: amountFontSize,
                    defaultCheckingName: defaultCheckingName
                )
            }
        }
        .transition(.opacity)
        .onAppear {
            editMode = initialEditMode
            loadTransaction()
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Dismiss", systemImage: "xmark") {
                    if draft.amount == 0.0 {
                        if let existingTx = transaction {
                            modelContext.delete(existingTx)
                        }
                    }
                    dismiss()
                }
            }
            
            ToolbarSpacer(.fixed, placement: .topBarLeading)
            
            ToolbarItem(placement: .topBarLeading) {
                if let existingTx = transaction {
                    Button("Delete", systemImage: "trash") {
                        if let externalID = existingTx.externalID {
                            SimpleFINConfig.dismissExternalID(externalID)
                        }
                        modelContext.delete(existingTx)
                        dismiss()
                    }
                    .tint(Color(.systemRed))
                }
            }
            
            Group {
                if editMode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") {
                            saveTransaction()
                            dismiss()
                        }
                        .disabled(draft.amount == 0.0 || (draft.category == nil && draft.fund == nil))
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") {
                            // 🚨 4. Simply toggle the edit mode directly!
                            editMode = true
                        }
                    }
                }
            }
        }
    }
        
    private func loadTransaction() -> Void {
        // Find the fallback category once
        let miscCategory = categories.first(where: { $0.name == "Miscellaneous" })
        
        if miscCategory == nil && transaction == nil {
            log.error("Miscellaneous category not found")
        }
        
        // Let the struct do all the heavy lifting!
        // A passed-in category/fund pre-populates the draft for new transactions.
        draft = Draft(from: transaction, defaultCategory: category ?? miscCategory, defaultFund: fund)
    }
    
    private func saveTransaction() -> Void {
        guard let finalCategory = draft.category ?? categories.first(where: { $0.name == "Miscellaneous" }) else {
            log.fault("No category could be determined when saving transaction")
            return
        }
        
        if let existingTx = transaction {
            // Update existing
            existingTx.amount = draft.amount
            existingTx.isIncome = draft.isIncome
            existingTx.date = draft.date
            existingTx.notes = draft.notes
            existingTx.account = draft.account
            existingTx.category = finalCategory
            existingTx.fund = draft.fund
            existingTx.recurrence = draft.recurrence
            existingTx.endDate = draft.endDate
        } else {
            // Create brand new
            let newTx = Transaction(
                amount: draft.amount,
                isIncome: draft.isIncome,
                date: draft.date,
                account: draft.account,
                category: finalCategory,
                fund: draft.fund,
                notes: draft.notes,
                recurrence: draft.recurrence,
                endDate: draft.endDate
            )
            modelContext.insert(newTx)
            // Save immediately so the new transaction gets its permanent persistentModelID now.
            // Otherwise SwiftData upgrades the temporary ID on the next autosave, which changes
            // the identity .sheet(item:) keys off of and makes the editor dismiss then reopen.
            try? modelContext.save()
        }

        // A payroll-categorized edit should move the payday-anchored window right away.
        syncPayrollPayPeriodAnchor()
    }
}

struct EditTransactionView: View {
    @AppStorage("decimal_pad_type") private var decimalPadType: DecimalPadType = .ATM
        
    @Query(sort: \Account.name) var accounts: [Account]
    @Query(sort: \Category.name) var categories: [Category]
    @Query(sort: \Fund.name) var funds: [Fund]
        
    @Binding fileprivate var draft: Draft
    
    @State private var isEndDate: Bool = false
    @State private var inputAmount: String = ""
    
    @State private var showNotesSheet: Bool = false
    @State private var showDateSheet: Bool = false
    @State private var showRecurringSheet: Bool = false
    
    @State private var addAccount = false
    @State private var addCategory = false
    @State private var addFund = false
    
    private var incomeName: String {
        if draft.category != nil {
            "Income"
        } else {
            "Contribution"
        }
    }
    
    private var expenseName: String {
        if draft.category != nil {
            "Expense"
        } else {
            "Utilization"
        }
    }
    
    let transaction: Transaction?
    let category: Category?
    let fund: Fund?
    
    let dismiss: DismissAction
    
    let currencySymbol: String
    let amountFontSize: CGFloat
    let defaultCheckingName: String
    
    var body: some View {
        VStack {
            Picker("", selection: $draft.isIncome) {
                if draft.fund?.preAllocate != true {
                    Label(incomeName, systemImage: "tray.and.arrow.down").tag(true)
                }
                
                Label(expenseName, systemImage: "tray.and.arrow.up").tag(false)
            }
            .pickerStyle(.palette)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.horizontal, 20)
            
            Spacer()
            
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(currencySymbol)
                    .font(.title)
                    .foregroundStyle(.secondary)
                
                Text(inputAmount)
                    .font(.system(size: amountFontSize, weight: .bold)) // Very large font, scales with Dynamic Type
                    .lineLimit(1)
                    .minimumScaleFactor(0.5) // Shrink to fit long amounts
                    .contentTransition(.numericText()) // Smooth animation
            }
            .frame(maxWidth: .infinity)

            Button {
                showNotesSheet = true
            } label: {
                Label("Notes", systemImage: "text.pad.header")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 7)
                    .glassEffect(.regular)
            }
            
            Spacer()
            
            HStack {
                Button {
                    showDateSheet = true
                } label: {
                    Text(draft.date, format: .dateTime.month(.abbreviated).day().year())
                        .padding(8)
                        .glassEffect(.regular)
                }
                
                Button {
                    showRecurringSheet = true
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                }
                .disabled(draft.fund != nil)
                
                Spacer()
                
                Menu {
                    Button {
                        addAccount = true
                    } label: {
                        Label("Add Card/Account", systemImage: "plus")
                    }
                    
                    Divider()
                    
                    Picker("Accounts", selection: $draft.account) {
                        ForEach(accounts.filter { $0.accountType != .credit }) { account in
                            Text(account.name).tag(account as Account?)
                        }
                        
                        Text(defaultCheckingName).tag(nil as Account?)
                    }
                    .labelsVisibility(.visible)
                    
                    Divider()
                    
                    Picker("Credit Cards", selection: $draft.account) {
                        ForEach(accounts.filter { $0.accountType == .credit }) { card in
                            Text(card.name).tag(card as Account?)
                        }
                    }
                    .labelsVisibility(.visible)
                } label: {
                    Group {
                        if let account = draft.account, account.accountType == .credit {
                            HStack {
                                Image(systemName: "creditcard")
                                Text(account.name)
                            }
                        }
                        
                        if let account = draft.account, account.accountType == .savings {
                            HStack {
                                Image(systemName: "s.square")
                                Text(account.name)
                            }
                        }
                        
                        if let account = draft.account, account.accountType == .checking {
                            Text(account.name)
                        }
                        
                        if draft.account == nil {
                            Text(defaultCheckingName)
                        }
                    }
                    .padding(8)
                    .glassEffect(.regular, in: .capsule)
                }
                Menu {
                    Menu {
                        Button {
                            addCategory = true
                            
                        } label: {
                            Label("Add Category", systemImage: "plus")
                        }
                        
                        Divider()

                        
                        Picker("Category", selection: $draft.category) {
                            ForEach(categories) { category in
                                Text("\(category.symbol)  \(category.name)").tag(category as Category?)
                            }
                        }
                    } label: {
                        Label("Category", systemImage: "rectangle.grid.2x2.fill")
                        if let cat = draft.category {
                            Text(cat.name)
                                .font(.caption)
                        }
                    }
                    
                    Menu {
                        Button {
                            addFund = true
                        } label: {
                            Label("Add Fund", systemImage: "plus")
                        }
                        
                        Divider()
                        
                        Picker("Fund", selection: $draft.fund) {
                            ForEach(funds) { fund in
                                Text("\(fund.symbol)  \(fund.name)").tag(fund)
                            }
                        }
                    } label: {
                        Label("Fund", systemImage: "rectangle.stack.fill")
                        if let fund = draft.fund {
                            Text(fund.name)
                                .font(.caption)
                        }
                    }
                } label: {
                    Group {
                        if let category = draft.category {
                            Text(category.symbol)
                                .padding(9)
                                .glassEffect(.regular.tint(category.color.opacity(0.5)))
                        } else if let fund = draft.fund {
                            Text(fund.symbol)
                                .padding(9)
                                .glassEffect(.regular.tint(fund.color.opacity(0.5)))
                        } else {
                            Text("Category/Fund")
                                .padding(8)
                                .glassEffect()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)

            LazyVGrid(columns: Array(repeating: GridItem(), count: 3)) {
                ForEach(1...9, id: \.self) { index in
                    Button {
                        handleInput(for: String(index))
                    } label: {
                        Text("\(index)")
                            .font(.title.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                            .glassEffect(.regular.interactive())
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: inputAmount)
                }
                if decimalPadType == .ATM {
                    Spacer()
                } else {
                    Button {
                        handleInput(for: ".")
                    } label: {
                        Text("•")
                            .font(.title.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                            .glassEffect(.regular.interactive())
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: inputAmount)
                }
                
                ForEach(["0", "delete.backward.fill"], id: \.self) { string in
                    Button {
                        handleInput(for: string)
                    } label: {
                        Group {
                            if string == "0" {
                                Text("0")
                            } else {
                                Image(systemName: string)
                            }
                        }
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 15)
                        .glassEffect(.regular.interactive())
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: inputAmount)
                }
            }
            .tint(.primary)
            .padding(.horizontal, 10)
        }
        .interactiveDismissDisabled(draft.amount == 0.0)
        .onAppear {
            loadAmount()
        }
        .onChange(of: draft.fund) {
            // Pre-allocated funds only support expenses ("Use"), so force expense for them.
            // Non-pre-allocated funds allow contributions (income), so leave isIncome alone —
            // otherwise loading an existing income transaction would reset it to expense.
            if draft.fund?.preAllocate == true {
                draft.isIncome = false
            }
        }
        .sheet(isPresented: $showNotesSheet) {
            NavigationStack {
                Form {
                    TextField("Birthday dinner", text: $draft.notes)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") {
                            showNotesSheet = false
                        }
                    }
                }
                .navigationTitle("Notes")
                .toolbarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        
        .sheet(isPresented: $showDateSheet) {
            NavigationStack {
                Form {
                    DatePicker("", selection: $draft.date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                }
                .navigationTitle("Date & Time")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") {
                            showDateSheet = false
                        }
                    }
                }
                .presentationDetents([.fraction(0.65)])
            }
        }
        .sheet(isPresented: $showRecurringSheet) {
            NavigationStack {
                Form {
                    Section {
                        Picker("Recurrence", selection: $draft.recurrence) {
                            ForEach(Recurrence.allCases, id: \.self) { recurrence in
                                Text(recurrence.rawValue).tag(recurrence)
                            }
                        }
                    }

                    Section {
                        if draft.recurrence != .none {
                            Toggle("End Date", isOn: $isEndDate)
                                .onChange(of: isEndDate) {
                                    if isEndDate {
                                        // Initialize with the current transaction date at start of day
                                        draft.endDate = draft.date.endOfDay
                                    } else {
                                        draft.endDate = nil
                                    }
                                }
                        }
                        
                        if isEndDate {
                            DatePicker(
                                "End Date",
                                selection: Binding(
                                    get: { draft.endDate ?? draft.date },
                                    set: { newValue in
                                        draft.endDate = newValue
                                    }
                                ),
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") {
                            showRecurringSheet = false
                        }
                    }
                }
                .navigationTitle("Recurrence")
                .toolbarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $addAccount) {
            NavigationStack {
                EditAccountView(account: nil)
            }
        }
        .sheet(isPresented: $addCategory) {
            NavigationStack {
                EditCategoryView(category: nil)
            }
        }
        .sheet(isPresented: $addFund) {
            NavigationStack {
                EditFundView(fund: nil)
            }
        }
//        .onDisappear {
//            // Only delete if it's an existing transaction that somehow got set to $0.00
//            if let existingTx = transaction, existingTx.amount == 0 {
//                modelContext.delete(existingTx)
//            }
//        }
        .foregroundStyle(.primary)
    }
    
    private func handleInput(for input: String) -> Void {
        withAnimation(.spring) {
        if decimalPadType == .ATM {
            if input == "delete.backward.fill" {
                var rawDigits = inputAmount.replacingOccurrences(of: ".", with: "")
                
                if !rawDigits.isEmpty {
                    rawDigits.removeLast()
                }
                
                let doubleValue = (Double(rawDigits) ?? 0.0) / 100
                
                inputAmount = String(format: "%.2f", doubleValue)
                draft.amount = doubleValue
                
            } else {
                var rawDigits = inputAmount.replacingOccurrences(of: ".", with: "")
                
                rawDigits.append(input)
                
                let doubleValue = (Double(rawDigits) ?? 0.0) / 100
                
                inputAmount = String(format: "%.2f", doubleValue)
                draft.amount = doubleValue
            }
        } else {
            if input == "delete.backward.fill" {
                if !inputAmount.isEmpty {
                    inputAmount.removeLast()
                }
                
                let doubleValue = Double(inputAmount) ?? 0.0
                
                draft.amount = doubleValue
            } else {
                inputAmount.append(input)
                
                let doubleValue = Double(inputAmount) ?? 0.0
                
                draft.amount = doubleValue
            }
        }
        }
    }

    private func loadAmount() -> Void {
        if decimalPadType == .ATM {
            inputAmount = String(format: "%.2f", transaction?.amount ?? 0.00)
        } else {
            inputAmount = String(transaction?.amount ?? 0.00)
        }
    }
}

struct ShowTransactionView: View {
    @Binding var editMode: Bool
    @Binding fileprivate var draft: Draft
    
    let transaction: Transaction?
    let dismiss: DismissAction
    
    let currencySymbol: String
    let amountFontSize: CGFloat
    let defaultCheckingName: String
    
    private var title: (name: String, symbol: String, color: Color) {
        if let cat = draft.category {
            return (cat.name, cat.symbol, cat.color)
        } else if let fund = draft.fund {
            return (fund.name, fund.symbol, fund.color)
        } else {
            return ("Unknown", "?", .gray)
        }
    }
    
    private var incomeName: String {
        if draft.isIncome {
            if draft.category != nil {
                return "Income"
            } else {
                return "Contribution"
            }
        } else {
            if draft.category != nil {
                return "Expense"
            } else {
                return "Utilization"
            }
        }
    }
    
    var body: some View {
        VStack {
            ZStack {
                Text(title.name)
                    .padding(6)
                    .glassEffect()
                    .offset(y: 50)
                
                Text(title.symbol)
                    .font(.largeTitle.bold())
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(title.color.opacity(0.6).gradient)
                    )
                    .shadow(color: title.color, radius: 5)
            }
            
            VStack {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(currencySymbol)
                        .font(.title)
                        .foregroundStyle(.secondary)
                    
                    Text(draft.amount, format: .number.precision(.fractionLength(2)))
                        .font(.system(size: amountFontSize, weight: .bold)) // Very large font, scales with Dynamic Type
                        .lineLimit(1)
                        .minimumScaleFactor(0.5) // Shrink to fit long amounts
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 28)
            
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Type", systemImage: "tray")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(incomeName)
                }
                
                Divider()
                
                HStack(alignment: .firstTextBaseline) {
                    Label("Date", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(draft.date.formatted(date: .long, time: .shortened))
                }
                
                Divider()
                
                HStack(alignment: .firstTextBaseline) {
                    Label("Recurrence", systemImage: "arrow.trianglehead.2.clockwise")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(draft.recurrence.rawValue.capitalized)
                }
                
                Divider()
                
                if let transaction, transaction.recurrence != .none, let nextOccurrence = transaction.nextOccurrence {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Next Occurrence", systemImage: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(nextOccurrence.formatted(date: .long, time: .omitted))
                    }
                    
                    Divider()
                }
                
                HStack(alignment: .firstTextBaseline) {
                    Label("\(draft.account?.accountType.rawValue ?? "Checking Account")", systemImage: "creditcard")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(draft.account?.name ?? defaultCheckingName)
                }
                
                Divider()
                
                HStack(alignment: .firstTextBaseline) {
                    Label("Notes", systemImage: "text.pad.header")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(draft.notes)
                }
            }
            .font(.headline)
            .frame(maxWidth: 360)
            .padding()
            .glassEffect(in: RoundedRectangle(cornerRadius: 26))
            
            Spacer()
        }
    }
}
