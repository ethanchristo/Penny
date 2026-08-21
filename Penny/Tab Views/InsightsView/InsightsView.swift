//
//  InsightsScreen.swift
//  Penny
//
//  Created by Ethan Christo on 8/19/26.
//

import SwiftUI

/// Standalone screen that hosts the Insights grid. `InsightsView` is a plain
/// content view (no scrolling or chrome of its own) and supplies its own
/// "Insights" header + menu, so this wrapper only adds the `ScrollView` when
/// Insights is pushed as its own screen.
struct InsightsView: View {
    var body: some View {
        ScrollView {
            InsightsTiles()
                .padding(.top)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.large)
    }
}
