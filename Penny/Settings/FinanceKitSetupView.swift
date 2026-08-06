//
//  FinanceKitSetupView.swift
//  Penny
//
//  The FinanceKit counterpart to SimpleFinSetupView: authorize Apple Wallet, map
//  each Wallet account to a Penny card / the primary checking / a new account /
//  skip, seed opening balances, then sync new transactions. Balances feed the net
//  total alongside SimpleFIN. A background-delivery extension keeps things current
//  without opening the app.
//

import SwiftUI
import SwiftData

/// Shared hybrid categoriser used by foreground syncs: the user's rules win, then
/// the on-device foundation model, then Miscellaneous. (The background extension
/// uses `FinanceKitImporter.rulesOnlyCategorize` instead.)
@MainActor
func financeKitHybridCategorize(_ notes: String,
                                categories: [Category],
                                fallback: Category?) async -> Category? {
    if let ruled = FinanceKitImporter.ruleCategory(notes: notes, categories: categories) { return ruled }
    let names = categories.map(\.name)
    if let predicted = await autoCategorize(text: notes, categories: names),
       let matched = categories.first(where: { $0.name == predicted }) {
        return matched
    }
    return fallback
}

struct FinanceKitSetupView: View {
    private enum Phase {
        case disconnected
        case working(String)
        case denied
        case mapping([FinanceKitAccountSnapshot])
        case connected
    }

    @Environment(\.modelContext) private var modelContext

    @State private var phase: Phase = .disconnected
    @State private var lastAccounts: [FinanceKitAccountSnapshot] = []
    @State private var errorMessage: String?
    @State private var lastSynced: Date?
    @State private var importSummary: String?

    // Accounts found in the feed that aren't mapped or skipped yet.
    @State private var newAccounts: [FinanceKitAccountSnapshot] = []
    @State private var isMappingNewAccounts = false

    @AppStorage("financekit_skip_recurring_duplicates", store: .group)
    private var skipRecurringDuplicates = true

    var body: some View {
        Group {
            if case .mapping(let accounts) = phase {
                FinanceKitAccountMappingView(remoteAccounts: accounts) {
                    finishMapping(accounts)
                } onCancel: {
                    cancelMapping()
                }
            } else {
                statusForm
            }
        }
        .navigationTitle("Apple Wallet")
        .task { await restoreExistingConnection() }
    }

    private var statusForm: some View {
        Form {
            switch phase {
            case .disconnected:
                connectSection
            case .working(let label):
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(label).foregroundStyle(.secondary)
                    }
                }
            case .denied:
                deniedSection
            case .mapping:
                EmptyView()
            case .connected:
                connectedSection
            }

