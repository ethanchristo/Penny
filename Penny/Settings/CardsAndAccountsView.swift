//
//  CardsAndAccountsView.swift
//  Penny
//
//  Created by Ethan Christo on 12/25/25.
//

import SwiftData
import SwiftUI

struct CardsAndAccountsView: View {
    @AppStorage("default_checking_name") private var defaultCheckingName: String = "Checking"
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Environment(\.modelContext) var modelContext
    
//    @Query(filter: \Transaction.account? == nil) var primaryTransactions: [Transaction]
    @Query(sort: \Account.name) var accounts: [Account]
    
    @State private var addAccount = false
    @State private var selectedAccount: Account?
    @State private var checkingNameSheet = false
    
    var creditCards: [Account] {
        accounts.filter { $0.accountType == .credit }
    }
    
    var checkingAccounts: [Account] {
        accounts.filter { $0.accountType == .checking }
    }
    
    var savingsAccounts: [Account] {
        accounts.filter { $0.accountType == .savings }
    }

    /// Live balances recorded on the last sync, merged from both bank-sync
    /// sources and keyed by `Account.externalID` (FinanceKit ids are namespaced,
    /// so the two never collide).
    private var liveBalances: [String: Double] {
        var balances = SimpleFINConfig.accountBalances
        balances.merge(FinanceKitConfig.accountBalances) { _, new in new }
        return balances
    }

    /// Formatted balance for a linked account: the last-synced live balance when
    /// available, otherwise derived from the account's own transactions.
    private func balanceText(for account: Account) -> String {
        let amount: Double
        if let externalID = account.externalID, let balance = liveBalances[externalID] {
            amount = balance
        } else {
            amount = (account.transactions ?? []).reduce(0.0) { $0 + ($1.isIncome ? $1.amount : -$1.amount) }
        }
        return amount.formatted(.currency(code: currencyCode))
    }

