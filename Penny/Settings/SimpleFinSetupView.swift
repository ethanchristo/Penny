//
//  SimpleFinSetupView.swift
//  Penny
//
//  Created by Ethan Christo on 6/10/26.
//

import SwiftUI
import SwiftData

struct SimpleFinSetupView: View {
    private enum Phase {
        case disconnected
        case working(String)                 // label shown while busy
        case mapping([SimpleFINAccount])     // first-connection account setup
        case connected
    }

    @Environment(\.modelContext) private var modelContext

    @State private var phase: Phase = .disconnected
    @State private var setupToken = ""
    @State private var lastAccounts: [SimpleFINAccount] = []
    @State private var bridgeErrors: [String] = []
    @State private var errorMessage: String?
    @State private var lastSynced: Date?
    @State private var importSummary: String?

    // Accounts found in the feed that aren't mapped or skipped yet (e.g. a card
    // added on the SimpleFIN portal after setup). Surfaced as a banner so the
    // user can map them. `isMappingNewAccounts` distinguishes this incremental
    // mapping from the first-connection wizard (which seeds the whole account set).
    @State private var newAccounts: [SimpleFINAccount] = []
    @State private var isMappingNewAccounts = false

    // Mirrors SimpleFINConfig.skipRecurringDuplicates. Stored in the shared App
    // Group suite and defaults to true so the importer skips duplicates by default.
    @AppStorage("simplefin_skip_recurring_duplicates", store: .group)
    private var skipRecurringDuplicates = true

    var body: some View {
        Group {
            if case .mapping(let accounts) = phase {
                SimpleFINAccountMappingView(remoteAccounts: accounts) {
                    finishMapping(accounts)
                } onCancel: {
                    cancelMapping()
                }
            } else {
                statusForm
            }
        }
        .navigationTitle("Bank Sync")
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
            case .mapping:
                EmptyView()   // handled above
            case .connected:
                connectedSection
            }

