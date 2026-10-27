//
//  AdaptiveSplitLayout.swift
//  Penny
//

import SwiftUI

/// Lays out a detail page's summary (charts, totals) alongside its transaction list.
///
/// In compact width (iPhone, folded iPhone Duo, narrow iPad multitasking) the two
/// stack in one scroll view, summary on top. In regular width (iPad, unfolded
/// iPhone Duo) the summary sits on the left and the transactions on the right,
/// each scrolling on its own. The size class is read from the environment, so
/// the layout switches live as the window is resized or the device is unfolded.
struct AdaptiveSplitLayout<Info: View, Transactions: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Draws the squiggly divider between the two sections when they're stacked.
    /// It's dropped side by side, where the columns already separate them.
    var showsDivider: Bool = false

    @ViewBuilder let info: Info
    @ViewBuilder let transactions: Transactions

    var body: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    info
                }
                .frame(maxWidth: .infinity)

                ScrollView(.vertical, showsIndicators: false) {
                    transactions
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                info

                if showsDivider {
                    SquigglyLine(wavelength: 16, amplitude: 2)
                        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(height: 12) // Height should accommodate the amplitude
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                transactions
            }
        }
    }
}