    /// Formatted balance for the primary checking account, whose live balance is
    /// keyed by whichever source designated it (SimpleFIN or FinanceKit).
    private var primaryCheckingBalanceText: String {
        let ids = [SimpleFINConfig.checkingID, FinanceKitConfig.checkingID].compactMap { $0 }
        let amount = ids.compactMap { liveBalances[$0] }.first ?? 0
        return amount.formatted(.currency(code: currencyCode))
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 10)
    ]
    
    var body: some View {
        List {
            Section {
                ForEach(creditCards) { card in
                    Button {
                        selectedAccount = card
                    } label: {
                        HStack {
                            Text(card.name)
                            Spacer()
                            Text(balanceText(for: card))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Credit Cards")
            }
            
            Section {
                Button {
                    
                } label: {
                    HStack {
                        Text(defaultCheckingName)
                        Spacer()
                        Text(primaryCheckingBalanceText)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                
                ForEach(checkingAccounts) { card in
                    Button {
                        selectedAccount = card
                    } label: {
                        HStack {
                            Text(card.name)
                            Spacer()
                            Text(balanceText(for: card))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Checking Accounts")
            }
            
            Section {
                ForEach(savingsAccounts) { card in
                    Button {
                        selectedAccount = card
                    } label: {
                        HStack {
                            Text(card.name)
                            Spacer()
                            Text(balanceText(for: card))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Savings Accounts")
            }
        }
        .listRowSpacing(12)
        
//        ScrollView {
//            LazyVGrid(columns: columns, spacing: 16) {
//                if !creditCards.isEmpty {
//                    Section {
//                        ForEach(creditCards) { card in
//                            Button {
//                                selectedAccount = card
//                            } label: {
//                                AccountCell(account: card)
//                                    .tint(.secondary)
//                            }
//                        }
//                    } header: {
//                        Text("Credit Cards")
//                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
//                            .padding(.horizontal)
//                            .font(.headline)
//                            .foregroundStyle(.secondary)
//                    }
//                }
//                
//                Section {
//                    ForEach(nonCreditAccounts) { account in
//                        Button {
//                            selectedAccount = account
//                        } label: {
//                            AccountCell(account: account)
//                                .tint(.secondary)
//                        }
//                    }
//                } header: {
//                    HStack {
//                        Text("Accounts")
//                            .foregroundStyle(Color.secondary)
//                        
//                        Menu {
//                            Button("Change default checking account name") {
//                                checkingNameSheet = true
//                            }
//                        } label: {
//                            Image(systemName: "ellipsis.circle")
//                        }
//                        .tint(.secondary)
//                        
//                    }
//                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
//                    .padding(.horizontal)
//                    .font(.headline)
//                }
//                
//            }
//            .padding(.horizontal, 10)
//        }
//        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("Cards & Accounts")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addAccount = true
                } label: {
                    Label("Add Card", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $addAccount) {
            NavigationStack {
                EditAccountView(account: nil)
            }
        }
        .sheet(item: $selectedAccount) { account in
            NavigationStack {
                EditAccountView(account: account)
            }
        }
        .sheet(isPresented: $checkingNameSheet) {
            NavigationStack {
                Form {
                    TextField("Checking Account Name", text: $defaultCheckingName)
                }
                .navigationTitle("Default Checking Account Name")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            checkingNameSheet = false
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                    }
                }
            }
            .presentationDetents([.fraction(0.2)])
        }
    }
    
    private func deleteAccount(_ indexSet: IndexSet) {
        for index in indexSet {
            let accountToDelete = accounts[index]
            
            modelContext.delete(accountToDelete)
        }
    }
}

struct AccountCell: View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"

    let account: Account

    /// The most recently closed statement for this card (nil for non-credit accounts).
    private var statement: CreditCardBalances? {
        creditCardStatement(for: account)
    }
    
    var body: some View {
        VStack {
            Text(account.name)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.bottom, 30)
            
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if account.accountType == .credit {
                        Text(amountTruncation(for: statement?.totalBalance ?? 0.0, currencySymbol: currencySymbol))
                    } else {
                        Text("$0.00")
                    }
                }
                .font(.title.bold())
                
                Group {
                    if account.accountType == .credit {
                        HStack(spacing: 2) {
                            Text(amountTruncation(for: statement?.balanceDue ?? 0.0, currencySymbol: currencySymbol))
                                .underline()
                            
                            Text("due on")
                            
                            Text(statement?.dueDate ?? .now, format: .dateTime.month().day().year())
                                .bold()
                        }
                    } else {
                        Text(account.accountType.rawValue.uppercased())
                    }
                    
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        }
        .padding()
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
    }
}

struct EditAccountView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    
    @State private var draftName = ""
    @State private var draftAccountType: AccountType = .checking
    @State private var draftClosingDate: Int = 1
    @State private var draftDueDate: Int = 1
    @State private var draftUseAvailableBalance = false
    
    @State private var newAccount = false
    
    let account: Account?

    private let numberRange = 1...28
    
    var body: some View {
        Form {
            Section {
                TextField("Account Name", text: $draftName)
            } header: {
                Text("Name")
            }
            
            Section {
                Picker("Account Type", selection: $draftAccountType) {
                    ForEach(AccountType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
            }
            
            if draftAccountType != .credit {
                Section {
                    Toggle("Use Available Balance", isOn: $draftUseAvailableBalance)
                } footer: {
                    Text("Use your bank's available balance (posted minus pending holds) for the net total instead of the posted balance.")
                }
            }

            if draftAccountType == .credit {
                Section {
                    Picker("Closing Date", selection: $draftClosingDate) {
                        ForEach(1...31, id: \.self) { num in
                            Text("\(num)").tag(num)
                        }
                    }
                    .pickerStyle(.wheel)
                } header: {
                    Text("Closing Date")
                } footer: {
                    Text("Select the day of the month of your credit card's closing date.")
                }
                
                Section {
                    Picker("Due Date", selection: $draftDueDate) {
                        ForEach(1...31, id: \.self) { num in
                            Text("\(num)").tag(num)
                        }
                    }
                    .pickerStyle(.wheel)
                } header: {
                    Text("Due Date")
                } footer: {
                    Text("Select the day of the month of your credit card's due date.")
                }
            }
        }
        .onAppear(perform: loadAccount)
        .navigationTitle(draftName.isEmpty ? "New Account" : draftName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Dismiss", systemImage: "xmark") {
                    if draftName.isEmpty {
                        if let existingAccount = account {
                            modelContext.delete(existingAccount)
                        }
                    }
                    
                    dismiss()
                }
            }
            
            ToolbarSpacer(.fixed, placement: .topBarLeading)
            
            ToolbarItem(placement: .topBarLeading) {
                if let existingAccount = account {
                    Button("Delete", systemImage: "trash") {
                        modelContext.delete(existingAccount)
                        
                        dismiss()
                    }
                    .tint(Color(.systemRed))
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    saveAccount()
                    dismiss()
                }
                // Prevent saving empty names if desired
                .disabled(draftName.isEmpty)
            }
        }
    }
    
    private func loadAccount() {
        if let existingAccount = account {
            draftName = existingAccount.name
            draftAccountType = existingAccount.accountType
            draftClosingDate = existingAccount.closingDate ?? 1
            draftDueDate = existingAccount.dueDate ?? 1
            draftUseAvailableBalance = existingAccount.useAvailableBalance
        }
    }
    
    private func saveAccount() {
        if let existingAccount = account {
            existingAccount.name = draftName
            existingAccount.accountType = draftAccountType
            existingAccount.closingDate = draftClosingDate
            existingAccount.dueDate = draftDueDate
        } else {
            let newAccount = Account(
                name: draftName,
                accountType: draftAccountType,
                closingDate: draftClosingDate,
                dueDate: draftDueDate
                )
            
            modelContext.insert(newAccount)
        }
    }
}
