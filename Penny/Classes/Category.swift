//
//  Category.swift
//  Penny
//
//  Created by Ethan Christo on 12/31/25.
//

import SwiftData
import SwiftUI

// MARK: - Category
@Model
class Category {
    #Index<Category>([\.name], [\.role])

    // Stable, store-independent identifier. Used as the `id` for CategoryEntity so
    // App Intents / Spotlight can resolve a category across the process boundary,
    // where PersistentIdentifier isn't usable as an entity id.
    var id: UUID = UUID()

    var name: String = ""

    @Relationship(deleteRule: .cascade, inverse: \Budget.category)
    var budget: Budget?
    var hexColor: String = "#32D74B"
    var symbol: String = "💰"

    @Relationship(deleteRule: .cascade, inverse: \CategoryRules.category)
    var rules: [CategoryRules]?

    /// Optional (rather than defaulting to `.userCreated`) so rows written before
    /// this property existed — or synced in from a device still running an older
    /// schema — decode to `nil` instead of crashing SwiftData's generated
    /// non-optional accessor. CloudKit-backed stores can't rename a property during
    /// migration, so this keeps the original `role` name and pushes the default onto
    /// `effectiveRole` instead of a differently-named backing property.
    var role: CategoryRole?

    /// `role`, defaulting to `.userCreated` for records that have no value set yet.
    /// Prefer this over `role` everywhere except code that specifically needs to
    /// distinguish "never assigned" from "explicitly user-created" (the migration
    /// backfill in `seedDefaultCategoriesIfNeeded`).
    var effectiveRole: CategoryRole { role ?? .userCreated }

    @Transient
    var color: Color {
        get {
            Color(hex: hexColor) ?? .green
        }
        set {
            hexColor = newValue.toHex() ?? "#00FF00"
        }
    }
    
    @Relationship(deleteRule: .nullify, inverse: \Transaction.categoryValue)
        var transactions: [Transaction]?
    
    init(name: String = "", budget: Budget? = nil, hexColor: String = "#32D74B", symbol: String = "💰", rules: [CategoryRules] = [], role: CategoryRole = .userCreated) {
        self.name = name
        self.budget = budget ?? Budget(hasBudget: false, budget: 0.0, budgetWindow: .monthly)
        self.hexColor = hexColor
        self.symbol = symbol
        self.rules = rules
        self.role = role
    }
}

// MARK: Category Rules
enum CategoryRulesInputType: String, Codable {
    var id: String { rawValue }
    
    case notes = "Notes"
    case amount = "Amount"
    case account = "Account"
    case recurrence = "Reccurence"
    case date = "Date"
}

@Model
class CategoryRules {
    var inputNotes: String?

    @Relationship(deleteRule: .nullify, inverse: \Account.rules)
    var inputAccount: Account?

    var inputRecurrence: Recurrence?
    var inputDate: Date?
    var match: String = ""

    var category: Category?
    
    init(inputNotes: String? = nil, inputAccount: Account? = nil, inputRecurrence: Recurrence? = nil, inputDate: Date? = nil, match: String = "") {
        self.inputNotes = inputNotes
        self.inputAccount = inputAccount
        self.inputRecurrence = inputRecurrence
        self.inputDate = inputDate
        self.match = match
    }
}
