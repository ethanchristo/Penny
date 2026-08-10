//
//  NetTotalWidget.swift
//  NetTotalWidget
//
//  Created by Ethan Christo on 3/24/26.
//

import WidgetKit
import SwiftUI
import SwiftData

// 1. The Data Payload
struct SimpleEntry: TimelineEntry {
    let date: Date
    let netTotal: Double
}

// 2. The Engine that fetches the data
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), netTotal: 1234.56)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date(), netTotal: 1234.56))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        Task { @MainActor in
            // The all-time net total (matching the home tab) is computed off the main
            // thread on the shared background ModelActor.
            let total = await StatsCalculator(modelContainer: SharedDatabase.shared.container)
                .allTimeNetTotals()
                .total

            let entry = SimpleEntry(date: Date(), netTotal: total)
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }
}

// 4. The Plain Text UI
struct PennyWidgetEntryView : View {
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("user_yellow_threshhold", store: .group) private var yellowThreshold: Double = 100.0
    @AppStorage("net_total_credit_mode", store: .group) private var creditMode: CreditCardBalanceType = .balance
    
    @Environment(\.colorScheme) private var colorScheme
    
    var entry: Provider.Entry

    private var background: Color {
        if entry.netTotal <= 0.0 {
            Color(.systemRed)
        } else if entry.netTotal <= yellowThreshold {
            Color(.systemYellow)
        } else {
            Color(.systemGreen)
        }
    }
    
    private var displayTotalColor: Color {
        if colorScheme == .dark {
            background.mix(with: .white, by: 0.6)
        } else {
            background.mix(with: .black, by: 0.6)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            VStack {
                Text("Net Total")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Text(creditMode.title.uppercased())
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Spacer()
            
            Text(amountTruncation(for: entry.netTotal, currencySymbol: currencySymbol))
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(displayTotalColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fontDesign(.rounded)
        .containerBackground(colorScheme == .light ? AnyShapeStyle(background.gradient.opacity(0.7)) : AnyShapeStyle(background.gradient.opacity(0.3)), for: .widget)
    }
}

// 5. The Widget Setup
struct NetTotalWidget: Widget {
    let kind: String = "PennyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            PennyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Net Total")
        .description("Shows your current net total in plain text.")
        .supportedFamilies([.systemSmall])
    }
}
