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
    
    @Query(sort: \Account.name) var accounts: [Account]
    
    @State private var addAccount = false
    @State private var selectedAccount: Account?
    @State private var editDefaultChecking = false
    
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
                    editDefaultChecking = true
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
        .sheet(isPresented: $editDefaultChecking) {
            NavigationStack {
                EditDefaultCheckingView(checkingName: $defaultCheckingName)
            }
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

    @Query private var allAccounts: [Account]

    @State private var draftName = ""
    @State private var draftAccountType: AccountType = .checking
    @State private var draftClosingDate: Int = 1
    @State private var draftDueDate: Int = 1
    @State private var draftUseAvailableBalance = false
    @State private var draftLinkedID: String?

    @State private var newAccount = false

    let account: Account?

    private let numberRange = 1...28

    /// Synced accounts offered in the reassignment picker. Always includes this
    /// card's current link even if the last sync predates name-recording.
    private var linkOptions: [SyncedAccountOption] {
        var options = BankSyncMapping.knownAccounts()
        if let ext = account?.externalID,
           !options.contains(where: { $0.id == ext }) {
            options.append(SyncedAccountOption(id: ext,
                                               name: BankSyncMapping.name(for: ext) ?? "Linked account"))
        }
        return options
    }

    private var showsBankLink: Bool {
        BankSyncMapping.isConfigured || account?.externalID != nil
    }
    
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

            if showsBankLink {
                Section {
                    Picker("Bank Account", selection: $draftLinkedID) {
                        Text("Not linked").tag(String?.none)
                        ForEach(linkOptions) { option in
                            Text(BankSyncMapping.label(for: option)).tag(String?.some(option.id))
                        }
                    }
                } header: {
                    Text("Linked Bank Account")
                } footer: {
                    Text("Choose which synced bank account feeds this card. Its bank-imported transactions move to this card, and new ones sync here from now on. \"Not linked\" stops syncing — transactions already imported stay put.")
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
            draftLinkedID = existingAccount.externalID
        }
    }

    private func saveAccount() {
        let target: Account
        if let existingAccount = account {
            existingAccount.name = draftName
            existingAccount.accountType = draftAccountType
            existingAccount.closingDate = draftClosingDate
            existingAccount.dueDate = draftDueDate
            target = existingAccount
        } else {
            let newAccount = Account(
                name: draftName,
                accountType: draftAccountType,
                closingDate: draftClosingDate,
                dueDate: draftDueDate
                )

            modelContext.insert(newAccount)
            target = newAccount
        }

        // Apply any reassignment: move the bank link (and its transactions) to
        // this card, or unlink it.
        BankSyncMapping.link(draftLinkedID, to: target, among: allAccounts, in: modelContext)
    }
}

