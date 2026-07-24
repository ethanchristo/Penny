//
//  NetTotalIntent.swift
//  Penny
//
//  Created by Ethan Christo on 6/17/26.
//
//  Returns the same net total HomeView shows, for Spotlight / Siri / Shortcuts.
//  Rather than reuse HomeStats (a SwiftUI view-model that needs the view's
//  @Query data injected), this fetches from the shared SwiftData container and
//  calls `netTotalType` directly — the single source of truth the widget uses too.

import AppIntents
import Foundation
import SwiftData
import SwiftUI

struct NetTotalIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Net Total"
    static var description = IntentDescription("Shows your current net total for the selected time range.")

    // No need to launch the app; the result is delivered inline in Spotlight/Siri.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog & ShowsSnippetView {
        // Mirror the settings the app and widget read from the shared App Group.
        let defaults = UserDefaults.group
        let currencyCode = defaults.string(forKey: "currency_code") ?? "USD"
        let currencySymbol = defaults.string(forKey: "currency_symbol") ?? "$"
        let yellowThreshold = defaults.object(forKey: "user_yellow_threshhold") as? Double ?? 100.0

        // The net total is all-time, matching the home tab. Computed off the main
        // thread on the shared background ModelActor.
        let total = await StatsCalculator(modelContainer: SharedDatabase.shared.container)
            .allTimeNetTotals()
            .total

        let formatted = total.formatted(.currency(code: currencyCode))
        return .result(
            value: total,
            dialog: IntentDialog("Your net total is \(formatted)."),
            view: NetTotalSnippetView(
                netTotal: total,
                currencySymbol: currencySymbol,
                yellowThreshold: yellowThreshold
            )
        )
    }
}

/// The card shown in Spotlight / Siri results. Mirrors the widget's styling —
/// big truncated amount over a green/yellow/red background driven by the same
/// threshold the home screen and widget use.
struct NetTotalSnippetView: View {
    let netTotal: Double
    let currencySymbol: String
    let yellowThreshold: Double

    private var background: Color {
        if netTotal <= 0.0 {
            Color(.systemRed)
        } else if netTotal <= yellowThreshold {
            Color(.systemYellow)
        } else {
            Color(.systemGreen)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("Net Total")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(amountTruncation(for: netTotal, currencySymbol: currencySymbol))
                .font(.largeTitle)
                .bold()

            Text("ALL TIME")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fontDesign(.rounded)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(background.gradient)
    }
}

/// Registers the net total as an App Shortcut so it surfaces as a top hit in
/// Spotlight and is voice-invokable with Siri without the user building a shortcut.
