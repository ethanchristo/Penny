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
    // A transaction is tagged with EITHER a category OR a freestanding budget, never both.
    // `Draft` is a plain struct (not an @Model), so didSet fires normally here
    // and — because `draft` lives in @State — the view re-renders on any change.
    var category: Category? = nil {
        didSet { if category != nil { budget = nil } }
    }
    var budget: Budget? = nil {
        didSet { if budget != nil { category = nil } }
    }
    var notes: String = ""
    var recurrence: Recurrence = .none
    var endDate: Date? = nil

    // An elegant initializer that automatically populates the draft
    // if you pass it an existing transaction!
    init(from transaction: Transaction? = nil, defaultCategory: Category? = nil, defaultBudget: Budget? = nil) {
        if let tx = transaction {
            self.amount = tx.amount
            self.isIncome = tx.isIncome
            self.date = tx.date
            self.account = tx.account
            self.category = tx.amount == 0.0 ? defaultCategory : tx.category
            self.budget = tx.budget
            self.notes = tx.notes
            self.recurrence = tx.recurrence
            self.endDate = tx.endDate
        } else if let defaultBudget {
            // New transaction pre-tagged with the passed-in budget
            self.budget = defaultBudget
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
    @State private var showDeleteConfirmation = false

    let initialEditMode: Bool
    let transaction: Transaction?
    let category: Category?
    let budget: Budget?

    private var title: String {
        if editMode {
            if let transaction {
                if !transaction.notes.isEmpty {
                    return transaction.notes
                } else if let cat = transaction.category {
                    return cat.name
                } else if let budget = transaction.budget {
                    return budget.displayName
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
                    budget: budget,
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
                if transaction != nil {
                    Button("Delete", systemImage: "trash") {
                        showDeleteConfirmation = true
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
                        .disabled(draft.amount == 0.0 || (draft.category == nil && draft.budget == nil))
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
        .alert("Delete Transaction?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let existingTx = transaction {
                    if let externalID = existingTx.externalID {
                        SimpleFINConfig.dismissExternalID(externalID)
                    }
                    modelContext.delete(existingTx)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func loadTransaction() -> Void {
        // Find the fallback category once
        let miscCategory = categories.first(where: { $0.name == "Miscellaneous" })
        
        if miscCategory == nil && transaction == nil {
            log.error("Miscellaneous category not found")
        }
        
        // Let the struct do all the heavy lifting!
        // A passed-in category/budget pre-populates the draft for new transactions.
        draft = Draft(from: transaction, defaultCategory: category ?? miscCategory, defaultBudget: budget)
    }
    
    private func saveTransaction() -> Void {
        guard let finalCategory = draft.category ?? categories.first(where: { $0.name == "Miscellaneous" }) else {
            log.fault("No category could be determined when saving transaction")
            return
        }
        
        if let existingTx = transaction {
            // Capture state needed to learn a category rule BEFORE we overwrite it.
            let wasImported = existingTx.externalID != nil
            let previousCategory = existingTx.category

            // Update existing
            existingTx.amount = draft.amount
            existingTx.isIncome = draft.isIncome
            existingTx.date = draft.date
            existingTx.notes = draft.notes
            existingTx.account = draft.account
            existingTx.category = finalCategory
            existingTx.budget = draft.budget
            existingTx.recurrence = draft.recurrence
            existingTx.endDate = draft.endDate

            // If the user manually re-categorized an imported transaction, remember
            // the choice as a rule so future imports of the same merchant match it.
            if wasImported, draft.budget == nil {
                learnCategoryRule(
                    notes: draft.notes,
                    newCategory: finalCategory,
                    previousCategory: previousCategory
                )
            }
        } else {
            // Create brand new
            let newTx = Transaction(
                amount: draft.amount,
                isIncome: draft.isIncome,
                date: draft.date,
                account: draft.account,
                category: finalCategory,
                budget: draft.budget,
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

    /// Creates a category rule keyed on an imported transaction's notes/merchant so
    /// that future SimpleFIN / FinanceKit imports of the same merchant are assigned
    /// the category the user just chose. No-ops when there's nothing to match on or
    /// when the category didn't actually change.
    private func learnCategoryRule(notes: String, newCategory: Category, previousCategory: Category?) -> Void {
        let keyword = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // Need a merchant/notes string to match against, and the category must have
        // actually changed — no point recording a rule for an unchanged category.
        guard !keyword.isEmpty, previousCategory?.id != newCategory.id else { return }

        // Remove any existing rules on OTHER categories that match this exact keyword,
        // so the re-categorization actually takes effect (rule matching returns the
        // first category whose rule matches).
        for category in categories where category.id != newCategory.id {
            category.rules?.removeAll { rule in
                (rule.inputNotes ?? "").caseInsensitiveCompare(keyword) == .orderedSame
            }
        }

        // Don't duplicate a rule that already exists on the target category.
        let alreadyExists = (newCategory.rules ?? []).contains { rule in
            (rule.inputNotes ?? "").caseInsensitiveCompare(keyword) == .orderedSame
        }
        guard !alreadyExists else { return }

        let rule = CategoryRules(inputNotes: keyword)
        rule.category = newCategory
        newCategory.rules = (newCategory.rules ?? []) + [rule]
        modelContext.insert(rule)

        log.info("Learned category rule '\(keyword, privacy: .public)' → \(newCategory.name, privacy: .public)")
    }
}

struct EditTransactionView: View {
    @AppStorage("decimal_pad_type") private var decimalPadType: DecimalPadType = .ATM
        
    @Query(sort: \Account.name) var accounts: [Account]
    @Query(sort: \Category.name) var categories: [Category]
    @Query(sort: \Budget.name) var budgets: [Budget]

    /// Only freestanding budgets can be tagged directly on a transaction.
    private var freestandingBudgets: [Budget] {
        budgets.filter { $0.isFreestanding && $0.hasBudget }
    }

    @Binding fileprivate var draft: Draft

    @State private var inputAmount: String = ""

    @State private var showNotesSheet: Bool = false
    @State private var showDateSheet: Bool = false
    @State private var showRecurringSheet: Bool = false

    @State private var addAccount = false
    @State private var addCategory = false
    @State private var addBudget = false
    
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
    let budget: Budget?

    let dismiss: DismissAction
    
    let currencySymbol: String
    let amountFontSize: CGFloat
    let defaultCheckingName: String
    
    var body: some View {
        VStack {
//            Picker("", selection: $draft.isIncome) {
//                if draft.fund?.preAllocate != true {
//                    Label(incomeName, systemImage: "tray.and.arrow.down").tag(true)
//                }
//                
//                Label(expenseName, systemImage: "tray.and.arrow.up").tag(false)
//            }
//            .pickerStyle(.palette)
//            .frame(maxWidth: .infinity)
//            .padding(.top, 10)
//            .padding(.horizontal, 20)
//            
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
                        .lineLimit(1)
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
                .disabled(draft.budget != nil)

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
                    .lineLimit(1)
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
                            addBudget = true
                        } label: {
                            Label("Add Budget", systemImage: "plus")
                        }

                        Divider()

                        Picker("Budget", selection: $draft.budget) {
                            ForEach(freestandingBudgets) { budget in
                                Text("\(budget.symbol)  \(budget.name)").tag(budget as Budget?)
                            }
                        }
                    } label: {
                        Label("Budget", systemImage: "rectangle.stack.fill")
                        if let budget = draft.budget {
                            Text(budget.name)
                                .font(.caption)
                        }
                    }
                } label: {
                    Group {
                        if let category = draft.category {
                            Text(category.symbol)
                                .padding(9)
                                .glassEffect(.regular.tint(category.color.opacity(0.5)))
                        } else if let budget = draft.budget {
                            Text(budget.symbol)
                                .padding(9)
                                .glassEffect(.regular.tint(budget.color.opacity(0.5)))
                        } else {
                            Text("Category/Budget")
                                .padding(8)
                                .glassEffect()
                        }
                    }
                }
            }
            .font(.headline)
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
                }
            }
            .tint(.primary)
            .padding(.horizontal, 10)
        }
        .interactiveDismissDisabled(draft.amount == 0.0)
        .onAppear {
            loadAmount()
        }
        .onChange(of: draft.budget) {
            // Pre-funded budgets only support expenses ("Utilization"), so force expense for them.
            // Contribute-toward budgets allow contributions (income), so leave isIncome alone —
            // otherwise loading an existing income transaction would reset it to expense.
            if draft.budget?.preFunding == true {
                draft.isIncome = false
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: inputAmount)
        .sensoryFeedback(.impact(weight: .light), trigger: draft.isIncome)
        .toolbar {
            ToolbarItem {
                Picker("Type", selection: $draft.isIncome) {
                    if draft.budget?.preFunding != true {
                        Text(incomeName).tag(true)
                    }
                    
                    Text(expenseName).tag(false)
                }
                .pickerStyle(.palette)
            }
            .sharedBackgroundVisibility(.hidden)
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
                            Toggle(
                                "End Date",
                                isOn: Binding(
                                    get: { draft.endDate != nil },
                                    set: { isOn in
                                        draft.endDate = isOn ? draft.date.endOfDay : nil
                                    }
                                )
                            )
                        }

                        if draft.endDate != nil {
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
        .sheet(isPresented: $addBudget) {
            NavigationStack {
                EditBudgetView(budget: nil)
            }
        }
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
        } else if let budget = draft.budget {
            return (budget.name, budget.symbol, budget.color)
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
                Text(title.symbol)
                    .font(.largeTitle.bold())
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(title.color.opacity(0.6).gradient)
                    )
                    .shadow(color: title.color, radius: 5)
                
                Text(title.name)
                    .padding(6)
                    .glassEffect()
                    .offset(y: 50)
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
