//
//  Penny.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import SwiftData
import SwiftUI
import TipKit

@main
struct PennyApp: App {
    @AppStorage("user_theme") private var currentTheme: AppTheme = .system
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false

    @State private var overallBudget = OverallBudget()
    @State private var router = AppRouter.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Loads persisted tip state (which coach marks were already seen).
        try? Tips.configure([.displayFrequency(.immediate)])

        // `.fontDesign(.rounded)` doesn't reach UIKit-drawn navigation bar titles,
        // so give the bar rounded fonts that match the system's sizes and weights.
        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = [.font: Self.roundedFont(.largeTitle, weight: .bold)]
        navigationBar.titleTextAttributes = [.font: Self.roundedFont(.headline, weight: .semibold)]
    }

    /// A rounded system font at the given text style's size that still scales
    /// with Dynamic Type.
    private static func roundedFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        return UIFontMetrics(forTextStyle: style).scaledFont(for: rounded)
    }
    

    var body: some Scene {
        WindowGroup {
            ContentView()
            .fontDesign(.rounded)
            .preferredColorScheme(currentTheme.colorScheme)
            .environment(overallBudget)
            .environment(router)
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { hasCompletedOnboarding = !$0 }
            )) {
                OnboardingView()
                    .fontDesign(.rounded)
                    .preferredColorScheme(currentTheme.colorScheme)
                    .interactiveDismissDisabled()
            }
            // Hold the Overview walkthrough until the intro onboarding is dismissed.
            .onChange(of: hasCompletedOnboarding, initial: true) {
                NetTotalTip.hasCompletedOnboarding = hasCompletedOnboarding
            }
            .task {
                await seedDefaultCategoriesIfNeeded()
                await indexEntitiesForSpotlight()
                // Refresh the payday-anchored window from the latest Payroll transaction
                // so the widget/background case is current even before Home recomputes.
                syncPayrollPayPeriodAnchor()
                // Re-arm Wallet change delivery for the PennyFinanceMonitor
                // extension; FinanceKit keeps it until explicitly disabled.
                if FinanceKitConfig.isConfigured {
                    FinanceKitClient.enableBackgroundDelivery()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    BankSync.scheduleBackgroundRefresh()
                }
            }
        }
        .modelContainer(SharedDatabase.shared.container)
        // Woken by BGTaskScheduler while Penny is suspended. The next request is
        // submitted first so the chain continues even if this run is cut short.
        .backgroundTask(.appRefresh(BankSync.refreshTaskIdentifier)) {
            await Self.runBackgroundSync()
        }
    }

    /// Runs the background bank sync entirely on the main actor, so the
    /// non-Sendable main `ModelContext` never leaves its isolation domain.
    @MainActor
    private static func runBackgroundSync() async {
        BankSync.scheduleBackgroundRefresh()
        await BankSync.syncAll(in: SharedDatabase.shared.container.mainContext)
    }
}
