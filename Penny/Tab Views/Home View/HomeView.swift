//
//  HomeView.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import SwiftData
import SwiftUI
import WidgetKit

struct HomeView: View {
    @AppStorage("googleScriptUrl") private var scriptUrl: String = ""
    @AppStorage("googleScriptSecret") private var scriptSecret: String = ""
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly
    @AppStorage("net_total_include_upcoming", store: .group) private var includeUpcoming: Bool = true
    // Recompute the net total when the credit-card mode changes.
    @AppStorage("net_total_credit_mode", store: .group) private var creditMode: CreditCardBalanceType = .balance
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("user_yellow_threshhold", store: .group) private var yellowThreshold: Double = 100.0
    @AppStorage("show_insights") private var showInsights: Bool = true

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.modelContext) var modelContext
    
    @Namespace private var namespace

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @Query private var funds: [Fund]

    @State private var stats = HomeStats()
    /// The windowed + sorted transactions shown in the list, cached so the window
    /// filter and sort only run when their inputs change — not on every body pass.
    @State private var windowedTransactions: [Transaction] = []
    @State private var editingTransaction: Transaction?

    @State private var searchText = ""
    @State private var filterAccount: Account? = nil
    @State private var filterCategory: Category? = nil
    @State private var filterIsIncome: Bool? = nil

    @State private var sortOrder: CustomSortOrder = .dateReverse
    
    @State private var settingsSheet = false
    @State private var showAddTransaction = false

    /// Value-based navigation path for pushes from the Home screen.
    @State private var path = NavigationPath()

    @State private var haptics: Int = 0

    private enum CustomSortOrder {
        case dateReverse, dateForward, aToZ, zToA
    }

    /// Destinations reachable from the Home screen, driven through `path`.
    private enum HomeRoute: Hashable {
        case budgets
        case funds
    }

    private var backgroundColor: Color {
        if stats.netTotal > yellowThreshold {
            Color(.systemGreen)
        } else if stats.netTotal <= 0 {
            Color(.systemRed)
        } else if stats.netTotal > 0 && stats.netTotal <= yellowThreshold {
            Color(.systemYellow)
        } else {
            Color(.systemRed)
        }
    }

    private func computeWindowedTransactions() -> [Transaction] {
        let windowed: [Transaction]
        
        switch selectedTimeRange {
        case .daily:
            windowed = transactionsInRange(window: .daily, shiftAmount: 0, transactions: transactions)
        case .weekly:
            windowed = transactionsInRange(window: .weekly, shiftAmount: 0, transactions: transactions)
        case .payPeriod:
            let bounds = payPeriodBounds(offset: 0)
            windowed = transactionsInRange(start: bounds.start, end: bounds.end, transactions: transactions)
        case .monthly:
            windowed = transactionsInRange(window: .monthly, shiftAmount: 0, transactions: transactions)
        case .yearly:
            windowed = transactionsInRange(window: .yearly, shiftAmount: 0, transactions: transactions)
        case .allTime:
            // A nil window spans everything up to now.
            windowed = transactionsInRange(window: nil, shiftAmount: 0, transactions: transactions)
        }

        // `windowed` is in @Query's date order (newest first) since `transactionsInRange`
        // sorts that way too; only reorder when the user picked a non-default sort.
        switch sortOrder {
        case .dateReverse:
            return windowed
        case .dateForward:
            return windowed.reversed()
        case .aToZ, .zToA:
            return windowed.sorted { t1, t2 in
                let name1 = !t1.notes.isEmpty ? t1.notes : (t1.category?.name ?? "Miscellaneous")
                let name2 = !t2.notes.isEmpty ? t2.notes : (t2.category?.name ?? "Miscellaneous")
                return sortOrder == .aToZ ? name1 < name2 : name1 > name2
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                NetTotalView(
                    selectedTimeRange: $selectedTimeRange,
                    modelContext: modelContext,
                    scenePhase: scenePhase,
                    scriptUrl: scriptUrl,
                    scriptSecret: scriptSecret,
                    currencyCode: currencyCode,
                    currencySymbol: currencySymbol,
                    transactions: transactions,
                    netIncome: stats.netIncome,
                    netExpenses: stats.netExpenses,
                    netTotal: stats.netTotal,
                    backgroundColor: backgroundColor
                )
                .padding(.top)
                .padding(.horizontal, 24)
                
                HStack {
                    Button {
                        haptics += 1
                        path.append(HomeRoute.budgets)
                    } label: {
                        HStack {
                            Label("Budgets", systemImage: "chart.bar.fill")
                                .lineLimit(1)

                            Spacer()


                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        .tint(.primary)
                        .padding(24)
                        .frame(height: 72)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
                    }

                    Button {
                        haptics += 1
                        path.append(HomeRoute.funds)
                    } label: {
                        HStack {
                            Label("Funds", systemImage: "rectangle.stack.fill")
                                .lineLimit(1)
                            
                            Spacer()
                            
                            
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        .tint(.primary)
                        .padding(24)
                        .frame(height: 72)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
                    }
                    
                }
                .sensoryFeedback(.impact, trigger: haptics)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .padding(.horizontal, 24)
                
                TransactionFilteredView(
                    editingTransaction: $editingTransaction,
                    transactions: windowedTransactions,
                    namespace: namespace,
                    hideRecent: false,
                    hideRecurrence: true,
                    hideUpcoming: true,
                    hideAllTx: true,
                    searchString: searchText,
                    filterAccount: filterAccount,
                    filterCategory: filterCategory,
                    filterIsIncome: filterIsIncome
                )
                
                if showInsights {
                    SquigglyLine(wavelength: 16, amplitude: 2)
                        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(height: 12) // Height should accommodate the amplitude
                        .padding(.horizontal)
                        .padding(.top, 12)
                    
                    InsightsView()
                }
            }
            .background {
                LinearGradient(
                    colors: [backgroundColor.opacity(0.7), .clear, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .budgets:  BudgetView()
                case .funds:    FundView()
                }
            }
            .navigationTitle("Overview")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsSheet = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
//                    .matchedTransitionSource(id: "settings", in: namespace)
                }

                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddTransaction = true
                    } label: {
                        Label("Add Transaction", systemImage: "plus")
                    }
                    .matchedTransitionSource(id: "addTransaction", in: namespace)
                }
            }
        }
        .task(id: statsTaskID) {
            // Keep the payday-anchored window in sync with the latest Payroll
            // transaction (when tracking is on) before computing, so the pass below
            // uses the fresh anchor. Cheap; stays on the main thread.
            syncPayrollPayPeriodAnchor(from: transactions)
            // The heavy all-time aggregation runs off the main thread on a background
            // ModelActor, then publishes plain numbers back to the UI.
            let totals = await StatsCalculator(modelContainer: SharedDatabase.shared.container).allTimeNetTotals()
            stats.apply(totals)
            // Transactions (or the upcoming toggle / funds) changed — rebuild the list too.
            windowedTransactions = computeWindowedTransactions()
            // The widget computes its net total from the same shared store, but only
            // refreshes on its own timeline. Nudge it whenever the inputs that drive the
            // net total change so it always matches what the app is showing.
            WidgetCenter.shared.reloadAllTimelines()
        }
        // The window filter and sort are cheap to re-run only when the user actually
        // changes the range or sort — no need to touch the all-time stats for these.
        .onChange(of: selectedTimeRange) { windowedTransactions = computeWindowedTransactions() }
        .onChange(of: sortOrder) { windowedTransactions = computeWindowedTransactions() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if !scriptSecret.isEmpty {
                await silentAutoFetch()
            }
            await silentSimpleFINSync()
            await silentFinanceKitSync()
        }
        .sheet(isPresented: $showAddTransaction) {
            NavigationStack {
                SingleTransactionView(initialEditMode: true, transaction: nil , category: nil, fund: nil)
            }
            .navigationTransition(.zoom(sourceID: "addTransaction", in: namespace))

        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, fund: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
        .sheet(isPresented: $settingsSheet) {
            NavigationStack {
                SettingsView()
            }
//            .navigationTransition(.zoom(sourceID: "settings", in: namespace))
        }
    }

    /// Combined dependency key for the stats recompute task. The net total is all-time,
    /// so it depends only on the transactions, the funds, and whether upcoming recurring
    /// transactions are included — not on the selected time range.
    private var statsTaskID: Int {
        var hasher = Hasher()
        hasher.combine(includeUpcoming)
        hasher.combine(creditMode)
        // Refire when a SimpleFIN or FinanceKit sync writes new live balances (they feed the total).
        for (id, balance) in SimpleFINConfig.accountBalances.sorted(by: { $0.key < $1.key }) {
            hasher.combine(id)
            hasher.combine(balance)
        }
        for (id, balance) in FinanceKitConfig.accountBalances.sorted(by: { $0.key < $1.key }) {
            hasher.combine(id)
            hasher.combine(balance)
        }
        hasher.combine(transactionsFingerprint(transactions))
        hasher.combine(fundsFingerprint(funds))
        return hasher.finalize()
    }

    private func silentAutoFetch() async {
        let cleanUrl = scriptUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = scriptSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanUrl.isEmpty || cleanSecret.isEmpty { return }

        let allowedCharacters = CharacterSet.alphanumerics
        guard let encodedSecret = cleanSecret.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else { return }

        let separator = cleanUrl.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(cleanUrl)\(separator)secret=\(encodedSecret)") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let jsonString = String(data: data, encoding: .utf8), jsonString.contains("Unauthorized") { return }

            let rawEmails = try JSONDecoder().decode([RawEmailDTO].self, from: data)

            let importedTransactions = await withTaskGroup(of: TransactionDTO?.self) { group in
                for rawEmail in rawEmails {
                    group.addTask {
                        await extractDataWithAI(from: rawEmail.body, date: rawEmail.date)
                    }
                }
                var results: [TransactionDTO] = []
                for await dto in group {
                    if let dto { results.append(dto) }
                }
                return results
            }

            await silentSaveToDatabase(dtos: importedTransactions)
        } catch {
            // Silent failure on background fetch
        }
    }

    /// Background SimpleFIN sync on foreground: pulls new transactions since the
    /// connection date and imports them (dedup + categorisation handled by
    /// `SimpleFINImporter`). Throttled to at most once every few hours because
    /// the Bridge only refreshes about once a day and heavy polling can disable
    /// the connection. No-ops if SimpleFIN isn't connected.
    private func silentSimpleFINSync() async {
        guard SimpleFINConfig.isConfigured,
              let accessURL = SimpleFINStore.loadAccessURL() else { return }

        let throttle: TimeInterval = 6 * 60 * 60
        if let last = SimpleFINConfig.lastSyncDate,
           Date.now.timeIntervalSince(last) < throttle { return }

        // Fetch back to the earliest per-account cutoff so transactions that
        // were pending at setup and have since posted (possibly with a date
        // before the connection date) are returned — but never reach past the
        // Bridge's 90-day window.
        let earliest = Calendar.current.date(byAdding: .day, value: -89, to: .now)
        let cutoffFloor = SimpleFINConfig.accountCutoffs.values.min()
            ?? SimpleFINConfig.connectedDate
            ?? earliest ?? .now
        let startDate = max(cutoffFloor, earliest ?? .distantPast)

        do {
            let result = try await SimpleFINClient.fetchAccounts(accessURL: accessURL,
                                                                 startDate: startDate)
            await SimpleFINImporter.importNewTransactions(result.accounts, into: modelContext)
            SimpleFINConfig.lastSyncDate = .now
        } catch {
            // Silent failure on background sync — a failed fetch doesn't mean a dead connection.
        }
    }

    /// FinanceKit sync on foreground: pulls new Wallet transactions since each
    /// mapped account's cutoff and imports them (dedup + categorisation handled by
    /// `FinanceKitImporter`). On-device data, so — unlike SimpleFIN — there's no API
    /// limit to throttle against; it runs on every open. No-ops if not connected.
    private func silentFinanceKitSync() async {
        guard FinanceKitConfig.isConfigured else { return }

        let floor = FinanceKitConfig.accountCutoffs.values.min()
            ?? FinanceKitConfig.connectedDate

        do {
            let accounts = try await FinanceKitClient.fetchAccounts(since: floor)
            await FinanceKitImporter.importNewTransactions(accounts,
                                                           into: modelContext,
                                                           categorize: financeKitHybridCategorize)
            FinanceKitConfig.lastSyncDate = .now
        } catch {
            // Silent failure on foreground sync.
        }
    }

    @MainActor
    private func silentSaveToDatabase(dtos: [TransactionDTO]) async {
        let formatter = ISO8601DateFormatter()

        var existingAccounts = [Account]()
        var existingTransactions = [Transaction]()

        do {
            existingAccounts = try modelContext.fetch(FetchDescriptor<Account>())
            existingTransactions = try modelContext.fetch(FetchDescriptor<Transaction>())
        } catch { return }

        guard let miscCategory = categories.first(where: { $0.name == "Miscellaneous" }) else { return }
        let categoryNames = categories.map { $0.name }

        for dto in dtos {
            let actualDate = formatter.date(from: dto.date) ?? Date()

            let isDuplicate = existingTransactions.contains { tx in
                tx.amount == dto.amount &&
                tx.notes == dto.name &&
                Calendar.current.isDate(tx.date, inSameDayAs: actualDate)
            }
            if isDuplicate { continue }

            let transactionText = "\(dto.name) \(dto.account ?? "")".lowercased()
            let transactionCard = existingAccounts.first { account in
                transactionText.contains(account.name.lowercased())
            }

            var finalCategory: Category = miscCategory

            if let ruleMatchedCategory = findCategoryByRule(for: dto, categories: categories) {
                finalCategory = ruleMatchedCategory
            } else if let predictedName = await autoCategorize(text: dto.name, categories: categoryNames) {
                if let matchedCategory = categories.first(where: { $0.name == predictedName }) {
                    finalCategory = matchedCategory
                }
            }

            let newTransaction = Transaction(
                amount: dto.amount,
                date: actualDate,
                account: transactionCard,
                category: finalCategory,
                notes: dto.name
            )

            modelContext.insert(newTransaction)
            existingTransactions.append(newTransaction)
        }

        try? modelContext.save()
    }
}
