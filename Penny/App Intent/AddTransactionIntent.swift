//
//  AddTransactionIntent.swift
//  Penny
//
//  Created by Ethan Christo on 7/20/26.
//

import AppIntents
import Foundation
import SwiftData

/// 1. We create an AppEnum to let the user toggle the grouping type.
enum GroupingChoice: String, AppEnum {
    case category
    case fund

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Grouping Choice"
    static let caseDisplayRepresentations: [GroupingChoice: DisplayRepresentation] = [
        .category: "Category",
        .fund: "Fund"
    ]
}

// 🚨 If/when Apple adds a standard financial schema, you will adopt it using this macro:
// @AppIntent(schema: .financial.createTransaction)
struct AddTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Transaction"
    static var description: IntentDescription = "Log a new income or expense transaction in Penny."

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount", description: "The monetary value of the transaction.")
    var amount: Double
    
    @Parameter(title: "Type", description: "Whether this transaction is income.", default: false)
    var isIncome: Bool

    @Parameter(title: "Date", description: "The date and time the transaction occurred.")
    var date: Date?
    
    @Parameter(title: "Recurrence", description: "The frequency that the transaction occurs.")
    var recurrence: Recurrence?
    
    @Parameter(title: "End Date", description: "The day the recurrence for the transaction ends.")
    var endDate: Date?

    @Parameter(title: "Grouping", description: "Assign this to a Category or a Fund.", default: .category)
    var grouping: GroupingChoice
    
    // 🚨 We use CategoryEntity and FundEntity here so App Intents can use your EntityQueries for the pickers!
    @Parameter(title: "Category", description: "The category the transaction belongs to.")
    var categoryEntity: CategoryEntity?
    
    @Parameter(title: "Fund", description: "The fund the transaction belongs to.")
    var fundEntity: FundEntity?

    @Parameter(title: "Notes", description: "The merchant name or description.", default: "")
    var notes: String

    // 2. The parameter summary generates the Shortcuts UI. `When` swaps between two
    // summaries so only the Category OR the Fund picker shows — enforcing the
    // model's mutual exclusivity right in the editor.
    static var parameterSummary: some ParameterSummary {
        When(\.$grouping, .equalTo, GroupingChoice.category) {
            Summary("Log a transaction of \(\.$amount)") {
                \.$isIncome
                \.$grouping
                \.$categoryEntity
                \.$date
                \.$recurrence
                \.$endDate
                \.$notes
            }
        } otherwise: {
            Summary("Log a transaction of \(\.$amount)") {
                \.$isIncome
                \.$grouping
                \.$fundEntity
                \.$date
                \.$recurrence
                \.$endDate
                \.$notes
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TransactionEntity> & ProvidesDialog {
        let context = SharedDatabase.shared.container.mainContext
        
        let descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.name == "Miscellaneous" })
        let miscCategory = try? context.fetch(descriptor).first
        
        var targetCategory: Category? = miscCategory
        var targetFund: Fund? = nil
        
        // 3. Resolve the AppEntities back into your SwiftData models based on the mutual exclusivity choice
        if grouping == .category, let catEntity = categoryEntity {
            let catID = catEntity.id
            let catDescriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == catID })
            targetCategory = try? context.fetch(catDescriptor).first
        } else if grouping == .fund, let fEntity = fundEntity {
            let fundID = fEntity.id
            let fundDescriptor = FetchDescriptor<Fund>(predicate: #Predicate { $0.id == fundID })
            targetFund = try? context.fetch(fundDescriptor).first
            targetCategory = nil
        }
        
        let newTx = Transaction(
            amount: amount,
            isIncome: isIncome,
            date: date ?? Date.now,
            account: nil,
            category: targetCategory,
            fund: targetFund,
            notes: notes,
            recurrence: recurrence ?? .none,
            endDate: endDate,
            externalID: nil
        )
        
        context.insert(newTx)
        try? context.save()
        
        let entity = TransactionEntity(transaction: newTx)
        
        let currencyCode = UserDefaults.group.string(forKey: "currency_code") ?? "USD"
        let typeString = isIncome ? "income" : "expense"
        let merchantString = notes.isEmpty ? "" : " at \(notes)"
        
        return .result(
            value: entity,
            dialog: IntentDialog("I logged a \(amount.formatted(.currency(code: currencyCode))) \(typeString)\(merchantString) in Penny.")
        )
    }
}
