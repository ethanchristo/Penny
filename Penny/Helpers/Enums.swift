//
//  Enums.swift
//  Penny
//
//  Created by Ethan Christo on 3/9/26.
//

import Foundation
import UIKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var id: String { rawValue }
    
    // Helper to convert selection to SwiftUI's ColorScheme
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum HomeTimeRange: String, CaseIterable, Identifiable {
    case daily =     "Today"
    case weekly =    "This Week"
    case monthly =   "This Month"
    case yearly =    "This Year"
    case allTime =   "All Time"
    case payPeriod = "Pay Period"

    var id: String { rawValue }

    var withOffset: String {
        switch self {
        case .daily:     "Daily"
        case .weekly:    "Weekly"
        case .monthly:   "Monthly"
        case .yearly:    "Yearly"
        case .allTime:   "All Time"
        case .payPeriod: "Pay Period"
        }
    }

}

/// How often the user is paid, used to anchor the "Pay Period" time range.
/// Weekly/biweekly step by a fixed day count; monthly steps by whole calendar
/// months (preserving the payday's day-of-month) since months vary in length.
// Pure value type read by the background net-total actor (`payPeriodBounds`), so it
// opts out of the module's default `@MainActor` isolation.
nonisolated enum PayPeriodCadence: String, CaseIterable, Identifiable {
    case weekly =   "Weekly"
    case biweekly = "Biweekly"
    case monthly =  "Monthly"

    var id: String { rawValue }

    /// Fixed day count for day-based cadences; `nil` for monthly (calendar-stepped).
    var lengthDays: Int? {
        switch self {
        case .weekly:   return 7
        case .biweekly: return 14
        case .monthly:  return nil
        }
    }
}

enum TransactionGrouping: String, CaseIterable, Identifiable {
    case none =     "None"
    case day =      "Day"
    case week =     "Week"
    case month =    "Month"

    var id: String { rawValue }
}

enum AccountType: String, Codable, CaseIterable, Identifiable {
    case checking = "Checking Account"
    case savings = "Savings Account"
    case credit = "Credit Card"
    
    var id: String { rawValue }
}

enum CreditCardBalanceType: String, CaseIterable, Identifiable {
    case timeRange = "timeRange"
    case statement = "statement"
    case balance = "balance"

    var id: String { rawValue }

    /// User-facing label for the two net-total modes (`timeRange` is used only by
    /// the charts and isn't offered as a net-total mode).
    var title: String {
        switch self {
        case .timeRange: return "Time Range"
        case .balance: return "Total Balance"
        case .statement: return "Amount Due"
        }
    }
}

enum DecimalPadType: String, CaseIterable, Identifiable {
    case ATM = "ATM"
    case decimal = "Decimal"
    
    var id: String { self.rawValue }
}

enum BudgetWindow: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }
    
    case daily =            "Daily"
    case weekly =           "Weekly"
    case biweekly =         "Bi-Weekly"
    case monthly =          "Monthly"
    case quarterly =        "Quarterly"
    case semiAnnually =     "Semi-Annual"
    case yearly =           "Yearly"
}

enum CategoryOptions: String, CaseIterable, Identifiable {
    case rentAndUtilities = "Rent & Utilities"
    case groceries = "Groceries"
    case food = "Food"
    case drinks = "Drinks"
    case transportation = "Transportation"
    case shopping = "Shopping"
    case entertainment = "Entertainment"
    case savingsAndInvestments = "Savings & Investments"
    case health = "Health"
    case gifts = "Gifts"
    case payroll = "Payroll"
    case miscellaneous = "Miscellaneous"
    
    var id: String { self.rawValue }
    
    var symbol: String {
        switch self {
        case .rentAndUtilities: return "🏠"
        case .groceries: return "🛒"
        case .food: return "🍔"
        case .drinks: return "🍸"
        case .transportation: return "🚊"
        case .shopping: return "🛍️"
        case .entertainment: return "🎬"
        case .savingsAndInvestments: return "📈"
        case .health: return "🩺"
        case .gifts: return "🎁"
        case .payroll: return "💰"
        case .miscellaneous: return "📦"
        }
    }
    
    var hexColor: String {
        switch self {
        case .rentAndUtilities: return "#FF453A"        // Red
        case .groceries: return "#32D74B"               // Green
        case .food: return "#FF9F0A"                    // Orange
        case .drinks: return "#FE7DE4"                  // Pink
        case .transportation: return "#1c8dff"          // Blue
        case .shopping: return "#FF375F"                // Coral
        case .entertainment: return "#BF5AF2"           // Purple
        case .savingsAndInvestments: return "#7d5d48"   // Brown
        case .health: return "#5AC8FA"                  // Light Blue
        case .gifts: return "5afaaf"                    // Sea Foam
        case .payroll: return "#FFD60A"                 // Yellow
        case .miscellaneous: return "#8E8E93"           // Gray
        }
    }
    
    var preBuiltCategory: Category {
        return Category(
            name: self.rawValue,
            hexColor: self.hexColor,
            symbol: self.symbol,
            isPreBuilt: true
        )
    }
}
