//
//  ContentView.swift
//  Penny
//
//  Created by Ethan Christo on 9/12/26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("user_yellow_threshhold", store: .group) private var yellowThreshold: Double = 100.0

    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    @State private var stats = HomeStats()
    
    private var backgroundColor: Color {
        if stats.netTotal > yellowThreshold {
            Color(.systemGreen)
        } else if stats.netTotal <= 0 {
            Color(.systemRed)
        } else if stats.netTotal > 0 && stats.netTotal <= yellowThreshold {
            Color(.systemYellow)
        } else {
            Color(.systemRed)
        }
    }
    
    var body: some View {
        // A single stack whose structure never changes with the size class, so a
        // rotation or unfold that flips compact ↔ regular keeps whatever is pushed.
        // Only the second pane comes and goes; anything either pane pushes covers
        // the whole screen and a single gradient sits behind both.
        NavigationStack {
            HStack(spacing: 0) {
                HomeView(
                    stats: stats,
                    horizontalSizeClass: horizontalSizeClass ?? .compact,
                    backgroundColor: backgroundColor
                )

                if horizontalSizeClass == .regular {
                    TransactionView()
                }
            }
            .navigationTitle("Overview")
            .background {
                LinearGradient(
                    colors: [backgroundColor.opacity(0.7), .clear, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }
}
