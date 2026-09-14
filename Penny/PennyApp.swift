//
//  Penny.swift
//  Penny
//
//  Created by Ethan Christo on 12/24/25.
//

import SwiftData
import SwiftUI

@main
struct PennyApp: App {
    @AppStorage("user_theme") private var currentTheme: AppTheme = .system
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false

    @State private var overallBudget = OverallBudget()
    @State private var router = AppRouter.shared

    /// Builds a rounded-design version of the font in the given title attributes,
    /// falling back to the system's default title sizes.
    private func roundedFont(for attributes: [NSAttributedString.Key: Any]) -> UIFont? {
        let baseFont = attributes[.font] as? UIFont
            ?? UIFont.preferredFont(forTextStyle: .largeTitle)
        guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded) else {
            return nil
        }
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }
    

    var body: some Scene {
        WindowGroup {
            ContentView()
            .fontDesign(.rounded)
            .preferredColorScheme(currentTheme.colorScheme)
            .environment(overallBudget)
            .environment(router)
            // Onboarding temporarily disabled — see PennyApp.swift.
            // .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
            //     OnboardingView()
            //         .fontDesign(.rounded)
            //         .preferredColorScheme(currentTheme.colorScheme)
            //         .interactiveDismissDisabled()
            // }
            .task {
                await seedDefaultCategoriesIfNeeded()
                await indexEntitiesForSpotlight()
                // Refresh the payday-anchored window from the latest Payroll transaction
                // so the widget/background case is current even before Home recomputes.
                syncPayrollPayPeriodAnchor()
            }
        }
        .modelContainer(SharedDatabase.shared.container)
    }
}
