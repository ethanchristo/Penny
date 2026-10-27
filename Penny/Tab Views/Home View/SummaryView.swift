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
        let route: Route
    }

    /// Where a tile goes when tapped.
    private enum Route: Hashable {
        case categoryBudget(Category)
        case freestandingBudget(Budget)
        case categorySpending(Category)
    }

    @Namespace private var namespace
    @State private var navRoute: Route?

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
                                  overspent: true,
                                  route: budget.category.map { .categoryBudget($0) } ?? .freestandingBudget(budget)))
        }

        // Top three categories by spend in the selected range, skipping overspent ones.
        let slices = categorySpendData(transactions: transactions,
                                       categories: categories,
                                       window: windowBounds(for: selectedTimeRange, offset: 0))
        let spent = slices
            .sorted { $0.amount > $1.amount }
            .filter { !overspentCategories.contains($0.category.persistentModelID) }
            .prefix(3)
            .map { Tile(id: $0.category.persistentModelID, symbol: $0.category.symbol,
                        color: $0.category.color, amount: $0.amount, overspent: false,
                        route: .categorySpending($0.category)) }

        return overspent + spent
    }

    var body: some View {
        HStack {
            ForEach(tiles) { tile in
                Button {
                    navRoute = tile.route
                } label: {
                    summaryTile(symbol: tile.symbol, color: tile.color,
                                amount: tile.amount, overspent: tile.overspent)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: tile.id, in: namespace)
            }
        }
        .navigationDestination(item: $navRoute) { route in
            destination(for: route)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .categoryBudget(let category):
            BudgetInsightsView(namespace: namespace,
                               source: .category(category, filter: categoriedTransactions(for: transactions, with: category)))
        case .freestandingBudget(let budget):
            FreestandingBudgetInsightsView(budget: budget, namespace: namespace)
        case .categorySpending(let category):
            CategorySpendingView(category: category,
                                 transactions: categoriedTransactions(for: transactions, with: category),
                                 selectedTimeRange: selectedTimeRange)
        }
    }
    
    private func summaryTile(symbol: String, color: Color, amount: Double, overspent: Bool) -> some View {
        HStack {
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
//            .padding(.leading, 10)
        }
        .padding(12)
        .glassEffect()
    }
    
    func formatToThreeDigits(_ value: Double) -> String {
        var amount = ""
        if value >= 1000 {
            amount = amountTruncation(for: value)
        }
        // If the number is 100 or greater, show it as an integer with no decimals (e.g., 300)
        else if value >= 100 {
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
