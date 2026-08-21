//
//  Transaction.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import AppIntents
import Foundation
import SwiftData

// Conforms to AppEnum (in the same file as the enum, to avoid a retroactive
// Sendable conformance) so it can be used as an App Intents / Shortcuts / Siri
// parameter — e.g. on AddTransactionIntent.
enum Recurrence: String, Codable, CaseIterable, AppEnum {
    case none =         "None"
    case daily =        "Daily"
    case weekly =       "Weekly"
    case biweekly =     "Bi-Weekly"
    case monthly =      "Monthly"
    case quarterly =    "Quarterly"
    case semiAnnually = "Semi-Annually"
    case yearly =       "Yearly"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recurrence"
    static let caseDisplayRepresentations: [Recurrence: DisplayRepresentation] = [
        .none:          "None",
        .daily:         "Daily",
        .weekly:        "Weekly",
        .biweekly:      "Bi-Weekly",
        .monthly:       "Monthly",
        .quarterly:     "Quarterly",
        .semiAnnually:  "Semi-Annually",
        .yearly:        "Yearly"
    ]
}

@Model
class Transaction {
    #Index<Transaction>([\.date], [\.isIncome], [\.date, \.isIncome])

    // Stable, store-independent identifier. Used as the `id` for TransactionEntity
    // so App Intents / Spotlight can resolve a transaction across the process
    // boundary, where PersistentIdentifier isn't usable as an entity id.
    var id: UUID = UUID()

    var amount: Double = 0.0
    var isIncome: Bool = false
    var date: Date = Date.now
    var account: Account? = nil

    // MARK: - Category / Budget (mutually exclusive)
    // A transaction is tagged with EITHER a category OR a (freestanding) budget, never both.
    //
    // `categoryValue` / `budgetValue` are the actual SwiftData-persisted properties (and
    // the targets of the inverse relationships on Category/Budget). The public
    // `category` / `budget` computed properties below wrap them so the exclusivity rule is
    // enforced everywhere they're assigned. We can't use a `didSet` observer for this
    // because SwiftData silently ignores property observers on @Model types — the setter
    // is the supported place to do it.
    var categoryValue: Category?
    var budgetValue: Budget?

    var category: Category? {
        get { categoryValue }
        set {
            categoryValue = newValue
            // Choosing a category clears any budget so they can't both be set.
            if newValue != nil { budgetValue = nil }
        }
    }

    /// The freestanding budget this transaction is tagged to.
    var budget: Budget? {
        get { budgetValue }
        set {
            budgetValue = newValue
            // Choosing a budget clears any category so they can't both be set.
            if newValue != nil { categoryValue = nil }
        }
    }

    var notes: String = ""
    var recurrence: Recurrence = Recurrence.none
    var endDate: Date?

    /// Stable identifier from an external source (e.g. a SimpleFIN transaction id).
    /// Used to deduplicate on re-sync. `nil` for transactions entered by hand.
    var externalID: String?

    @Transient // Tells SwiftData NOT to save this to the database
    var nextOccurrence: Date? {
        if recurrence == .none { return nil }
        
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date.now)
        
        // If the original date hasn't even happened yet, that IS the next date!
        if date >= today {
            return date
        }
        
        var next = date
        
        // Fast-forward the date until it is strictly in the future (after today)
        while next < today {
            switch recurrence {
            case .none:         return nil
            case .daily:        next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            case .weekly:       next = calendar.date(byAdding: .day, value: 7, to: next) ?? next
            case .biweekly:     next = calendar.date(byAdding: .day, value: 14, to: next) ?? next
            case .monthly:      next = calendar.date(byAdding: .month, value: 1, to: next) ?? next
            case .quarterly:    next = calendar.date(byAdding: .month, value: 3, to: next) ?? next
            case .semiAnnually: next = calendar.date(byAdding: .month, value: 6, to: next) ?? next
            case .yearly:       next = calendar.date(byAdding: .year, value: 1, to: next) ?? next
            }
        }
        
        // Finally, make sure this next date doesn't exceed the user's End Date
        if let limit = endDate, next > calendar.startOfDay(for: limit) {
            return nil // The recurrence has officially ended!
        }
        
        return next
    }
    
    init(amount: Double = 0.00, isIncome: Bool = false, date: Date = .now, account: Account? = nil, category: Category? = nil, budget: Budget? = nil, notes: String = "", recurrence: Recurrence = .none, endDate: Date? = nil, externalID: String? = nil) {
        self.amount = amount
        self.isIncome = isIncome
        self.date = date
        self.account = account
        // Enforce category/budget exclusivity at creation. If both are somehow supplied,
        // the freestanding budget wins over the category.
        if budget != nil {
            self.budgetValue = budget
            self.categoryValue = nil
        } else {
            self.categoryValue = category
            self.budgetValue = nil
        }
        self.notes = notes
        self.recurrence = recurrence
        self.endDate = endDate
        self.externalID = externalID
    }
}
