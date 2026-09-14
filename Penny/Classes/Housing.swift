//
//  Housing.swift
//  Penny
//
//  Created by Ethan Christo on 9/9/26.
//

import Foundation
import SwiftData

/// How often a housing payment recurs. Raw values intentionally match `Recurrence`'s
/// so a `Housing` entry's frequency can be bridged into the same date-stepping logic
/// (`calculateNextDate`) that Transaction recurrence uses, without duplicating it.
///
/// Pure value type read by the nonisolated `housingAllTimeTotal` (see Functions.swift),
/// so it opts out of the module's default `@MainActor` isolation.
nonisolated enum HousingFrequency: String, CaseIterable, Codable, Hashable {
    case weekly = "Weekly"
    case biweekly = "Bi-Weekly"
    case monthly = "Monthly"

    var asRecurrence: Recurrence {
        Recurrence(rawValue: rawValue) ?? .monthly
    }
}

/// A recurring rent or mortgage payment. Modeled separately from `Transaction` since
/// it's a standing obligation the user declares up front rather than something posted
/// by a bank sync — but it steps through occurrences the same way a recurring
/// Transaction does, and is folded into the net total the same way (see
/// `housingAllTimeTotal` in Functions.swift). Supports multiple entries (e.g. rent plus
/// a mortgage on a second property) and an optional end date for when the obligation stops.
@Model
class Housing {
    var id: UUID = UUID()
    var name: String = ""
    var mortgage: Bool = false
    var amount: Double = 0
    var account: Account? = nil
    var startDate: Date = Date.now.startOfMonth
    var endDate: Date? = nil
    var frequency: HousingFrequency = HousingFrequency.monthly

    /// Whether an upcoming (not-yet-due) occurrence is counted against the net total
    /// early, `leadDays` before it's due — mirroring the app-wide "Include Upcoming
    /// Recurring" toggle, but tunable per housing entry. On by default.
    var includeUpcoming: Bool = true

    /// How many days before an occurrence's due date it starts counting against the
    /// net total, when `includeUpcoming` is on. 1...14, defaulting to the max.
    var leadDays: Int = 14

    /// The `notes` text of a real (bank-imported) transaction the user linked once, used
    /// to auto-match future occurrences: once a transaction on `account` with these notes
    /// and a matching amount posts, that occurrence stops being double-counted here since
    /// the real transaction already carries it through the normal transaction total. Only
    /// takes effect when `account` is import-linked — either a specific `Account` with an
    /// `externalID`, or `nil` (the app-wide convention for the primary checking account)
    /// when a SimpleFIN/FinanceKit checking feed is designated (see `BankSyncMapping`).
    var matchNotes: String? = nil

    init(id: UUID = UUID(), name: String = "", mortgage: Bool = false, amount: Double = 0, account: Account? = nil, startDate: Date = .now, endDate: Date? = nil, frequency: HousingFrequency = .monthly, includeUpcoming: Bool = true, leadDays: Int = 14, matchNotes: String? = nil) {
        self.id = id
        self.name = name
        self.mortgage = mortgage
        self.amount = amount
        self.account = account
        // Monthly payments anchor to the start of the month so occurrences land on
        // calendar-month boundaries instead of drifting off the original day-of-month;
        // weekly/biweekly keep the exact date and step by day count (see calculateNextDate).
        self.startDate = frequency == .monthly ? startDate.startOfMonth : startDate
        self.endDate = endDate
        self.frequency = frequency
        self.includeUpcoming = includeUpcoming
        self.leadDays = leadDays
        self.matchNotes = matchNotes
    }
}
