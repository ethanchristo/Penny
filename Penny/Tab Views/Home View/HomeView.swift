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

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.modelContext) var modelContext
    
    @Namespace private var namespace

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @Query private var budgets: [Budget]

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

    private enum CustomSortOrder {
        case dateReverse, dateForward, aToZ, zToA
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
                    categories: categories,
                    budgets: budgets,
                    transactions: transactions,
                    netTotal: stats.netTotal
                )
                .padding(.top, 16)
                .padding(.horizontal, 24)

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
            .background {
                LinearGradient(
                    colors: [backgroundColor.opacity(0.7), .clear, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
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

/// A compact glass card under the net total that reconciles budget overspending
/// against the money the user has to spend. The "spendable pool" is the overall
/// budget's remaining amount when the overall budget is on, otherwise the net total —
/// so the summary answers "what's left, and can it cover where I went over?".
struct BudgetSummaryView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    @Environment(\.colorScheme) private var colorScheme
    @Environment(OverallBudget.self) private var overallBudget

    let categories: [Category]
    let budgets: [Budget]
    let transactions: [Transaction]
    let netTotal: Double

    /// One overspent budget (category or freestanding) with the amount it's over by.
    private struct OverspentBudget: Identifiable {
        let id: String
        let symbol: String
        let name: String
        let over: Double
    }

    /// Every budget currently spent past its limit, biggest overage first.
    private var overspentBudgets: [OverspentBudget] {
        var results: [OverspentBudget] = []

        // Category budgets — spend for the current window vs. the category's limit.
        for category in categories {
            guard let budget = category.budget, budget.hasBudget, !budget.isFreestanding else { continue }
            let limit = budget.amount
            guard limit > 0 else { continue }
            let spent = budgetTotal(for: category, in: transactions, by: 0)
            if spent > limit {
                results.append(.init(id: "cat-\(category.id)",
                                     symbol: category.symbol,
                                     name: category.name,
                                     over: spent - limit))
            }
        }

        // Freestanding budgets already track their own remaining balance.
        for budget in budgets where budget.hasBudget && budget.isFreestanding {
            if budget.remaining < 0 {
                results.append(.init(id: "budget-\(budget.id)",
                                     symbol: budget.displaySymbol,
                                     name: budget.displayName,
                                     over: -budget.remaining))
            }
        }

        return results.sorted { $0.over > $1.over }
    }

    private var totalOverspent: Double {
        overspentBudgets.reduce(0) { $0 + $1.over }
    }

    /// Whether the reconciliation uses the overall budget (on) or the net total (off).
    private var usingOverall: Bool { overallBudget.isEnabled }

    /// The money available to spend: overall budget remaining, or the net total.
    private var availableAmount: Double {
        usingOverall
            ? overallBudget.budget - overallBudgetTotal(for: overallBudget, in: transactions, by: 0)
            : netTotal
    }

    private var availableSubtitle: String {
        if usingOverall {
            let window = budgetWindowText(from: overallBudget.budgetWindow)
            return availableAmount >= 0
                ? "left in your overall budget \(window)"
                : "over your overall budget \(window)"
        } else {
            return availableAmount >= 0
                ? "net total available to spend"
                : "your net total is in the red"
        }
    }

    /// Reconciles the overspend against the spendable pool: how much you'd have left
    /// after covering it, or how far short you'd fall.
    private var reconciliationText: String {
        let count = overspentBudgets.count
        let noun = count == 1 ? "budget" : "budgets"
        let source = usingOverall ? "budget" : "net total"
        let overStr = totalOverspent.formatted(.currency(code: currencyCode))

        let head = "You've overspent \(overStr) across \(count) \(noun)."
        let after = availableAmount - totalOverspent
        if after >= 0 {
            return head + " Covering it from your \(source) leaves \(after.formatted(.currency(code: currencyCode)))."
        } else {
            return head + " That's \(abs(after).formatted(.currency(code: currencyCode))) more than your \(source)."
        }
    }

    private var amountColor: Color {
        let base: Color = availableAmount < 0 ? Color(.systemRed) : Color(.systemGreen)
        return colorScheme == .dark ? base.mix(with: .white, by: 0.4) : base.mix(with: .black, by: 0.3)
    }

    /// What's genuinely free to use: the spendable pool minus anything needed to cover
    /// overspending. Drives the "ideas" nudge so it only shows when there's real money left.
    private var spendableLeftover: Double {
        availableAmount - totalOverspent
    }

    /// Friendly ways to put a positive leftover to work. Purely suggestive — tapping
    /// one just closes the nudge, so it never records a transaction on its own.
    private struct SpendIdea: Identifiable {
        var id: String { title }
        let title: String
        let systemImage: String
    }

    private let spendIdeas: [SpendIdea] = [
        .init(title: "Save it", systemImage: "building.columns.fill"),
        .init(title: "Invest it", systemImage: "chart.line.uptrend.xyaxis"),
        .init(title: "Treat yourself", systemImage: "gift.fill"),
        .init(title: "Share with friends", systemImage: "person.2.fill")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Summary", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(availableAmount, format: .currency(code: currencyCode))
                    .font(.title.bold())
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                    .contentTransition(.numericText())

                Text(availableSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if overspentBudgets.isEmpty {
                Label("All budgets are on track", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            } else {
                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Overspent")
                        .font(.subheadline.weight(.semibold))

                    ForEach(overspentBudgets) { item in
                        HStack(spacing: 8) {
                            Text(item.symbol)
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            Text(item.over, format: .currency(code: currencyCode))
                                .monospacedDigit()
                                .foregroundStyle(.red)
                        }
                        .font(.subheadline)
                    }

                    Text(reconciliationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if spendableLeftover > 0 {
                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ideas to make it count")
                        .font(.subheadline.weight(.semibold))

                    Text("You've got \(spendableLeftover.formatted(.currency(code: currencyCode))) free — put it to work.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(spendIdeas) { idea in
                                Label(idea.title, systemImage: idea.systemImage)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
    }
}
