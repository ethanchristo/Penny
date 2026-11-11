//
//  HomeTips.swift
//  Penny
//
//  In-context coach marks for the Overview screen, shown after the intro
//  onboarding finishes. Each tip is a popover anchored to the element it explains.
//

import SwiftUI
import TipKit

/// The Overview walkthrough: tips are presented one at a time in this order, each
/// waiting for the previous one to be dismissed (or its feature to be used).
///
/// TipKit can't un-invalidate a tip once the datastore is configured, so each tip's
/// `id` includes a "generation" number. Restarting the tour bumps the generation,
/// producing fresh tips with no seen/dismissed history.
@MainActor
@Observable
final class HomeTour {
    static let shared = HomeTour()

    private static let generationKey = "home_tour_generation"

    private(set) var tips: TipGroup

    private init() {
        tips = Self.makeTips(generation: UserDefaults.standard.integer(forKey: Self.generationKey))
    }

    private static func makeTips(generation: Int) -> TipGroup {
        TipGroup(.ordered) {
            NetTotalTip(generation: generation)
            AddTransactionTip(generation: generation)
            BudgetsTip(generation: generation)
            InsightsTip(generation: generation)
            SettingsTip(generation: generation)
        }
    }

    /// The current walkthrough. Views read this in `body`, so restarting the tour
    /// re-renders their popovers.
    static var tips: TipGroup { shared.tips }

    /// Shows the whole walkthrough again from the first tip.
    func restart() {
        let generation = UserDefaults.standard.integer(forKey: Self.generationKey) + 1
        UserDefaults.standard.set(generation, forKey: Self.generationKey)
        tips = Self.makeTips(generation: generation)
    }

    /// Dismisses the current tip if it's the one for the feature just used, so
    /// using a control counts as having seen its tip.
    static func featureUsed<T: Tip>(_ type: T.Type) {
        if let tip = tips.currentTip as? T {
            tip.invalidate(reason: .actionPerformed)
        }
    }
}

struct NetTotalTip: Tip {
    /// Mirrors `has_completed_onboarding` so the walkthrough doesn't appear behind
    /// the full-screen intro. Set from `PennyApp`.
    @Parameter static var hasCompletedOnboarding: Bool = false

    let generation: Int
    var id: String { "NetTotalTip-\(generation)" }

    var title: Text { Text("Your Net Total").fontDesign(.rounded) }
    var message: Text? {
        Text("Everything you have across your accounts. Tap for a breakdown, or touch and hold to switch how credit cards are counted.")
            .fontDesign(.rounded)
    }
    var image: Image? { Image(systemName: "dollarsign.circle") }

    var rules: [Rule] {
        #Rule(Self.$hasCompletedOnboarding) { $0 == true }
    }
}

struct AddTransactionTip: Tip {
    let generation: Int
    var id: String { "AddTransactionTip-\(generation)" }

    var title: Text { Text("Log a Transaction").fontDesign(.rounded) }
    var message: Text? {
        Text("Add income or spending by hand. Imported transactions from your bank show up automatically.")
            .fontDesign(.rounded)
    }
    var image: Image? { Image(systemName: "plus.circle") }
}

struct BudgetsTip: Tip {
    let generation: Int
    var id: String { "BudgetsTip-\(generation)" }

    var title: Text { Text("Budgets").fontDesign(.rounded) }
    var message: Text? {
        Text("Set limits for categories or save toward goals like a trip, and see how much is left.")
            .fontDesign(.rounded)
    }
    var image: Image? { Image(systemName: "rectangle.grid.2x2") }
}

struct InsightsTip: Tip {
    let generation: Int
    var id: String { "InsightsTip-\(generation)" }

    var title: Text { Text("Insights").fontDesign(.rounded) }
    var message: Text? {
        Text("Charts of where your money goes, cash flow, and upcoming recurring payments.")
            .fontDesign(.rounded)
    }
    var image: Image? { Image(systemName: "chart.bar") }
}

struct SettingsTip: Tip {
    let generation: Int
    var id: String { "SettingsTip-\(generation)" }

    var title: Text { Text("Make Penny Yours").fontDesign(.rounded) }
    var message: Text? {
        Text("Connect your bank, edit categories and rules, and choose your currency and start of week.")
            .fontDesign(.rounded)
    }
    var image: Image? { Image(systemName: "gear") }
}