            if let errorMessage {
                Section("Something went wrong") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            // The Bridge docs say to always surface these to the user —
            // they include things like "reconnect your bank" notices.
            if !bridgeErrors.isEmpty {
                Section("Messages from SimpleFIN") {
                    ForEach(bridgeErrors, id: \.self) {
                        Text($0).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var connectSection: some View {
        Section {
            Link("Get a Setup Token from SimpleFIN",
                 destination: URL(string: "https://bridge.simplefin.org/simplefin/create")!)
        }
        
        Section {
            TextField("Paste your Setup Token", text: $setupToken, axis: .vertical)
                .lineLimit(3...6)
                .font(.footnote.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("Connect") {
                Task { await connect() }
            }
            .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } footer: {
            Text("Setup Tokens work once. Penny trades it for an access key stored in your Keychain — your bank login never touches this app.")
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
                Text("Found \(newAccounts.count) account\(newAccounts.count == 1 ? "" : "s") in your bank feed that Penny isn't tracking yet. Map \(newAccounts.count == 1 ? "it" : "them") to start syncing.")
            }
        }

        Section {
            if lastAccounts.isEmpty {
                Label("Connected to SimpleFIN", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lastAccounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            if let org = account.org?.name {
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
                    Text("Last synced \(lastSynced.formatted(date: .abbreviated, time: .shortened)). SimpleFIN refreshes data about once a day, so there's no benefit to syncing more often.")
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
        guard SimpleFINStore.loadAccessURL() != nil else { return }
        if SimpleFINConfig.isConfigured {
            await sync()
        } else {
            // Token was claimed but setup never finished — resume the mapping step.
            await loadAccountsForMapping()
        }
    }

    private func connect() async {
        errorMessage = nil
        phase = .working("Connecting to SimpleFIN…")
        do {
            let accessURL = try await SimpleFINClient.claim(setupToken: setupToken)
            SimpleFINStore.saveAccessURL(accessURL)
            setupToken = ""   // one-time use; nothing to keep
            await loadAccountsForMapping()
        } catch {
            errorMessage = error.localizedDescription
            phase = .disconnected
        }
    }

    /// First-connection step: pull the accounts so the user can map them.
    private func loadAccountsForMapping() async {
        guard let accessURL = SimpleFINStore.loadAccessURL() else {
            phase = .disconnected
            return
        }
        errorMessage = nil
        phase = .working("Loading your accounts…")
        do {
            // The Bridge caps each request's date range at 90 days,
            // so ask for 89 to stay safely inside it.
            let startDate = Calendar.current.date(byAdding: .day, value: -89, to: .now)
            let result = try await SimpleFINClient.fetchAccounts(accessURL: accessURL,
                                                                 startDate: startDate)
            bridgeErrors = result.errors
            SimpleFINConfig.recordBalances(from: result.accounts)
            phase = .mapping(result.accounts)
        } catch {
            errorMessage = error.localizedDescription
            phase = .disconnected
        }
    }

    /// Ongoing sync: import only transactions posted since the connection date.
    private func sync() async {
        guard let accessURL = SimpleFINStore.loadAccessURL() else {
            phase = .disconnected
            return
        }
        errorMessage = nil
        phase = .working("Syncing transactions…")
        do {
            // Fetch back to the earliest per-account cutoff so the Bridge returns
            // transactions that were pending at setup and have since posted with a
            // date before the connection date — but never reach past its 90-day
            // window. Falls back to the connection date when no cutoffs are stored.
            let earliest = Calendar.current.date(byAdding: .day, value: -89, to: .now)
            let cutoffFloor = SimpleFINConfig.accountCutoffs.values.min()
                ?? SimpleFINConfig.connectedDate
                ?? earliest ?? .now
            let startDate = max(cutoffFloor, earliest ?? .distantPast)
            let result = try await SimpleFINClient.fetchAccounts(accessURL: accessURL,
                                                                 startDate: startDate)
            bridgeErrors = result.errors
            lastAccounts = result.accounts

            let summary = await SimpleFINImporter.importNewTransactions(result.accounts,
                                                                        into: modelContext)

            // Surface accounts added on the portal since setup so the user can map them.
            newAccounts = SimpleFINImporter.unmappedAccounts(result.accounts, in: modelContext)
            importSummary = summary.imported == 0
                ? "Up to date — no new transactions."
                : "Imported \(summary.imported) new transaction\(summary.imported == 1 ? "" : "s")."

            lastSynced = .now
            SimpleFINConfig.lastSyncDate = .now
            phase = .connected
        } catch {
            errorMessage = error.localizedDescription
            // Keep the connection — a failed sync doesn't mean a dead token.
            phase = SimpleFINConfig.isConfigured ? .connected : .disconnected
        }
    }

    /// Mapping wizard finished (seeded opening balances + cutoffs already done).
    private func finishMapping(_ accounts: [SimpleFINAccount]) {
        lastSynced = .now
        if isMappingNewAccounts {
            isMappingNewAccounts = false
            newAccounts = []   // these are now mapped or skipped
            importSummary = "New accounts added. Their purchases will sync from here on."
        } else {
            lastAccounts = accounts
            importSummary = "Opening balances added. New purchases will sync from here on."
        }
        phase = .connected
    }

    /// Mapping wizard cancelled. For the first connection there's nothing to keep,
    /// so disconnect; for newly-found accounts just return — the banner stays so
    /// they can be set up later.
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
        // connection itself is removed.
        SimpleFINStore.deleteAccessURL()
        SimpleFINConfig.reset()
        lastAccounts = []
        bridgeErrors = []
        errorMessage = nil
        lastSynced = nil
        importSummary = nil
        newAccounts = []
        isMappingNewAccounts = false
        phase = .disconnected
    }
}

// MARK: - First-connection mapping wizard

/// Lets the user assign each fetched SimpleFIN account to a destination, then
/// seeds opening balances and records the mapping. Shown only on first connect.
private struct SimpleFINAccountMappingView: View {
    let remoteAccounts: [SimpleFINAccount]
    var onDone: () -> Void
    var onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var existingAccounts: [Account]

    /// Where a fetched SimpleFIN account should land in Penny.
    private enum Destination: Hashable {
        case checking                       // the primary checking -> account == nil
        case existing(PersistentIdentifier) // match an account already in Penny
        case createNew                      // make a new Penny card
        case skip                           // don't sync this account
    }

    @State private var destinations: [String: Destination] = [:]
    @State private var newTypes: [String: AccountType] = [:]
    // Day-of-month closing/due dates captured for accounts that map to a credit
    // card, so the "Amount Due" net-total mode has real statement dates instead of
    // the default 1st (which makes the statement window meaningless).
    @State private var closingDates: [String: Int] = [:]
    @State private var dueDates: [String: Int] = [:]
    @State private var didPrepare = false

    /// True once a primary checking account is designated. In that case this is an
    /// incremental run (mapping newly-found cards), so the checking option is hidden.
    private var checkingAlreadySet: Bool { SimpleFINConfig.checkingID != nil }

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
                        // Only offer "checking" until one is designated — later runs
                        // (mapping newly-added cards) shouldn't reassign it.
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

                    // Statement dates for anything that resolves to a credit card, so
                    // "Amount Due" has a real billing cycle to work from.
                    if mapsToCredit(account.id) {
                        Picker("Closing date", selection: closingBinding(for: account.id)) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("Due date", selection: dueBinding(for: account.id)) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                } header: {
                    Text(account.org?.name ?? account.name)
                } footer: {
                    if account.org?.name != nil {
                        Text(account.name)
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

            // Pre-match to an existing account with the same name when possible.
            if let match = existingAccounts.first(where: {
                !$0.name.isEmpty && $0.name.caseInsensitiveCompare(account.name) == .orderedSame
            }) {
                destinations[account.id] = .existing(match.persistentModelID)
                closingDates[account.id] = match.closingDate ?? 1
                dueDates[account.id] = match.dueDate ?? 1
            } else {
                destinations[account.id] = .createNew
            }
        }
    }

    private func guessType(for account: SimpleFINAccount) -> AccountType {
        if account.balanceValue < 0 { return .credit }
        if account.name.localizedCaseInsensitiveContains("saving") { return .savings }
        return .checking
    }

    private func destinationBinding(for id: String) -> Binding<Destination> {
        Binding(
            get: { destinations[id] ?? .createNew },
            set: { newValue in
                // Only one account can be the primary checking.
                if newValue == .checking {
                    for key in destinations.keys where key != id && destinations[key] == .checking {
                        destinations[key] = .skip
                    }
                }
                destinations[id] = newValue

                // Show a linked existing card's real statement dates so we don't
                // later clobber them with the default 1st.
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
        Binding(
            get: { newTypes[id] ?? .checking },
            set: { newTypes[id] = $0 }
        )
    }

    private func closingBinding(for id: String) -> Binding<Int> {
        Binding(get: { closingDates[id] ?? 1 }, set: { closingDates[id] = $0 })
    }

    private func dueBinding(for id: String) -> Binding<Int> {
        Binding(get: { dueDates[id] ?? 1 }, set: { dueDates[id] = $0 })
    }

    /// Whether the chosen destination for `id` resolves to a credit card — a new
    /// card typed as credit, or an existing credit account.
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
                SimpleFINConfig.checkingID = account.id
                SimpleFINImporter.seedOpeningBalance(for: account, type: .checking,
                                                     account: nil, into: modelContext)

            case .existing(let pid):
                guard let target = existingAccounts.first(where: { $0.persistentModelID == pid }) else { continue }
                target.externalID = account.id
                if target.accountType == .credit {
                    target.closingDate = closingDates[account.id] ?? target.closingDate ?? 1
                    target.dueDate = dueDates[account.id] ?? target.dueDate ?? 1
                }
                SimpleFINImporter.seedOpeningBalance(for: account, type: target.accountType,
                                                     account: target, into: modelContext)

            case .createNew:
                let type = newTypes[account.id] ?? .checking
                let created = Account(name: account.name, accountType: type,
                                      closingDate: closingDates[account.id] ?? 1,
                                      dueDate: dueDates[account.id] ?? 1,
                                      externalID: account.id)
                modelContext.insert(created)
                SimpleFINImporter.seedOpeningBalance(for: account, type: type,
                                                     account: created, into: modelContext)

            case .skip:
                SimpleFINConfig.markSkipped(account.id)
                continue
            }

            // Future syncs import this account's transactions posted after the
            // most recent one visible now — so purchases pending at setup, which
            // aren't in the seeded balance, still import once they post.
            SimpleFINConfig.setCutoff(SimpleFINImporter.importCutoff(for: account),
                                      for: account.id)
        }

        // Marks setup as done and acts as the fallback cutoff. Only stamped on the
        // first connection — later runs (mapping newly-added cards) keep the
        // original date so already-mapped accounts' cutoffs aren't disturbed.
        if SimpleFINConfig.connectedDate == nil {
            SimpleFINConfig.connectedDate = .now
        }
        try? modelContext.save()
        onDone()
    }
}