struct EditDefaultCheckingView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var allAccounts: [Account]

    @Binding var checkingName: String

    /// Persisted in the shared App Group so the SimpleFIN importer resolves the
    /// same preference when recording the primary checking's live balance.
    @AppStorage("default_checking_use_available_balance", store: .group)
    private var useAvailableBalance: Bool = false

    @State private var draftCheckingID: String?

    /// Synced accounts offered as the primary checking. Always includes the current
    /// designation even if the last sync predates name-recording.
    private var checkingOptions: [SyncedAccountOption] {
        var options = BankSyncMapping.knownAccounts()
        if let id = BankSyncMapping.primaryCheckingID,
           !options.contains(where: { $0.id == id }) {
            options.append(SyncedAccountOption(id: id,
                                               name: BankSyncMapping.name(for: id) ?? "Linked account"))
        }
        return options
    }

    var body: some View {
        Form {
            Section {
                TextField("Account Name", text: $checkingName)
            } header: {
                Text("Name")
            }

            if BankSyncMapping.isConfigured {
                Section {
                    Picker("Bank Account", selection: $draftCheckingID) {
                        Text("Not linked").tag(String?.none)
                        ForEach(checkingOptions) { option in
                            Text(BankSyncMapping.label(for: option)).tag(String?.some(option.id))
                        }
                    }
                } header: {
                    Text("Linked Bank Account")
                } footer: {
                    Text("Choose which synced bank account is your primary checking. Its live balance drives your checking total, and its bank-imported transactions move here.")
                }
            }

            Section {
                Toggle("Use Available Balance", isOn: $useAvailableBalance)
            } footer: {
                Text("Use your bank's available balance (posted minus pending holds) for the net total instead of the posted balance.")
            }
        }
        .navigationTitle("Default Checking Account")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { draftCheckingID = BankSyncMapping.primaryCheckingID }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    BankSyncMapping.setPrimaryChecking(draftCheckingID, among: allAccounts, in: modelContext)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Reassigning bank-synced accounts

/// One bank-synced account known from the last sync, used by the Cards & Accounts
/// screen to let the user reassign which Penny card (or the primary checking) it
/// feeds — without a live re-fetch. `id` is the value stored on `Account.externalID`.
struct SyncedAccountOption: Identifiable, Hashable {
    let id: String
    let name: String

    /// FinanceKit external ids are namespaced `financekit-…`; everything else is
    /// SimpleFIN. Lets the picker label the source and route config writes.
    var isFinanceKit: Bool { id.hasPrefix("financekit-") }
    var sourceLabel: String { isFinanceKit ? "Apple Wallet" : "Bank Sync" }
}

/// Bridges the two bank-sync configs so the reassignment UI reads the known
/// accounts and moves their mapping (to a Penny card, the primary checking, or
/// nothing) from one place. Only future syncs are affected — transactions already
/// imported keep whichever account they landed on.
enum BankSyncMapping {
    static var isConfigured: Bool {
        SimpleFINConfig.isConfigured || FinanceKitConfig.isConfigured
    }

    /// True when both sources are connected, so pickers disambiguate by source.
    static var showsSourceLabels: Bool {
        SimpleFINConfig.isConfigured && FinanceKitConfig.isConfigured
    }

    /// Every account seen on the last sync from either source, sorted by name.
    static func knownAccounts() -> [SyncedAccountOption] {
        var byID = SimpleFINConfig.accountNames
        byID.merge(FinanceKitConfig.accountNames) { _, new in new }
        return byID
            .map { SyncedAccountOption(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Display name last seen for an external id, if any.
    static func name(for id: String) -> String? {
        SimpleFINConfig.accountNames[id] ?? FinanceKitConfig.accountNames[id]
    }

    /// Picker label for an option, appending the source only when both are connected.
    static func label(for option: SyncedAccountOption) -> String {
        showsSourceLabels ? "\(option.name) (\(option.sourceLabel))" : option.name
    }

    /// The external id currently designated as the primary checking. Only one
    /// source designates it in practice; SimpleFIN wins the tie, matching the net
    /// total's resolution order.
    static var primaryCheckingID: String? {
        SimpleFINConfig.checkingID ?? FinanceKitConfig.checkingID
    }

    private static func isFinanceKit(_ id: String) -> Bool { id.hasPrefix("financekit-") }

    private static func markSkipped(_ id: String) {
        if isFinanceKit(id) { FinanceKitConfig.markSkipped(id) }
        else { SimpleFINConfig.markSkipped(id) }
    }

    private static func unskip(_ id: String) {
        if isFinanceKit(id) {
            var ids = FinanceKitConfig.skippedIDs
            ids.removeAll { $0 == id }
            FinanceKitConfig.skippedIDs = ids
        } else {
            var ids = SimpleFINConfig.skippedIDs
            ids.removeAll { $0 == id }
            SimpleFINConfig.skippedIDs = ids
        }
    }

    private static func setCheckingID(_ id: String?) {
        // Only one source designates the checking, so clear both then set one.
        SimpleFINConfig.checkingID = nil
        FinanceKitConfig.checkingID = nil
        guard let id else { return }
        if isFinanceKit(id) { FinanceKitConfig.checkingID = id }
        else { SimpleFINConfig.checkingID = id }
    }

    /// The bank-imported transactions sitting on one bucket — a specific card, or
    /// the primary-checking bucket when `owner` is nil (`account == nil`). Manual,
    /// email, and file entries (which have no `externalID`) are left untouched.
    private static func syncedTransactions(on owner: Account?,
                                           from all: [Transaction]) -> [Transaction] {
        all.filter { $0.externalID != nil
            && $0.account?.persistentModelID == owner?.persistentModelID }
    }

    /// A destination a bank feed can occupy: a Penny card, or the primary-checking
    /// bucket (`account == nil`). Reads/writes its id designation and locates its
    /// bank-imported transactions, so both slot kinds are handled uniformly.
    private enum Slot {
        case card(Account)
        case checking

        /// The account transactions live on for this slot (`nil` for checking).
        var owner: Account? {
            if case .card(let account) = self { return account }
            return nil
        }

        var currentID: String? {
            switch self {
            case .card(let account): return account.externalID
            case .checking: return BankSyncMapping.primaryCheckingID
            }
        }

        func setID(_ id: String?) {
            switch self {
            case .card(let account): account.externalID = id
            case .checking: BankSyncMapping.setCheckingID(id)
            }
        }

        func isSame(as other: Slot) -> Bool {
            switch (self, other) {
            case (.checking, .checking): return true
            case (.card(let a), .card(let b)): return a.persistentModelID == b.persistentModelID
            default: return false
            }
        }
    }

    /// Points `account` at a different synced account (or `nil` to unlink). See
    /// `assign` for how transactions follow.
    static func link(_ newID: String?, to account: Account,
                     among accounts: [Account], in context: ModelContext) {
        assign(newID, to: .card(account), among: accounts, in: context)
    }

    /// Designates `newID` as the primary checking (or `nil` to unlink it), so its
    /// live balance drives the `account == nil` checking total. See `assign`.
    static func setPrimaryChecking(_ newID: String?, among accounts: [Account],
                                   in context: ModelContext) {
        assign(newID, to: .checking, among: accounts, in: context)
    }

    /// Moves the `newID` feed onto `target`, swapping with wherever that feed
    /// currently lives so the operation is fully reversible: `target`'s old feed
    /// (id *and* its transactions) moves to the slot the new feed just vacated. A
    /// feed's transactions and its id designation therefore always travel together
    /// — reverting a mistaken remap restores the exact prior state. Only the
    /// bank-imported transactions move; manual/email/file entries stay put.
    ///
    /// Unlinking (`newID == nil`), or pointing at a feed that isn't currently
    /// mapped anywhere, has no partner slot: the target's old transactions stay on
    /// it and the orphaned id is skipped so it doesn't nag as "unmapped".
    private static func assign(_ newID: String?, to target: Slot,
                               among accounts: [Account], in context: ModelContext) {
        let oldID = target.currentID
        guard newID != oldID else { return }

        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []

        // Where newID's feed currently lives (its partner slot), if anywhere.
        let partner: Slot? = {
            guard let newID else { return nil }
            if let card = accounts.first(where: {
                $0.externalID == newID && !target.isSame(as: .card($0))
            }) {
                return .card(card)
            }
            if newID == primaryCheckingID, !target.isSame(as: .checking) {
                return .checking
            }
            return nil
        }()

        // Snapshot both feeds before mutating so the two sets stay disjoint.
        let incoming = partner.map { syncedTransactions(on: $0.owner, from: all) } ?? []
        let displaced = syncedTransactions(on: target.owner, from: all)

        // Swap the id designations: target takes newID, partner takes target's old.
        target.setID(newID)
        partner?.setID(oldID)
        if let newID { unskip(newID) }
        if partner != nil, let oldID { unskip(oldID) }

        // Transactions follow their feed.
        for txn in incoming { txn.account = target.owner }
        if let partner {
            for txn in displaced { txn.account = partner.owner }
        }

        // With no partner the old id no longer designates any slot — skip it so a
        // future sync doesn't resurface it as an unmapped account. (Its
        // transactions stay on the target as historical entries.)
        if partner == nil, let oldID {
            markSkipped(oldID)
        }

        try? context.save()
    }
}
