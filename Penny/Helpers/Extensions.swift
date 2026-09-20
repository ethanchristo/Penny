//
//  Extensions.swift
//  Penny
//
//  Created by Ethan Christo on 1/5/26.
//

import Foundation
import OrderedCollections
import SwiftUI

// The shared App Group defaults are thread-safe and read from the background
// net-total actor, so this must not inherit the module's default `@MainActor`.
nonisolated extension UserDefaults {
    static let group: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: SharedDatabase.appGroup) else {
            fatalError("App Group '\(SharedDatabase.appGroup)' is not configured. Check entitlements.")
        }
        return defaults
    }()
}

// Pure date arithmetic with no shared mutable state. Marked `nonisolated` so the
// net-total aggregation can run on the background `StatsCalculator` ModelActor even
// though the module defaults to `@MainActor` isolation.
nonisolated extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
    
    var endOfDay: Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfDay) ?? self
    }
    
    var startOfWeek: Date {
        Calendar.current.dateComponents([.calendar, .yearForWeekOfYear, .weekOfYear], from: self).date ?? self
    }
    
    var endOfWeek: Date {
        // Robust Pattern: Start of Week + 7 Days - 1 Second
        let calendar = Calendar.current
        guard let startOfNextWeek = calendar.date(byAdding: .day, value: 7, to: startOfWeek) else { return self }
        return calendar.date(byAdding: .second, value: -1, to: startOfNextWeek) ?? self
    }
    
    var startOfFortnight: Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        
        // Safety: Default to self if calculation fails
        let weekOfYear = calendar.component(.weekOfYear, from: self)
        
        // If even week, go back 1 week. If odd, stay here.
        if weekOfYear % 2 == 0 {
            return calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek) ?? startOfWeek
        } else {
            return startOfWeek
        }
    }
    
    var endOfFortnight: Date {
        // Robust Pattern: Start of Fortnight + 14 Days - 1 Second
        let calendar = Calendar.current
        guard let endOfPeriod = calendar.date(byAdding: .day, value: 14, to: startOfFortnight) else { return self }
        return calendar.date(byAdding: .second, value: -1, to: endOfPeriod) ?? self
    }
    
    var startOfMonth: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: components) ?? self
    }
    
    var endOfMonth: Date {
        // Robust Pattern: Start of Month + 1 Month - 1 Second
        let calendar = Calendar.current
        guard let startOfNextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) else { return self }
        return calendar.date(byAdding: .second, value: -1, to: startOfNextMonth) ?? self
    }
    
    var startOfQuarter: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: self)
        
        guard let month = components.month else { return self }
        
        // Calculate the first month of the quarter (1, 4, 7, 10)
        let startMonth = ((month - 1) / 3) * 3 + 1
        
        return calendar.date(from: DateComponents(year: components.year, month: startMonth, day: 1)) ?? self
    }
    
    var endOfQuarter: Date {
        // Robust Pattern: Start of Quarter + 3 Months - 1 Second
        let calendar = Calendar.current
        guard let startOfNextQuarter = calendar.date(byAdding: .month, value: 3, to: startOfQuarter) else { return self }
        
        return calendar.date(byAdding: .second, value: -1, to: startOfNextQuarter) ?? self
    }
    
    var startOfSemiAnnual: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: self)

        guard let month = components.month else { return self }

        // First month of the half-year: 1 (Jan–Jun) or 7 (Jul–Dec).
        let startMonth = month <= 6 ? 1 : 7

        return calendar.date(from: DateComponents(year: components.year, month: startMonth, day: 1)) ?? self
    }

    var endOfSemiAnnual: Date {
        // Robust Pattern: Start of Semi-Annual + 6 Months - 1 Second
        let calendar = Calendar.current
        guard let startOfNextSemiAnnual = calendar.date(byAdding: .month, value: 6, to: startOfSemiAnnual) else { return self }

        return calendar.date(byAdding: .second, value: -1, to: startOfNextSemiAnnual) ?? self
    }
    
    var startOfYear: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year], from: self)) ?? self
    }
    
    var endOfYear: Date {
        var components = DateComponents()
        components.year = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfYear) ?? self
    }
    
    func shifting(by value: Int, window: BudgetWindow?) -> Date {
        let calendar = Calendar.current
        let component: Calendar.Component
        
        switch window {
        case .daily:        component = .day
        case .weekly:       component = .weekOfYear
        case .biweekly:     return calendar.date(byAdding: .day, value: 14 * value, to: self) ?? self
        case .monthly:      component = .month
        case .quarterly:    return calendar.date(byAdding: .month, value: 3 * value, to: self) ?? self
        case .semiAnnually: return calendar.date(byAdding: .month, value: 6 * value, to: self) ?? self
        case .yearly:       component = .year
        case nil:           return self

        }
        
        return calendar.date(byAdding: component, value: value, to: self) ?? self
    }
}

// Hex <-> Color conversion now lives in ColorHex.swift so the model layer can be
// shared with the PennyFinanceMonitor extension without this file's App Group
// dependency.

// MARK: - The Apple Helper Extension
@available(iOS 27.0, *)
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    func apply(to values: inout [some Identifiable<ItemID>]) {
        var dictionary = OrderedDictionary(uniqueKeys: values.map { $0.id }, values: values)
        
        let destinationOffset: Int? = switch destination.position {
        case .before(let destination):
            dictionary.keys.firstIndex(of: destination)
        case .end:
            nil
        }
        
        dictionary.move(keys: sources, to: destinationOffset ?? values.endIndex)
        values = dictionary.values.elements
    }
}
