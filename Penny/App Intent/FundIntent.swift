//
//  FundIntent.swift
//  Penny
//
//  Created by Ethan Christo on 6/15/26.
//

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import SwiftUI

struct FundEntity: IndexedEntity {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fund"
    
    static var defaultQuery = FundQuery()
    
    var id: UUID

    @Property(title: "Name")
    var name: String
    
    @Property(title: "Amount")
    var goal: Double
    
    @Property(title: "Date")
    var date: Date
    
    @Property(title: "Notes")
    var notes: String
    
    private var preAllocate: Bool
    private var remaining: Double
    
    private var symbol: String
    private var color: Color
    private var imageData: Data?
    
    @ComputedProperty(indexingKey: \.contentDescription)
    var subtitleText: String {
        "\(remaining.formatted(.currency(code: currencyCode))) remaining"
    }
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
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
    init(fund: Fund) {
        // Plain stored properties must be initialized before assigning through
        // the @Property wrappers, since those go through a setter that requires
        // `self` to be fully initialized.
        self.id = fund.id
        self.preAllocate = fund.preAllocate
        self.remaining = fund.remaining
        self.symbol = fund.symbol
        self.color = fund.color
        self.imageData = FundEntity.renderSymbolImage(symbol: fund.symbol, color: fund.color)
        self.name = fund.name
        self.goal = fund.goal
        self.date = fund.end
        self.notes = fund.notes
    }
}

struct FundQuery: EntityQuery {
    static var isDiscoverable: Bool = false
    
    // 1. Lookup by ID: Called when the user taps on the search result in Spotlight
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [FundEntity] {
        let ids = identifiers
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Fund>(predicate: #Predicate { ids.contains($0.id) })
        let funds = (try? context.fetch(descriptor)) ?? []

        return funds.map { FundEntity(fund: $0) }
    }
    
    // 3. Suggestions: Shown as defaults before the user even starts typing
    @MainActor
    func suggestedEntities() async throws -> [FundEntity] {
        let context = SharedDatabase.shared.container.mainContext
        let descriptor = FetchDescriptor<Fund>()
        let allFunds = (try? context.fetch(descriptor)) ?? []
        
        return allFunds.map { FundEntity(fund: $0) }
    }
}
