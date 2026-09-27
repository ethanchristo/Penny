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
        Group {
            if horizontalSizeClass == .compact {
                HomeView(
                    stats: stats,
                    horizontalSizeClass: horizontalSizeClass ?? .compact,
                    backgroundColor: backgroundColor
                )
            } else {
                // One stack for both panes, so anything they push covers the whole
                // screen and a single gradient sits behind both.
                NavigationStack {
                    HStack(spacing: 0) {
                        HomeView(
                            stats: stats,
                            horizontalSizeClass: horizontalSizeClass ?? .regular,
                            backgroundColor: backgroundColor
                        )

                        TransactionView()
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
    }
}
