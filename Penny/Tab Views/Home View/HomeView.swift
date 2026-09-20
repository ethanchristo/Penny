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

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.modelContext) var modelContext
    @Environment(OverallBudget.self) private var overallBudget

    @Namespace private var namespace

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @Query private var budgets: [Budget]
    @Query private var housings: [Housing]

    /// The windowed + sorted transactions shown in the list, cached so the window
    /// filter and sort only run when their inputs change — not on every body pass.
    @State private var windowedTransactions: [Transaction] = []
    /// The summary card's sections, cached for the same reason (see `Summary`) and
    /// refreshed from `summaryTaskID` below.
    @State private var summary = Summary()
    @State private var editingTransaction: Transaction?

    @State private var searchText = ""
    @State private var filterAccount: Account? = nil
    @State private var filterCategory: Category? = nil
    @State private var filterIsIncome: Bool? = nil

    @State private var sortOrder: CustomSortOrder = .dateReverse
    
    @State private var settingsSheet = false
    @State private var showAddTransaction = false
    
    let stats: HomeStats
    let horizontalSizeClass: UserInterfaceSizeClass
    let backgroundColor: Color

    private enum CustomSortOrder {
        case dateReverse, dateForward, aToZ, zToA
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
        NavigationStack {
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

                BudgetSummaryView(
                    summary: summary,
                    transactions: transactions,
                    selectedTimeRange: selectedTimeRange
                )
                .padding(.top, 16)
                .padding(.horizontal, 24)
                
                if horizontalSizeClass == .compact {
                    SquigglyLine(wavelength: 16, amplitude: 2)
                        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(height: 12) // Height should accommodate the amplitude
                        .padding(.horizontal)
                        .padding(.top, 16)
                    
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // DIAGNOSTIC
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .navigationTitle("Overview")
            .toolbarTitleDisplayMode(UIDevice.current.userInterfaceIdiom == .phone ? .inlineLarge : .large)
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

                if horizontalSizeClass == .compact {
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
            .background {
                LinearGradient(
                    colors: [backgroundColor.opacity(0.7), .clear, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
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
        // Rebuild the summary card's sections only when their inputs change. Kept
        // separate from `statsTaskID` because the summary IS range-dependent while the
        // net total isn't, and it's synchronous main-actor work (its rows hold live
        // models the card navigates to), so `onChange` rather than `task`.
        .onChange(of: summaryTaskID, initial: true) {
            summary.refresh(categories: categories,
                            budgets: budgets,
                            transactions: transactions,
                            selectedTimeRange: selectedTimeRange,
                            overallBudget: overallBudget)
        }
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
                SingleTransactionView(initialEditMode: true, transaction: nil , category: nil, budget: nil)
            }
            .navigationTransition(.zoom(sourceID: "addTransaction", in: namespace))

        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, budget: nil)
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
        hasher.combine(budgetsFingerprint(budgets))
        hasher.combine(housingsFingerprint(housings))
        return hasher.finalize()
    }

    /// Dependency key for the summary card's recompute. Unlike the net total the
    /// summary is windowed, so the selected range is part of it — as is the overall
    /// budget's window, which decides what counts as spent against it. The overall
    /// budget's *amount* is deliberately absent: the card reads it live, and changing
    /// a limit doesn't change what was already spent.
    private var summaryTaskID: Int {
        var hasher = Hasher()
        hasher.combine(selectedTimeRange)
        hasher.combine(overallBudget.budgetWindow)
        hasher.combine(transactionsFingerprint(transactions))
        hasher.combine(budgetsFingerprint(budgets))
        hasher.combine(categoriesFingerprint(categories))
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
        guard let accessURL = SimpleFINStore.loadAccessURL() else { return }

        // A credential without local bookkeeping means iCloud Keychain brought
        // the connection over from another device; rebuild it from the synced
        // data so syncing resumes without a trip through Settings.
        guard SimpleFINConfig.isConfigured
                || SimpleFINConfig.adoptSyncedConnection(in: modelContext)
        else { return }

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

/// A compact glass card under the net total summarizing where the money is going: a
/// highlighted overall-budget section (only when the overall budget is enabled), the
/// budgets the user has overspent, the expenses coming due next, the biggest spending
/// categories, and the recurring budgets still under their limit.
///
/// Presentation only — the sections come pre-computed in `Summary`, which HomeView
/// owns and refreshes when the underlying data changes. Every row is a control rather
/// than a label: budgets open their insights page, upcoming expenses open the
/// transaction, and categories open their spending detail.
struct BudgetSummaryView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(OverallBudget.self) private var overallBudget

    @Namespace private var namespace

    @State private var navRoute: SummaryRoute?
    /// Same destinations as `navRoute`, but presented full-screen — used in the
    /// regular-width side-by-side layout (see `open`).
    @State private var coverRoute: SummaryRoute?
    @State private var editingTransaction: Transaction?

    @State private var haptics: Int = 0

    /// The already-computed sections. Owned and refreshed by `HomeView`; this view
    /// only renders them (see `Summary` for why they aren't computed here).
    let summary: Summary
    /// The full transaction set, used to scope the destinations a row opens.
    let transactions: [Transaction]
    /// The home tab's selected range — the window `summary` was built for, shown as
    /// the subtitle on a category's spending detail.
    let selectedTimeRange: HomeTimeRange

    /// Everywhere a summary row can go. `Identifiable` as well as `Hashable` so the
    /// same value can drive both the pushed destination and the full-screen cover.
    private enum SummaryRoute: Hashable, Identifiable {
        case overall
        case budget(SummaryTarget)
        case categorySpending(Category)
        case allBudgets
        case allCategories
        case allTransactions

        var id: Self { self }
    }

    // MARK: - Overall budget

    private var overallLimit: Double { overallBudget.budget }
    private var overallRemaining: Double { overallLimit - summary.overallSpent }

    // MARK: - Navigation

    /// Routes to `route` — pushed within HomeView's own stack when compact (it already
    /// fills the screen), or presented full-screen when regular-width (side-by-side
    /// layout), so it covers both panes instead of just the left one. Matches how the
    /// net-total buttons above this card navigate.
    private func open(_ route: SummaryRoute) {
        haptics += 1
        if horizontalSizeClass == .regular {
            coverRoute = route
        } else {
            navRoute = route
        }
    }

    @ViewBuilder
    private func destination(for route: SummaryRoute) -> some View {
        switch route {
        case .overall:
            BudgetInsightsView(namespace: namespace,
                               source: .overall(overallBudget, filter: transactions))
        case .budget(.categoryBudget(let category)):
            BudgetInsightsView(namespace: namespace,
                               source: .category(category, filter: categoriedTransactions(for: transactions, with: category)))
        case .budget(.freestandingBudget(let budget)):
            FreestandingBudgetInsightsView(budget: budget, namespace: namespace)
        case .categorySpending(let category):
            CategorySpendingView(category: category,
                                 transactions: categoriedTransactions(for: transactions, with: category),
                                 selectedTimeRange: selectedTimeRange)
        case .allBudgets:
            BudgetView()
        case .allCategories:
            CategoryInsightsView()
        case .allTransactions:
            TransactionView()
        }
    }

    var body: some View {
        let overspent = summary.overspent
        let underspent = summary.underspent
        let upcoming = summary.upcoming
        let topCategories = summary.topSpending

        let showOverall = overallBudget.isEnabled
        let showContent = showOverall || !summary.isEmpty

        if showContent {
            VStack(alignment: .leading, spacing: 16) {
                Label("Summary", systemImage: "text.line.3.summary")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if showOverall {
                    overallSection
                }

                if !overspent.isEmpty {
                    divider(showOverall)
                    budgetList(title: "Overspent", items: overspent, over: true)
                }

                if !upcoming.isEmpty {
                    divider(showOverall || !overspent.isEmpty)
                    upcomingSection(upcoming)
                }

                if !topCategories.isEmpty {
                    divider(showOverall || !overspent.isEmpty || !upcoming.isEmpty)
                    topSpendingSection(topCategories)
                }

                if !underspent.isEmpty {
                    divider(showOverall || !overspent.isEmpty || !upcoming.isEmpty || !topCategories.isEmpty)
                    budgetList(title: "Underspent", items: underspent, over: false, showsSpending: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
            .sensoryFeedback(.impact(weight: .light), trigger: haptics)
            .navigationDestination(item: $navRoute) { route in
                destination(for: route)
            }
            .fullScreenCover(item: $coverRoute) { route in
                NavigationStack {
                    destination(for: route)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    coverRoute = nil
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                            }
                        }
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                NavigationStack {
                    SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, budget: nil)
                }
                .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
            }
        }
    }

    /// The separator between two sections, drawn only when something came before.
    @ViewBuilder
    private func divider(_ hasPrecedingSection: Bool) -> some View {
        if hasPrecedingSection { Divider().opacity(0.4) }
    }

    /// The overall-budget block, shaped like an underspent row — glyph, name, and a
    /// spent-of-limit caption, with what's left on the right — but sized up and sat on
    /// a tinted background, since it's the card's headline figure. Opens the overall
    /// budget's insights page.
    private var overallSection: some View {
        return Button {
            open(.overall)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.pie")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Overall Budget")
                        .font(.headline)
                    Text("\(summary.overallSpent.formatted(.currency(code: currencyCode))) spent of \(overallLimit.formatted(.currency(code: currencyCode))) \(budgetWindowText(from: overallBudget.budgetWindow))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    // Always a magnitude — the label below says which side of the
                    // budget it falls on.
                    Text(abs(overallRemaining), format: .currency(code: currencyCode))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(overallRemaining < 0 ? "over" : "under")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .underline()
                }
            }
//            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
//            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "overallInsights", in: namespace)
    }

    /// A titled list of budget rows with a subtotal, each row opening that budget.
    /// `over` shows amounts as negative (overspend); otherwise they're the positive
    /// remaining. `showsSpending` adds the spent-of-limit line under each name, the
    /// way the upcoming rows carry their due date.
    @ViewBuilder
    private func budgetList(title: String, items: [SummaryBudgetStat], over: Bool, showsSpending: Bool = false) -> some View {
        let subtotal = items.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title, subtotal: subtotal, route: .allBudgets)

            ForEach(items) { item in
                Button {
                    open(.budget(item.target))
                } label: {
                    HStack(spacing: 8) {
                        Text(item.symbol)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .lineLimit(1)
                            if showsSpending {
                                Text("\(item.spent.formatted(.currency(code: currencyCode))) spent of \(item.limit.formatted(.currency(code: currencyCode)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(over ? -item.amount : item.amount, format: .currency(code: currencyCode))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: item.target.transitionID, in: namespace)
            }
        }
    }

    /// What's due next, each row opening that transaction. Recurring transactions show
    /// the date of their next occurrence; one-time ones their own (future) date.
    @ViewBuilder
    private func upcomingSection(_ items: [SummaryUpcomingExpense]) -> some View {
        let subtotal = items.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Upcoming", subtotal: subtotal, route: .allTransactions)

            ForEach(items) { item in
                Button {
                    editingTransaction = item.transaction
                } label: {
                    HStack(spacing: 8) {
                        Text(item.symbol)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .lineLimit(1)
                            Text(item.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.amount, format: .currency(code: currencyCode))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: item.id, in: namespace)
            }
        }
    }

    /// Where the money actually went this window: the biggest spending categories that
    /// aren't already flagged as overspent, each opening its own spending detail.
    @ViewBuilder
    private func topSpendingSection(_ slices: [CategorySlice]) -> some View {
        let subtotal = slices.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Top Spending", subtotal: subtotal, route: .allCategories)

            ForEach(slices) { slice in
                Button {
                    open(.categorySpending(slice.category))
                } label: {
                    HStack(spacing: 8) {
                        Text(slice.symbol)
                        Text(slice.name)
                            .lineLimit(1)
                        Spacer()
                        Text(slice.amount, format: .currency(code: currencyCode))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A section's title and subtotal, tappable as a whole to reach the full view the
    /// section is a preview of.
    private func sectionHeader(_ title: String, subtotal: Double, route: SummaryRoute) -> some View {
        Button {
            open(route)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(subtotal, format: .currency(code: currencyCode))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

}

/// Where a top-spending category goes when tapped: what it cost over the home tab's
/// window, above the transactions that make up the total. Unlike `BudgetInsightsView`
/// this doesn't assume the category has a budget — most top spenders don't.
struct CategorySpendingView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Namespace private var namespace

    @State private var editingTransaction: Transaction?

    let category: Category
    /// The category's transactions, unwindowed — the window is applied here so the
    /// header total and the list below always agree on it.
    let transactions: [Transaction]
    let selectedTimeRange: HomeTimeRange

    private var window: (start: Date, end: Date) {
        windowBounds(for: selectedTimeRange, offset: 0)
    }

    /// Windowed spend for the category, computed the same way the home card's
    /// Top Spending row is (`categorySpendData`), so the two never disagree.
    private var spent: Double {
        let expenses = typedTransactions(for: transactions, income: false)
        return abs(calculateTotal(for: expenses, start: window.start, end: window.end))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                Text(category.symbol)
                    .font(.system(size: 44))

                Text(spent, format: .currency(code: currencyCode))
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                    .foregroundStyle(category.color)

                Text("Spent · \(selectedTimeRange.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            SquigglyLine(wavelength: 16, amplitude: 2)
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(height: 12)
                .padding(.horizontal)
                .padding(.top, 8)

            TransactionFilteredView(
                editingTransaction: $editingTransaction,
                transactions: transactionsInRange(start: window.start, end: window.end, transactions: transactions),
                namespace: namespace,
                hideRecent: true,
                hideRecurrence: false,
                hideUpcoming: true,
                hideAllTx: false,
                searchString: ""
            )
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background {
            LinearGradient(
                colors: [category.color.opacity(0.2), .clear, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("\(category.symbol) \(category.name)")
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                SingleTransactionView(initialEditMode: false, transaction: transaction, category: nil, budget: nil)
            }
            .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
        }
    }
}
