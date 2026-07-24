//
//  Fund.swift
//  Penny
//
//  Created by Ethan Christo on 6/4/26.
//

import SwiftData
import SwiftUI

@Model
class Fund {
    // Stable, store-independent identifier. Used as the `id` for FundEntity so
    // App Intents / Spotlight can resolve a fund across the process boundary,
    // where PersistentIdentifier isn't usable as an entity id.
    var id: UUID = UUID()

    var name: String = ""
    var goal: Double = 0.0
    var preAllocate: Bool = false
    var start: Date = Date()
    var end: Date = Date()
    var symbol: String = "✈️"
    var hexColor: String = "#32D74B"
    var notes: String = ""

    // Transactions tagged with this fund. The inverse is Transaction.fundValue,
    // which the Transaction.fund computed property sets. Deleting a transaction
    // simply detaches it from the fund (nullify) rather than deleting the fund.
    @Relationship(deleteRule: .nullify, inverse: \Transaction.fundValue)
    var transactions: [Transaction]? = nil

    // Sum of every transaction tagged with this fund.
    @Transient
    var contributed: Double {
        (transactions ?? []).reduce(0) {
            if $1.isIncome { $0 + $1.amount }
            else { $0 }
        }
    }

    @Transient
    var progress: Double { goal - contributed }
    
    @Transient
    var used: Double {
        (transactions ?? []).reduce(0) {
            if !$1.isIncome { $0 + $1.amount }
            else { $0 }
        }
        
    }
    
    @Transient
    var remaining: Double {
        if !preAllocate {
            contributed - used
        } else {
            goal - used
        }
    }
    
    @Transient
    var color: Color {
        get {
            Color(hex: hexColor) ?? .green
        }
        set {
            hexColor = newValue.toHex() ?? "#00FF00"
        }
    }
    
    init(name: String = "", amount: Double = 0.0, goal: Double = 0.0, preAllocate: Bool = false, start: Date = Date(), end: Date = Date(), symbol: String = "✈️", hexColor: String = "#32D74B", notes: String = "") {
        self.name = name
        self.goal = goal
        self.preAllocate = preAllocate
        self.start = start
        self.end = end
        self.symbol = symbol
        self.hexColor = hexColor
        self.notes = notes
    }
}
