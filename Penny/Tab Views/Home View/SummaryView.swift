//
//  SummaryView.swift
//  Penny
//
//  Created by Ethan Christo on 10/24/26.
//

import SwiftData
import SwiftUI

struct SummaryView: View {
    @Query private var budgets: [Budget]
    @Query private var categories: [Category]

    let currencyCode: String
    let transactions: [Transaction]
    let selectedTimeRange: HomeTimeRange

    private struct Tile: Identifiable {
        let id: PersistentIdentifier
        let symbol: String
        let color: Color
        let amount: Double
        let overspent: Bool
    }

    /// Overspent budget tiles followed by the top-spending categories. Built in one
    /// pass so the overspent test is evaluated once per budget, and the same result
    /// both produces the "over" tiles and hides those categories from "spent".
    private var tiles: [Tile] {
        var overspentCategories = Set<PersistentIdentifier>()
        var overspent: [Tile] = []

        let now = Date.now

        for budget in budgets where budget.hasBudget {
            // Skip budgets whose end date has passed.
            if let end = budget.end, end < now { continue }

            let remaining: Double
            if let category = budget.category {
                // Category budgets don't track `transactions`, so `remaining` is always 0.
                // Their spend comes from the category's transactions in the budget window.
                guard budget.amount > 0 else { continue }
                remaining = budget.amount - budgetTotal(for: category, in: transactions, by: 0)
                guard remaining < 0 else { continue }
                overspentCategories.insert(category.persistentModelID)
            } else {
                remaining = budget.remaining
                guard remaining < 0 else { continue }
            }
            overspent.append(Tile(id: budget.persistentModelID,
                                  symbol: budget.displaySymbol,
                                  color: budget.category?.color ?? budget.color,
                                  amount: remaining,
                                  overspent: true))
        }

        // Top three categories by spend in the selected range, skipping overspent ones.
        let slices = categorySpendData(transactions: transactions,
                                       categories: categories,
                                       window: windowBounds(for: selectedTimeRange, offset: 0))
        let spent = slices
            .sorted { $0.amount > $1.amount }
            .map(\.category)
            .filter { !overspentCategories.contains($0.persistentModelID) }
            .prefix(3)
            .map { Tile(id: $0.persistentModelID, symbol: $0.symbol, color: $0.color,
                        amount: 0.01, overspent: false) }

        return overspent + spent
    }

    var body: some View {
        HStack {
            ForEach(tiles) { tile in
                summaryTile(symbol: tile.symbol, color: tile.color,
                            amount: tile.amount, overspent: tile.overspent)
            }
        }
        
    }
    
    private func summaryTile(symbol: String, color: Color, amount: Double, overspent: Bool) -> some View {
        VStack {
            Text(symbol)
                .font(.title)
                .frame(width: 50, height: 50)
                .background(
                    Circle()
                        .fill(color.opacity(0.5).gradient)
                )
                .shadow(color: color, radius: 5)
            
            VStack {
                Text(formatToThreeDigits(abs(amount)))
                    .bold()
                Text(overspent ? "over" : "spent")
                    .font(.caption)
                    .underline()
            }
            .padding(.top, 12)
        }
        .padding(18)
        .glassEffect()
    }
    
    func formatToThreeDigits(_ value: Double) -> String {
        var amount = ""
        // If the number is 100 or greater, show it as an integer with no decimals (e.g., 300)
        if value >= 100 {
            amount = String(format: "%.0f", value)
        }
        // If it's between 10 and 100, we need 1 decimal place to hit 3 digits (e.g., 12.3)
        else if value >= 10 {
            amount = String(format: "%.1f", value)
        }
        // If it's less than 10, we need 2 decimal places (e.g., 0.01 or 5.23)
        else {
            amount = String(format: "%.2f", value)
        }
        
        return "$\(amount)"
    }
}
