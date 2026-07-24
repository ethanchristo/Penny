//
//  CategoryIntent.swift
//  Penny
//
//  Created by Ethan Christo on 7/20/26.
//
//  Exposes Category to App Intents / Spotlight / Siri so it can be used as a
//  picker value (e.g. when adding a transaction) and resolved back to the
//  SwiftData model across the process boundary via its stable UUID id.

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import SwiftUI

struct CategoryEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"

    static var defaultQuery = CategoryQuery()

    var id: UUID

    @Property(title: "Name")
    var name: String

    private var symbol: String
    private var color: Color
    private var imageData: Data?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
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
    init(category: Category) {
        // Plain stored properties must be initialized before assigning through
        // the @Property wrappers, since those go through a setter that requires
        // `self` to be fully initialized.
        self.id = category.id
        self.symbol = category.symbol
        self.color = category.color
        self.imageData = CategoryEntity.renderSymbolImage(symbol: category.symbol, color: category.color)
        self.name = category.name
    }
}

struct CategoryQuery: EntityQuery {
    // 1. Lookup by ID: Called when the system resolves a stored selection.
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CategoryEntity] {
        let ids = identifiers
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Category>(predicate: #Predicate { ids.contains($0.id) })
        let categories = (try? context.fetch(descriptor)) ?? []

        return categories.map { CategoryEntity(category: $0) }
    }

    // 2. Suggestions: Every category, shown as the picker options before the user types.
    @MainActor
    func suggestedEntities() async throws -> [CategoryEntity] {
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)])
        let categories = (try? context.fetch(descriptor)) ?? []

        return categories.map { CategoryEntity(category: $0) }
    }
}
