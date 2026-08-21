//
//  AppShortcutsProvider.swift
//  Penny
//
//  Created by Ethan Christo on 7/20/26.
//

import AppIntents

@available(iOS 27.0, *)
struct PennyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        
        // 1. Add Transaction (From our previous work)
        AppShortcut(
            intent: AddTransactionIntent(),
            phrases: [
                "Log a transaction in \(.applicationName)",
                "Add an expense to \(.applicationName)",
                "Record income in \(.applicationName)"
            ],
            shortTitle: "Add Transaction",
            systemImageName: "plus.circle"
        )
        
        // 2. Net Total
        AppShortcut(
            intent: NetTotalIntent(),
            phrases: [
                "What's my net total in \(.applicationName)",
                "Show my net total in \(.applicationName)",
                "\(.applicationName) net total"
            ],
            shortTitle: "Net Total",
            systemImageName: "dollarsign.circle"
        )
        
        // 3. Open Budget (Using your system schema intent)
        AppShortcut(
            intent: OpenBudgetIntent(),
            phrases: [
                "Open \(\.$target) budget in \(.applicationName)",
                "Show my \(\.$target) budget in \(.applicationName)",
                "Check my \(\.$target) budget in \(.applicationName)"
            ],
            shortTitle: "Open Budget",
            systemImageName: "chart.bar"
        )
        
        // 4. Open Transaction (Using your system schema intent)
        AppShortcut(
            intent: OpenTransactionIntent(),
            phrases: [
                "Open transaction \(\.$target) in \(.applicationName)",
                "Show transaction \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Open Transaction",
            systemImageName: "list.bullet.rectangle"
        )
    }
}
