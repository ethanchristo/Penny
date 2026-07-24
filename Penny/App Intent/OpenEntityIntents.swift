//
//  OpenEntityIntents.swift
//  Penny
//
//  Created by Ethan Christo on 6/15/26.
//
//  These OpenIntents are what the system runs when the user taps an indexed
//  entity in Spotlight (or asks Siri to open one). Each one opens the app and
//  routes the shared AppRouter to the matching destination.

import AppIntents

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenFundIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Fund"
    
    @Parameter(title: "Fund")
    var target: FundEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openFund(id: target.id)
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenBudgetIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Budget"
    
    @Parameter(title: "Budget")
    var target: BudgetEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openBudget(id: target.id)
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenTransactionIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Transaction"

    @Parameter(title: "Transaction")
    var target: TransactionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openTransaction(id: target.id)
        return .result()
    }
}