            if let errorMessage {
                Section("Something went wrong") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var connectSection: some View {
        Section {
            Button("Connect Apple Wallet") {
                Task { await connect() }
            }
        } footer: {
            Text("Penny reads balances and transactions for the accounts in your Apple Wallet — Apple Card, Apple Cash, Apple Savings, and connected bank cards. Nothing leaves your device.")
        }
    }

    @ViewBuilder
    private var deniedSection: some View {
        Section {
            Label("Access not granted", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
            Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
        } footer: {
            Text("Penny doesn't have permission to read your Wallet financial data. Enable it for Penny in Settings, then try again.")
        }

        Section {
            Button("Try again") { Task { await connect() } }
        }
    }

    @ViewBuilder
    private var connectedSection: some View {
        if !newAccounts.isEmpty {
            Section {
                Button {
                    isMappingNewAccounts = true
                    phase = .mapping(newAccounts)
                } label: {
                    Label("Set up \(newAccounts.count) new account\(newAccounts.count == 1 ? "" : "s")",
                          systemImage: "creditcard.badge.plus")
                }
            } footer: {
                Text("Found \(newAccounts.count) account\(newAccounts.count == 1 ? "" : "s") in Apple Wallet that Penny isn't tracking yet. Map \(newAccounts.count == 1 ? "it" : "them") to start syncing.")
            }
        }

        Section {
            if lastAccounts.isEmpty {
                Label("Connected to Apple Wallet", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lastAccounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            if let org = account.institutionName {
                                Text(org)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(account.balanceFormatted)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Linked accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let importSummary {
                    Text(importSummary)
                }
                if let lastSynced {
                    Text("Last synced \(lastSynced.formatted(date: .abbreviated, time: .shortened)). New transactions also sync each time you open Penny.")
                }
            }
        }

        Section {
            Toggle("Skip recurring duplicates", isOn: $skipRecurringDuplicates)
        } footer: {
            Text("Don't import a transaction when its description and amount exactly match one you already track as recurring, so it isn't counted twice.")
        }

        Section {
            Button("Sync now") {
                Task { await sync() }
            }
            Button("Disconnect", role: .destructive) {
                disconnect()
            }
        }
    }

    // MARK: - Actions

    private func restoreExistingConnection() async {
        guard FinanceKitConfig.isConfigured else {
            // Not set up yet — reflect the current authorization state.
            let state = await FinanceKitClient.authorizationState()
            phase = (state == .denied) ? .denied : .disconnected
            return
        }
        await sync()
    }

    private func connect() async {
        errorMessage = nil
        phase = .working("Connecting to Apple Wallet…")

        let state = await FinanceKitClient.requestAuthorization()
        guard state == .authorized else {
            phase = .denied
            return
        }
        await loadAccountsForMapping()
    }

    /// First-connection step: pull accounts so the user can map them.
    private func loadAccountsForMapping() async {
        errorMessage = nil
        phase = .working("Loading your accounts…")
        do {
            let accounts = try await FinanceKitClient.fetchAccounts()
            FinanceKitConfig.recordBalances(from: accounts)
            phase = .mapping(accounts)
        } catch {
            errorMessage = error.localizedDescription
            phase = .disconnected
        }
    }

    /// Ongoing sync: import only transactions posted since each account's cutoff.
    private func sync() async {
        errorMessage = nil
        phase = .working("Syncing transactions…")
        do {
            // Fetch back to the earliest cutoff so transactions pending at setup
            // still import once they post, capped at a 90-day lookback.
            let floor = FinanceKitConfig.accountCutoffs.values.min()
                ?? FinanceKitConfig.connectedDate
            let accounts = try await FinanceKitClient.fetchAccounts(since: floor)
            lastAccounts = accounts

            let summary = await FinanceKitImporter.importNewTransactions(
                accounts,
                into: modelContext,
                categorize: financeKitHybridCategorize
            )

            newAccounts = FinanceKitImporter.unmappedAccounts(accounts, in: modelContext)
            importSummary = summary.imported == 0
                ? "Up to date — no new transactions."
                : "Imported \(summary.imported) new transaction\(summary.imported == 1 ? "" : "s")."

            lastSynced = .now
            FinanceKitConfig.lastSyncDate = .now
            phase = .connected
        } catch {
            errorMessage = error.localizedDescription
            phase = FinanceKitConfig.isConfigured ? .connected : .disconnected
        }
    }

    private func finishMapping(_ accounts: [FinanceKitAccountSnapshot]) {
        lastSynced = .now
        if isMappingNewAccounts {
            isMappingNewAccounts = false
            newAccounts = []
            importSummary = "New accounts added. Their purchases will sync from here on."
        } else {
            lastAccounts = accounts
            importSummary = "Opening balances added. New purchases will sync from here on."
        }
        phase = .connected
    }

    private func cancelMapping() {
        if isMappingNewAccounts {
            isMappingNewAccounts = false
            phase = .connected
        } else {
            disconnect()
        }
    }

    private func disconnect() {
        // Leaves already-imported transactions and accounts in place — only the
        // connection bookkeeping is removed.
        FinanceKitConfig.reset()
        lastAccounts = []
        errorMessage = nil
        lastSynced = nil
        importSummary = nil
        newAccounts = []
        isMappingNewAccounts = false
        phase = .disconnected
    }
}

// MARK: - First-connection mapping wizard

/// Assigns each fetched FinanceKit account to a destination, seeds opening
/// balances, and records the mapping. Mirrors SimpleFINAccountMappingView.
private struct FinanceKitAccountMappingView: View {
    let remoteAccounts: [FinanceKitAccountSnapshot]
    var onDone: () -> Void
    var onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var existingAccounts: [Account]

    private enum Destination: Hashable {
        case checking
        case existing(PersistentIdentifier)
        case createNew
        case skip
    }

    @State private var destinations: [String: Destination] = [:]
    @State private var newTypes: [String: AccountType] = [:]
    @State private var closingDates: [String: Int] = [:]
    @State private var dueDates: [String: Int] = [:]
    @State private var didPrepare = false

    private var checkingAlreadySet: Bool { FinanceKitConfig.checkingID != nil }

    var body: some View {
        Form {
            Section {
                Text(checkingAlreadySet
                     ? "Match each new account to one of your cards or create a new one. Penny adds its current balance as a starting point — individual purchases sync automatically after this."
                     : "Pick which account is your main checking, then match the rest to your cards or create new ones. Penny adds each account's current balance as a starting point — individual purchases sync automatically after this.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(remoteAccounts) { account in
                Section {
                    LabeledContent("Current balance", value: account.balanceFormatted)

                    Picker("Link to", selection: destinationBinding(for: account.id)) {
                        if !checkingAlreadySet {
                            Text("My checking account").tag(Destination.checking)
                        }
                        ForEach(existingAccounts) { existing in
                            Text(existing.name.isEmpty ? "Untitled account" : existing.name)
                                .tag(Destination.existing(existing.persistentModelID))
                        }
                        Text("Create new card").tag(Destination.createNew)
                        Text("Don't sync").tag(Destination.skip)
                    }

                    if destinations[account.id] == .createNew {
                        Picker("New card type", selection: newTypeBinding(for: account.id)) {
                            ForEach(AccountType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                    }

                    if mapsToCredit(account.id) {
                        Picker("Closing date", selection: closingBinding(for: account.id)) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("Due date", selection: dueBinding(for: account.id)) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                } header: {
                    Text(account.institutionName ?? account.displayName)
                } footer: {
                    if account.institutionName != nil {
                        Text(account.displayName)
                    }
                }
            }
        }
        .navigationTitle("Set Up Accounts")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { finish() }
            }
        }
        .onAppear(perform: prepareDefaults)
    }

    // MARK: Defaults & bindings

    private func prepareDefaults() {
        guard !didPrepare else { return }
        didPrepare = true

        for account in remoteAccounts {
            newTypes[account.id] = guessType(for: account)

            if let match = existingAccounts.first(where: {
                !$0.name.isEmpty && $0.name.caseInsensitiveCompare(account.displayName) == .orderedSame
            }) {
                destinations[account.id] = .existing(match.persistentModelID)
                closingDates[account.id] = match.closingDate ?? 1
                dueDates[account.id] = match.dueDate ?? 1
            } else {
                destinations[account.id] = .createNew
            }
        }
    }

    private func guessType(for account: FinanceKitAccountSnapshot) -> AccountType {
        if account.isLiability || account.balanceValue < 0 { return .credit }
        if account.displayName.localizedCaseInsensitiveContains("saving") { return .savings }
        return .checking
    }

    private func destinationBinding(for id: String) -> Binding<Destination> {
        Binding(
            get: { destinations[id] ?? .createNew },
            set: { newValue in
                if newValue == .checking {
                    for key in destinations.keys where key != id && destinations[key] == .checking {
                        destinations[key] = .skip
                    }
                }
                destinations[id] = newValue

                if case .existing(let pid) = newValue,
                   let account = existingAccounts.first(where: { $0.persistentModelID == pid }),
                   account.accountType == .credit {
                    closingDates[id] = account.closingDate ?? 1
                    dueDates[id] = account.dueDate ?? 1
                }
            }
        )
    }

    private func newTypeBinding(for id: String) -> Binding<AccountType> {
        Binding(get: { newTypes[id] ?? .checking }, set: { newTypes[id] = $0 })
    }

    private func closingBinding(for id: String) -> Binding<Int> {
        Binding(get: { closingDates[id] ?? 1 }, set: { closingDates[id] = $0 })
    }

    private func dueBinding(for id: String) -> Binding<Int> {
        Binding(get: { dueDates[id] ?? 1 }, set: { dueDates[id] = $0 })
    }

    private func mapsToCredit(_ id: String) -> Bool {
        switch destinations[id] ?? .skip {
        case .createNew:
            return (newTypes[id] ?? .checking) == .credit
        case .existing(let pid):
            return existingAccounts.first { $0.persistentModelID == pid }?.accountType == .credit
        default:
            return false
        }
    }

    // MARK: Commit

    private func finish() {
        for account in remoteAccounts {
            switch destinations[account.id] ?? .skip {
            case .checking:
                FinanceKitConfig.checkingID = account.id
                FinanceKitImporter.seedOpeningBalance(for: account, type: .checking,
                                                      account: nil, into: modelContext)

            case .existing(let pid):
                guard let target = existingAccounts.first(where: { $0.persistentModelID == pid }) else { continue }
                target.externalID = account.id
                if target.accountType == .credit {
                    target.closingDate = closingDates[account.id] ?? target.closingDate ?? 1
                    target.dueDate = dueDates[account.id] ?? target.dueDate ?? 1
                }
                FinanceKitImporter.seedOpeningBalance(for: account, type: target.accountType,
                                                      account: target, into: modelContext)

            case .createNew:
                let type = newTypes[account.id] ?? .checking
                let created = Account(name: account.displayName, accountType: type,
                                      closingDate: closingDates[account.id] ?? 1,
                                      dueDate: dueDates[account.id] ?? 1,
                                      externalID: account.id)
                modelContext.insert(created)
                FinanceKitImporter.seedOpeningBalance(for: account, type: type,
                                                      account: created, into: modelContext)

            case .skip:
                FinanceKitConfig.markSkipped(account.id)
                continue
            }

            FinanceKitConfig.setCutoff(FinanceKitImporter.importCutoff(for: account),
                                       for: account.id)
        }

        if FinanceKitConfig.connectedDate == nil {
            FinanceKitConfig.connectedDate = .now
        }
        try? modelContext.save()
        onDone()
    }
}
