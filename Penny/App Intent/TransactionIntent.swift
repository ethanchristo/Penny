//
//  TransactionIntent.swift
//  Penny
//
//  Created by Ethan Christo on 6/15/26.
//

import AppIntents
import Foundation
import SwiftData

struct TransactionEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction"

    static var defaultQuery = TransactionQuery()

    var id: UUID

    // Category or fund name the transaction is tagged with (whichever is set).
    var tagName: String

    @Property(title: "Amount")
    var amount: Double

    @Property(title: "Income")
    var isIncome: Bool

    @Property(title: "Date")
    var date: Date

    @Property(title: "Notes")
    var notes: String

    var displayRepresentation: DisplayRepresentation {
        let title = notes.isEmpty ? (tagName.isEmpty ? "Transaction" : tagName) : notes
        let sign = isIncome ? "+" : "-"
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: LocalizedStringResource(stringLiteral: "\(sign)$\(amount)")
        )
    }

    init(transaction: Transaction) {
        // Plain stored properties must be initialized before assigning through
        // the @Property wrappers, since those go through a setter that requires
        // `self` to be fully initialized.
        self.id = transaction.id
        self.tagName = transaction.category?.name ?? transaction.fund?.name ?? ""
        self.amount = transaction.amount
        self.isIncome = transaction.isIncome
        self.date = transaction.date
        self.notes = transaction.notes
    }
}

struct TransactionQuery: EntityStringQuery {
    static var isDiscoverable: Bool = false
    
    // 1. Lookup by ID: Called when the user taps a search result in Spotlight.
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TransactionEntity] {
        let ids = identifiers
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { ids.contains($0.id) })
        let transactions = (try? context.fetch(descriptor)) ?? []
        
        return transactions.map { TransactionEntity(transaction: $0) }
    }
    
    // 2. Text Search: Called when the user types into Spotlight or Siri. Matches
    // the notes plus the tagged category/fund name. Capped and sorted newest-first
    // since the transaction table can be large.
    @MainActor
    func entities(matching string: String) async throws -> [TransactionEntity] {
        let context = SharedDatabase.shared.container.mainContext
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { transaction in
                transaction.notes.localizedStandardContains(string) ||
                (transaction.categoryValue?.name.localizedStandardContains(string) ?? false) ||
                (transaction.fundValue?.name.localizedStandardContains(string) ?? false)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        let transactions = (try? context.fetch(descriptor)) ?? []
        
        return transactions.map { TransactionEntity(transaction: $0) }
    }
}
