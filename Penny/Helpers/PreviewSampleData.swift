//
//  PreviewSampleData.swift
//  Penny
//
//  Sample data for SwiftUI previews only. Apply with `#Preview(traits: .sampleData)`.
//

import SwiftData
import SwiftUI

/// Builds an in-memory SwiftData store filled with representative accounts,
/// categories, budgets, housing, and transactions, and injects the environment
/// objects the app's screens expect (`OverallBudget`, `AppRouter`).
struct SampleData: PreviewModifier {
    static func makeSharedContext() async throws -> ModelContainer {
        let container = try ModelContainer(
            for: Transaction.self, Account.self, Category.self, Budget.self, CategoryRules.self, Housing.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        insertSampleData(into: container.mainContext)
        return container
    }

    func body(content: Content, context: ModelContainer) -> some View {
        content
            .modelContainer(context)
            .environment(OverallBudget())
            .environment(AppRouter.shared)
            .fontDesign(.rounded)
    }

    private static func insertSampleData(into context: ModelContext) {
        let checking = Account(name: "Checking", accountType: .checking)
        let savings = Account(name: "Savings", accountType: .savings)
        let credit = Account(name: "Visa", accountType: .credit, closingDate: 20, dueDate: 15)
        [checking, savings, credit].forEach(context.insert)

        var categories: [CategoryOptions: Category] = [:]
        for option in CategoryOptions.allCases {
            let category = option.preBuiltCategory
            context.insert(category)
            categories[option] = category
        }

        categories[.groceries]?.budget = Budget(hasBudget: true, budget: 400, budgetWindow: .monthly)
        categories[.food]?.budget = Budget(hasBudget: true, budget: 250, budgetWindow: .monthly)

        let coffeeRule = CategoryRules(inputNotes: "Starbucks")
        coffeeRule.category = categories[.drinks]
        context.insert(coffeeRule)

        let vacation = Budget(
            name: "Vacation",
            amount: 1_500,
            budgetWindow: .monthly,
            start: Date.now.startOfMonth,
            end: Date.now.addingTimeInterval(60 * 60 * 24 * 90),
            symbol: "✈️",
            hexColor: "#1c8dff"
        )
        context.insert(vacation)

        context.insert(Housing(name: "Apartment", amount: 1_800, account: checking, startDate: Date.now.startOfYear, frequency: .monthly))

        let calendar = Calendar.current
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        }

        let transactions: [Transaction] = [
            Transaction(amount: 2_400, isIncome: true, date: daysAgo(3), account: checking, category: categories[.payroll], notes: "Acme Corp Payroll", recurrence: .biweekly),
            Transaction(amount: 86.42, date: daysAgo(1), account: credit, category: categories[.groceries], notes: "Trader Joe's"),
            Transaction(amount: 6.75, date: daysAgo(1), account: credit, category: categories[.drinks], notes: "Starbucks"),
            Transaction(amount: 42.10, date: daysAgo(2), account: credit, category: categories[.food], notes: "Chipotle"),
            Transaction(amount: 15.99, date: daysAgo(5), account: credit, category: categories[.entertainment], notes: "Netflix", recurrence: .monthly),
            Transaction(amount: 54.30, date: daysAgo(6), account: checking, category: categories[.transportation], notes: "Shell Gas"),
            Transaction(amount: 129.99, date: daysAgo(9), account: credit, category: categories[.shopping], notes: "Amazon"),
            Transaction(amount: 300, date: daysAgo(10), account: savings, category: categories[.savingsAndInvestments], notes: "Monthly Transfer", recurrence: .monthly),
            Transaction(amount: 112.58, date: daysAgo(14), account: credit, category: categories[.groceries], notes: "Whole Foods"),
            Transaction(amount: 2_400, isIncome: true, date: daysAgo(17), account: checking, category: categories[.payroll], notes: "Acme Corp Payroll", recurrence: .biweekly),
            Transaction(amount: 240, date: daysAgo(20), account: credit, budget: vacation, notes: "Flight Deposit"),
            Transaction(amount: 38.00, date: daysAgo(35), account: credit, category: categories[.health], notes: "CVS Pharmacy"),
        ]
        transactions.forEach(context.insert)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    /// In-memory sample store plus the app's environment objects.
    @MainActor static var sampleData: Self = .modifier(SampleData())
}

/// Fetches the first model of a type from a preview's container, for previews of
/// views that take a model as a parameter.
@MainActor
func previewModel<T: PersistentModel>(_ type: T.Type, in context: ModelContext, where predicate: Predicate<T>? = nil) -> T? {
    var descriptor = FetchDescriptor<T>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
}
