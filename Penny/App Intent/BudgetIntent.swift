//
//  BudgetIntent.swift
//  Penny
//
//  Created by Ethan Christo on 6/15/26.
//

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import SwiftUI

/// App Intents / Spotlight representation of a unified `Budget` — covers both
/// category-linked and freestanding budgets (the latter formerly "funds"), using the
/// model's `displayName`/`displaySymbol` so either kind surfaces consistently.
struct BudgetEntity: IndexedEntity {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Budget"

    static var defaultQuery = BudgetQuery()

    var id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Amount")
    var amount: Double

    @Property(title: "Window")
    var window: String

    private var symbol: String
    private var color: Color
    private var imageData: Data?

    @ComputedProperty(indexingKey: \.contentDescription)
    var subtitleText: String {
        window.isEmpty ? "\(amount.formatted(.currency(code: currencyCode)))" : "\(amount.formatted(.currency(code: currencyCode))) • \(window)"
    }

    var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: LocalizedStringResource(stringLiteral: subtitleText),
            image: imageData.map { DisplayRepresentation.Image(data: $0) }
        )
    }

    @MainActor
    private static func renderSymbolImage(symbol: String, color: Color) -> Data? {
        let view = Text(symbol)
            .font(.system(size: 60))
            .frame(width: 100, height: 100)
            .background(color.gradient)
            .clipShape(Circle())

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    @MainActor
    init(budget: Budget) {
        let symbol = budget.displaySymbol
        let color = budget.color
        self.id = budget.id
        self.symbol = symbol
        self.color = color
        self.imageData = BudgetEntity.renderSymbolImage(symbol: symbol, color: color)
        self.name = budget.displayName
        self.amount = budget.amount
        // Recurring budgets show their reset window; one-time freestanding budgets show "One-time".
        self.window = budget.isRecurring ? (budget.budgetWindow?.rawValue ?? "") : "One-time"
    }
}

struct BudgetQuery: EntityQuery {
    static var isDiscoverable: Bool = false

    // 1. Lookup by ID: Called when the user taps a search result in Spotlight.
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BudgetEntity] {
        let ids = identifiers
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Budget>(predicate: #Predicate { ids.contains($0.id) })
        let budgets = (try? context.fetch(descriptor)) ?? []

        return budgets.map { BudgetEntity(budget: $0) }
    }

    // 3. Suggestions: Every active budget (category + freestanding), shown before the user types.
    @MainActor
    func suggestedEntities() async throws -> [BudgetEntity] {
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Budget>(predicate: #Predicate { $0.hasBudget })
        let budgets = (try? context.fetch(descriptor)) ?? []

        return budgets.map { BudgetEntity(budget: $0) }
    }
}
