//
//  BudgetSummaryConfig.swift
//  Penny
//
//  Created by Ethan Christo on 9/14/26.
//

import SwiftUI

/// Configuration for customizing the budget summary display in HomeView.
@Observable
final class BudgetSummaryConfig {
    /// Singleton instance for app-wide access.
    static let shared = BudgetSummaryConfig()
    
    // MARK: - Display Options
    
    /// Whether to show the overall budget section.
    var showOverallBudget: Bool {
        get { access(keyPath: \.showOverallBudget); return _showOverallBudget }
        set { withMutation(keyPath: \.showOverallBudget) { _showOverallBudget = newValue } }
    }
    private var _showOverallBudget = true
    
    /// Whether to show the overspent budgets section.
    var showOverspent: Bool {
        get { access(keyPath: \.showOverspent); return _showOverspent }
        set { withMutation(keyPath: \.showOverspent) { _showOverspent = newValue } }
    }
    private var _showOverspent = true
    
    /// Whether to show the underspent budgets section.
    var showUnderspent: Bool {
        get { access(keyPath: \.showUnderspent); return _showUnderspent }
        set { withMutation(keyPath: \.showUnderspent) { _showUnderspent = newValue } }
    }
    private var _showUnderspent = true
    
    // MARK: - Filtering Options
    
    /// Minimum overspend amount to display (in base currency). Budgets overspent by less
    /// than this threshold will be hidden.
    var overspentThreshold: Double {
        get { access(keyPath: \.overspentThreshold); return _overspentThreshold }
        set { withMutation(keyPath: \.overspentThreshold) { _overspentThreshold = newValue } }
    }
    private var _overspentThreshold = 0.0
    
    /// Maximum number of overspent budgets to display. Set to 0 for unlimited.
    var maxOverspentItems: Int {
        get { access(keyPath: \.maxOverspentItems); return _maxOverspentItems }
        set { withMutation(keyPath: \.maxOverspentItems) { _maxOverspentItems = newValue } }
    }
    private var _maxOverspentItems = 0
    
    /// Maximum number of underspent budgets to display. Set to 0 for unlimited.
    var maxUnderspentItems: Int {
        get { access(keyPath: \.maxUnderspentItems); return _maxUnderspentItems }
        set { withMutation(keyPath: \.maxUnderspentItems) { _maxUnderspentItems = newValue } }
    }
    private var _maxUnderspentItems = 3
    
    // MARK: - Sorting Options
    
    enum SortOrder: String, CaseIterable, Identifiable {
        case amountDescending = "Amount (High to Low)"
        case amountAscending = "Amount (Low to High)"
        case nameAscending = "Name (A to Z)"
        case nameDescending = "Name (Z to A)"
        
        var id: String { rawValue }
    }
    
    /// How to sort overspent budgets.
    var overspentSortOrder: SortOrder {
        get { access(keyPath: \.overspentSortOrder); return _overspentSortOrder }
        set { withMutation(keyPath: \.overspentSortOrder) { _overspentSortOrder = newValue } }
    }
    private var _overspentSortOrder: SortOrder = .amountDescending
    
    /// How to sort underspent budgets.
    var underspentSortOrder: SortOrder {
        get { access(keyPath: \.underspentSortOrder); return _underspentSortOrder }
        set { withMutation(keyPath: \.underspentSortOrder) { _underspentSortOrder = newValue } }
    }
    private var _underspentSortOrder: SortOrder = .amountDescending
    
    // MARK: - Visual Options
    
    /// Whether to show the progress bar in the overall budget section.
    var showProgressBar: Bool {
        get { access(keyPath: \.showProgressBar); return _showProgressBar }
        set { withMutation(keyPath: \.showProgressBar) { _showProgressBar = newValue } }
    }
    private var _showProgressBar = true
    
    /// Whether to show category/budget symbols/emojis.
    var showSymbols: Bool {
        get { access(keyPath: \.showSymbols); return _showSymbols }
        set { withMutation(keyPath: \.showSymbols) { _showSymbols = newValue } }
    }
    private var _showSymbols = true
    
    /// Whether to show section subtotals.
    var showSubtotals: Bool {
        get { access(keyPath: \.showSubtotals); return _showSubtotals }
        set { withMutation(keyPath: \.showSubtotals) { _showSubtotals = newValue } }
    }
    private var _showSubtotals = true
    
    // MARK: - Helper Methods
    
    /// Applies the configured sort order to a list of budget items.
    func sort(_ items: [(symbol: String, name: String, amount: Double)], using order: SortOrder) -> [(symbol: String, name: String, amount: Double)] {
        switch order {
        case .amountDescending:
            return items.sorted { $0.amount > $1.amount }
        case .amountAscending:
            return items.sorted { $0.amount < $1.amount }
        case .nameAscending:
            return items.sorted { $0.name < $1.name }
        case .nameDescending:
            return items.sorted { $0.name > $1.name }
        }
    }
    
    /// Filters and limits items based on configuration.
    func filterAndLimit(_ items: [(symbol: String, name: String, amount: Double)], maxItems: Int, threshold: Double = 0) -> [(symbol: String, name: String, amount: Double)] {
        var filtered = items.filter { $0.amount > threshold }
        if maxItems > 0 {
            filtered = Array(filtered.prefix(maxItems))
        }
        return filtered
    }
    
    /// Resets all settings to their defaults.
    func resetToDefaults() {
        _showOverallBudget = true
        _showOverspent = true
        _showUnderspent = true
        _overspentThreshold = 0.0
        _maxOverspentItems = 0
        _maxUnderspentItems = 3
        _overspentSortOrder = .amountDescending
        _underspentSortOrder = .amountDescending
        _showProgressBar = true
        _showSymbols = true
        _showSubtotals = true
    }
}
