//
//  TransactionFilteredView.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import SwiftData
import SwiftUI

struct TransactionFilteredView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("show_recurring_section") private var showRecurringSection = true
    @AppStorage("hide_recurrence_ended") private var hideRecurrenceEnded = false
    @AppStorage("show_upcoming_section") private var showUpcomingSection = true
    
    @Environment(\.modelContext) var modelContext
    
    @Binding var editingTransaction: Transaction?
    
    @State private var showBudgetSection = false
    @State private var pendingDeletion: Transaction? = nil
    
    @State private var haptics: Int = 0
    
    let transactions: [Transaction]
    let namespace: Namespace.ID

    let hideRecent: Bool
    let hideRecurrence: Bool
    let hideUpcoming: Bool
    let hideAllTx: Bool
    
    var disableDateGrouping: Bool = false
    var grouping: TransactionGrouping = .day
    /// When true, groups and the transactions within them run oldest-first; otherwise newest-first.
    var dateAscending: Bool = false

    var searchString: String
    var filterAccount: Account?
    var filterCategory: Category?
    var filterBudget: Budget?
    var filterIsIncome: Bool?
        
    /// The fully-derived sections for one render. Built once per body pass by
    /// `makeSections()` so the filter, the section splits, and the (expensive)
    /// `nextOccurrence` sorts each run a single time instead of once per access.
    private struct DisplaySections {
        var recent: [Transaction] = []
        var recurring: [Transaction] = []
        var upcoming: [Transaction] = []
        var notRecurring: [Transaction] = []
        var grouped: [(key: Date, value: [Transaction])] = []
        var funded: [Transaction] = []
    }

    /// Applies the search + dropdown filters once, then derives every section from
    /// that single filtered list. `nextOccurrence` — a while-loop recurrence
    /// expansion — is computed exactly once per transaction and reused for sorting,
    /// rather than being recomputed inside an O(n log n) sort comparator.
    private func makeSections() -> DisplaySections {
        let now = Date.now
        // Safely calculate exactly 48 hours ago using Calendar
        let fortyEightHoursAgo = Calendar.current.date(byAdding: .hour, value: -48, to: now)?.startOfDay ?? now.addingTimeInterval(-172800)

        // 1. Search + dropdown filters, applied a single time.
        let filtered = transactions.filter { t in
            let matchesSearch = searchString.isEmpty ||
                                (t.account?.name.localizedStandardContains(searchString) == true) ||
                                (t.category?.name.localizedStandardContains(searchString) == true) ||
                                (t.budget?.name.localizedStandardContains(searchString) == true) ||
                                t.notes.localizedStandardContains(searchString)

            let matchesAccount = filterAccount == nil || t.account == filterAccount
            let matchesCategory = filterCategory == nil || t.category == filterCategory
            let matchedBudget = filterBudget == nil || t.budget == filterBudget
            let matchesIncome = filterIsIncome == nil || t.isIncome == filterIsIncome!

            return matchesSearch && matchesAccount && matchesCategory && matchedBudget && matchesIncome
        }

        // Sorts by next occurrence, expanding each transaction's recurrence just once.
        func sortedByNextOccurrence(_ txs: [Transaction]) -> [Transaction] {
            txs.map { (tx: $0, next: $0.nextOccurrence) }
                .sorted { lhs, rhs in
                    switch (lhs.next, rhs.next) {
                    case let (l?, r?): return l < r
                    case (nil, _?):    return false
                    case (_?, nil):    return true
                    case (nil, nil):   return false
                    }
                }
                .map(\.tx)
        }

        func notEnded(_ transaction: Transaction) -> Bool {
            if !hideRecurrenceEnded { return true }
            guard let endDate = transaction.endDate else { return true }
            return endDate >= now
        }

        // 2. Split the filtered list into its sections.
        var sections = DisplaySections()
        sections.recurring = sortedByNextOccurrence(filtered.filter { $0.recurrence != .none && notEnded($0) })
        sections.upcoming = sortedByNextOccurrence(filtered.filter { ($0.date > now || $0.recurrence != .none) && notEnded($0) })
        sections.funded = filtered.filter { $0.budget != nil }

        // Isolate all past, non-recurring transactions
        let pastNonRecurring = filtered.filter { $0.recurrence == .none && $0.date <= now }
        
        // Partition them into Recent (last 48 hours) and everything else
        sections.recent = pastNonRecurring.filter { $0.date >= fortyEightHoursAgo }
            // Ensure the recent array respects your global ascending/descending toggle
            .sorted { dateAscending ? $0.date < $1.date : $0.date > $1.date }
        
        // Leave the older transactions for the grouped/flat lists
        sections.notRecurring = pastNonRecurring.filter { $0.date < fortyEightHoursAgo }

        // 3. Group the older non-recurring transactions by the selected window, sorting
        //    within each group and the groups themselves by the active direction.
        let groupedDict = Dictionary(grouping: sections.notRecurring) { groupingKey(for: $0.date) }
        sections.grouped = groupedDict
            .map { (key: $0.key, value: $0.value.sorted { dateAscending ? $0.date < $1.date : $0.date > $1.date }) }
            .sorted { dateAscending ? $0.key < $1.key : $0.key > $1.key }

        return sections
    }

    /// The representative start date for a transaction's group, based on the selected `grouping`.
    private func groupingKey(for date: Date) -> Date {
        let calendar = Calendar.current
        switch grouping {
        case .none, .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    /// The header label for a group, formatted to match the selected `grouping`.
    private func headerTitle(for key: Date) -> String {
        let calendar = Calendar.current
        switch grouping {
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: key) else {
                return key.formatted(date: .abbreviated, time: .omitted)
            }
            let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(key.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
        case .month:
            return key.formatted(.dateTime.month(.wide).year())
        case .none, .day:
            return key.formatted(date: .abbreviated, time: .omitted)
        }
    }
    
    var body: some View {
        let sections = makeSections()
        // Any section that can actually render. `recent` and `upcoming` must be here:
        // callers like the Home tab show ONLY the Recent section, so gating on just
        // recurring/notRecurring would blank the list (no rows AND no empty state)
        // whenever the window holds only transactions from the last 48 hours.
        let hasContent = !sections.recurring.isEmpty
            || !sections.notRecurring.isEmpty
            || !sections.recent.isEmpty
            || !sections.upcoming.isEmpty

        Group {
            if !hasContent {
                VStack(spacing: 5) {
                    Image(systemName: "xmark.seal")
                        .font(.system(size: 100))
                        .foregroundStyle(.tertiary)
                    
                    Text("No transactions found")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 120)
            }
            
            if hasContent {
                LazyVStack(spacing: 15) {
                    if !hideRecent {
                        recentSection(from: sections)
                    }
                    
                    if !hideRecurrence {
                        recurringSection(from: sections)
                    }
                    
                    if !hideUpcoming {
                        upcomingSection(from: sections)
                    }
                    
                    if !hideAllTx {
                        mainTxSection(from: sections)
                    }
                }
                .animation(.snappy, value: showRecurringSection)
                .animation(.snappy, value: showUpcomingSection)
            }

            if showBudgetSection {
                ForEach(sections.funded) { transaction in
                    Button {
                        editingTransaction = transaction
                    } label: {
                        TransactionRowView(transaction: transaction, disableGrouping: disableDateGrouping, currency: currencyCode, upcoming: false, grouping: grouping)
                    }
                    .matchedTransitionSource(id: transaction.id, in: namespace)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = transaction
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .safeAreaPadding(.bottom)
        .sensoryFeedback(.impact(weight: .light), trigger: haptics)
        .sensoryFeedback(.impact(weight: .light), trigger: showBudgetSection)
        .sensoryFeedback(.impact(weight: .light), trigger: showUpcomingSection)
        .sensoryFeedback(.impact(weight: .light), trigger: showRecurringSection)
        .alert(
            "Delete Transaction?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in if !isPresented { pendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let transaction = pendingDeletion {
                    deleteTransaction(transaction)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }
    
    @ViewBuilder
    private func recentSection(from sections: DisplaySections) -> some View {
        if !sections.recent.isEmpty {
            HStack {
                Text("Recent Transactions")
                
                Spacer()
                
                NavigationLink("View All") { TransactionView() }
                    .tint(.secondary)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 20)
            
            ForEach(sections.recent) { transaction in
                Button {
                    haptics += 1
                    editingTransaction = transaction
                } label: {
                    TransactionRowView(transaction: transaction, disableGrouping: disableDateGrouping, currency: currencyCode, upcoming: false, grouping: grouping)
                }
                .matchedTransitionSource(id: transaction.id, in: namespace)
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDeletion = transaction
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .transition(.blurReplace)
            }
            .padding(.horizontal)
        } else {
            NavigationLink {
                TransactionView()
            } label: {
                Label("All Transactions", systemImage: "receipt.fill")
                    .font(.headline)
                    .lineLimit(1)
                    .tint(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .frame(height: 72)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
            }
            .padding(.horizontal, 24)
        }
    }
    
    @ViewBuilder
    private func recurringSection(from sections: DisplaySections) -> some View {
        if !sections.recurring.isEmpty {
            HStack {
                Text("Recurring")
                
                Menu {
                    Button {
                        hideRecurrenceEnded.toggle()
                    } label: {
                        Text(hideRecurrenceEnded ? "Show Ended" : "Hide Ended")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(.secondary)
                
                Spacer()
                
                Text("(\(sections.recurring.count))")
                    .foregroundStyle(Color.secondary)
                
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showRecurringSection ? 180 : 0))
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .onTapGesture { showRecurringSection.toggle() }
            
            if showRecurringSection {
                ForEach(sections.recurring) { transaction in
                    Button {
                        haptics += 1
                        editingTransaction = transaction
                    } label: {
                        TransactionRowView(transaction: transaction, disableGrouping: disableDateGrouping, currency: currencyCode, upcoming: false, grouping: grouping)
                    }
                    .matchedTransitionSource(id: transaction.id, in: namespace)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = transaction
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .transition(.blurReplace)
                }
                .padding(.horizontal)
            }
        }
    }
    
    @ViewBuilder
    private func upcomingSection(from sections: DisplaySections) -> some View {
        if !sections.upcoming.isEmpty {
            HStack {
                Text("Upcoming")
                
                Spacer()
                
                Text("(\(sections.upcoming.count))")
                    .foregroundStyle(Color.secondary)
                
//                Image(systemName: "chevron.up")
//                    .foregroundStyle(.secondary)
//                    .rotationEffect(.degrees(showUpcomingSection ? 180 : 0))
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .onTapGesture { showUpcomingSection.toggle() }
            
            ForEach(sections.upcoming) { transaction in
                Button {
                    haptics += 1
                    editingTransaction = transaction
                } label : {
                    TransactionRowView(transaction: transaction, disableGrouping: disableDateGrouping, currency: currencyCode, upcoming: true, grouping: grouping)
                }
                .matchedTransitionSource(id: transaction.id, in: namespace)
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDeletion = transaction
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    @ViewBuilder
    private func mainTxSection(from sections: DisplaySections) -> some View {
        if disableDateGrouping {
            // THE FLAT LIST (Respects Global Sorting by Amount, A-Z, etc.)
            if !sections.notRecurring.isEmpty {
                if (!hideUpcoming && !sections.upcoming.isEmpty) && (!hideRecurrence && !sections.recurring.isEmpty) {
                    Text("Transactions")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.top, 20)
                }
                
                ForEach(sections.notRecurring) { transaction in
                    Button {
                        haptics += 1
                        editingTransaction = transaction
                    } label : {
                        TransactionRowView(transaction: transaction, disableGrouping: disableDateGrouping, currency: currencyCode, upcoming: false, grouping: grouping)
                    }
                    .matchedTransitionSource(id: transaction.id, in: namespace)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = transaction
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .padding(.horizontal)
                }
            }
        } else {
            if !sections.grouped.isEmpty {
                if !sections.upcoming.isEmpty || !sections.recurring.isEmpty {
                    Text("Transactions")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.top, 20)
                }
                
                ForEach(sections.grouped, id: \.key) { dateGroup in
                    Section {
                        ForEach(dateGroup.value) { transaction in
                            Button {
                                haptics += 1
                                editingTransaction = transaction
                            } label : {
                                TransactionRowView(transaction: transaction, disableGrouping: disableDateGrouping, currency: currencyCode, upcoming: false, grouping: grouping)
                            }
                            .matchedTransitionSource(id: transaction.id, in: namespace)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDeletion = transaction
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .padding(.horizontal)
                        }
                    } header: {
                        let netTotal = dateGroup.value.reduce(0) { $0 + ($1.isIncome ? $1.amount : -$1.amount) }
                        
                        HStack {
                            Text(headerTitle(for: dateGroup.key))
                            
                            Spacer()
                            
                            Text(amountTruncation(for: netTotal, currencySymbol: currencySymbol))
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.top, 10)
                    }
                }
            }
        }
    }
    
    private func deleteTransaction(_ transaction: Transaction) {
        // Tombstone bank-imported transactions so a re-sync won't bring them back.
        if let externalID = transaction.externalID {
            SimpleFINConfig.dismissExternalID(externalID)
        }
        modelContext.delete(transaction)
    }
}

struct TransactionRowView: View {
    @AppStorage("default_checking_name") private var defaultCheckingName: String = "Checking"

    let transaction: Transaction
    let disableGrouping: Bool
    let currency: String
    let upcoming: Bool
    let grouping: TransactionGrouping
    
    private var name: String {
        if !transaction.notes.isEmpty {
            transaction.notes
        } else if let category = transaction.category {
            category.name
        } else if let budget = transaction.budget {
            budget.name
        } else {
            "Unknown"
        }
    }

    private var symbol: String {
        if let category = transaction.category {
            category.symbol
        } else if let budget = transaction.budget {
            budget.symbol
        } else {
            "?"
        }
    }

    private var color: Color {
        if let category = transaction.category {
            category.color
        } else if let budget = transaction.budget {
            budget.color
        } else {
            .gray
        }
    }

    private var amountCellColor: Color {
        if transaction.isIncome {
            if transaction.budget != nil {
                Color(.systemBlue)
            } else {
                Color(.systemGreen)
            }
        } else {
            if transaction.budget != nil {
                Color(.systemGray)
            } else{
                .clear
            }
        }
    }

    private var amountColor: Color {
        if transaction.budget != nil {
            .white
        } else {
            if transaction.isIncome {
                .white
            } else {
                .primary
            }
        }
    }
    
    private var accountSymbol: String {
        if transaction.account?.accountType == .credit {
            "creditcard"
        } else {
            "banknote"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Text(symbol)
                .font(.title)
                .frame(width: 50, height: 50)
                .background(
                    Circle()
                        .fill(color.opacity(0.5).gradient)
                )
                .shadow(color: color, radius: 5)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .bold()
                    .lineLimit(1)
                
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    let displayDate = (upcoming ? transaction.nextOccurrence : nil) ?? transaction.date
                    
                    Image(systemName: accountSymbol)
                        .font(.caption.bold())

                    Text(transaction.account?.name ?? defaultCheckingName)
                        .font(.caption.bold())
                    
                    if disableGrouping || grouping == .none || transaction.recurrence != .none || upcoming {
                        Text("•")
                            .font(.caption)
                        
                        Text(displayDate.formatted(date: .long, time: .omitted))
                            .font(.caption)
                    }
                }
                .foregroundStyle(Color.secondary)
            }
            
            Spacer()
            
            VStack(spacing: 6) {
                Text(transaction.amount, format: .currency(code: currency))
                    .foregroundStyle(amountColor)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .glassEffect(.regular.tint(amountCellColor))
                
                if transaction.recurrence != .none {
                    Text(transaction.recurrence.rawValue.uppercased())
                        .foregroundStyle(Color(.systemGray))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                }
            }
        }
        .tint(.primary)
        .padding()
        .frame(maxWidth: 500, alignment: .leading)
        .glassEffect()
        .accessibilityElement(children: .combine)
    }
}
