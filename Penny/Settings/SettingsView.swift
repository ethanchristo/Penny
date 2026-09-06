//
//  SettingsView.swift
//  Penny
//
//  Created by Ethan Christo on 12/25/25.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("currency_code", store: .group) private var currencyCode: String = "USD"
    @AppStorage("currency_symbol", store: .group) private var currencySymbol: String = "$"
    @AppStorage("Home Time Range", store: .group) private var selectedTimeRange: HomeTimeRange = .monthly
    @AppStorage("user_theme") private var currentTheme: AppTheme = .system
    @AppStorage("user_yellow_threshhold", store: .group) private var yellowThreshold: Double = 100.0
    @AppStorage("savings_total", store: .group) private var savingsTotal: Bool = false
    @AppStorage("pay_period_anchor", store: .group) private var payPeriodAnchor: Double = 0
    @AppStorage("pay_period_cadence", store: .group) private var payPeriodCadence: PayPeriodCadence = .biweekly
    @AppStorage("pay_period_grace_days", store: .group) private var payPeriodGraceDays: Int = 2
    // When on, the payday auto-tracks the latest Payroll-categorized transaction.
    @AppStorage("pay_period_track_payroll", store: .group) private var payPeriodTrackPayroll: Bool = true
    // When on, the all-time net total also counts recurring transactions due before the
    // next predicted payday (next week / two weeks / month, per pay cadence).
    @AppStorage("net_total_include_upcoming", store: .group) private var includeUpcoming: Bool = true
    // How credit cards count against the net total: their full outstanding balance
    // (Total Balance) or just the last closed statement's amount due (Amount Due).
    @AppStorage("net_total_credit_mode", store: .group) private var creditMode: CreditCardBalanceType = .balance
    // When off (default), each card's manually entered installment-plan balance
    // (e.g. Apple Card Monthly Installments) is subtracted out of its net total
    // contribution, since bank-sync balances lump it in with the rest of the card.
    @AppStorage("include_installment_balance", store: .group) private var includeInstallmentBalance: Bool = false
    @AppStorage("show_insights") private var showInsights: Bool = true
    // Controls whether the first-launch onboarding flow is shown. Resetting it
    // re-presents onboarding on the next app launch.
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding: Bool = false

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL
    
    @State private var currency: [String] = ["US Dollar", "USD", "$"]
    @State private var yellowNumberSheet = false
    // The payday detected from the latest Payroll transaction, refreshed on appear.
    // Drives the read-only display when tracking is on so it never shows a stale/today value.
    @State private var detectedPayday: Date?

    var body: some View {
        let currencyCodes = allCurrencies()

        List {
            Section("General") {
                Picker(selection: $currency) {
                    ForEach(currencyCodes, id: \.self) { code in
                        Text(code[0]).tag(code)
                    }
                } label: {
                    Label("Currency", systemImage: "globe")
                }
                .foregroundStyle(.primary)
                .tint(.secondary)
                
                Picker(selection: $currentTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                } label: {
                    Label("Theme", systemImage: "moon")
                }
                .foregroundStyle(.primary)
                .tint(.secondary)
                
                NavigationLink {
                    DecimalPadSettingsView()
                } label: {
                    Label("Decimal Pad Type", systemImage: "circle.grid.3x3")
                }
                .foregroundStyle(.primary)
            }
            
            Section {
                NavigationLink {
                    CardsAndAccountsView()
                } label: {
                    Label("Cards & Accounts", systemImage: "creditcard")
                }
                .foregroundStyle(.primary)
                
                NavigationLink {
                    CategoryView()
                } label: {
                    Label("Categories", systemImage: "tag")
                }
                .foregroundStyle(.primary)
                
                NavigationLink {
                    BudgetSettingsView()
                } label: {
                    Label("Budgets", systemImage: "rectangle.grid.2x2")
                }
                .foregroundStyle(.primary)
            }
            
            Section("Home Tab") {
                NavigationLink {
                    netTotalSettings
                } label: {
                    Text("Net Total")
                }
                
                NavigationLink {
                    homeTxWindowSettings
                } label: {
                    Text("Transaction Window")
                }
                
                Toggle("Show Insights", isOn: $showInsights)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            }

            Section("Data") {
                NavigationLink {
                    ImportTransactionsView()
                } label: {
                    Label("Bank Sync", systemImage: "receipt")
                }
                .foregroundStyle(.primary)
                
                NavigationLink {
                    ImportFileView()
                } label: {
                    Label("Import CSV file (coming soon)", systemImage: "plus.rectangle.on.folder")
                }
                .foregroundStyle(.primary)
                
                Button {
                    
                } label: {
                    Label("Export Data (coming soon)", systemImage: "arrow.up.folder")
                }
                .foregroundStyle(.primary)
            }
            
            Section {
                Button("Report Bug", systemImage: "ladybug") {
                    // 2. Set up your email, subject, and body
                    let email = "pennybudgetapp@gmail.com"
                    let subject = "Penny App Bug"
                    let body = "Hi Ethan,\n\nI have a bug to report..."
                    
                    // 3. Encode the strings so spaces and special characters don't break the URL
                    let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    
                    // 4. Create the final mailto URL
                    let urlString = "mailto:\(email)?subject=\(encodedSubject)&body=\(encodedBody)"
                    
                    // 5. Open the Mail app
                    if let url = URL(string: urlString) {
                        openURL(url)
                    }
                }
                .foregroundStyle(.primary)

                Button("Request Feature", systemImage: "envelope") {
                    // 2. Set up your email, subject, and body
                    let email = "pennybudgetapp@gmail.com"
                    let subject = "Penny App Suggestion"
                    let body = "Hi Ethan,\n\nI have some feedback about the app..."
                    
                    // 3. Encode the strings so spaces and special characters don't break the URL
                    let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    
                    // 4. Create the final mailto URL
                    let urlString = "mailto:\(email)?subject=\(encodedSubject)&body=\(encodedBody)"
                    
                    // 5. Open the Mail app
                    if let url = URL(string: urlString) {
                        openURL(url)
                    }
                }
                .foregroundStyle(.primary)

                Button("Reset Onboarding", systemImage: "arrow.counterclockwise") {
                    hasCompletedOnboarding = false
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Other")
            } footer: {
                Text("""
                    
                    Created with love by Ethan Christo 💖
                    
                    Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    
                """)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            if let match = allCurrencies().first(where: { $0[1] == currencyCode }) {
                currency = match
            }
            // Refresh the auto-tracked payday from the latest Payroll transaction so the
            // Last Payday field is current the moment Settings opens.
            syncPayrollPayPeriodAnchor()
            detectedPayday = latestPayrollDate()
        }
        .onChange(of: payPeriodTrackPayroll) {
            // Re-detect when the user flips tracking on, and re-anchor immediately.
            syncPayrollPayPeriodAnchor()
            detectedPayday = latestPayrollDate()
        }
        .onChange(of: currency) {
            saveCurrency()
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "xmark")
                }
            }
        }
    }

    
    @ViewBuilder
    private var netTotalSettings: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(currencySymbol)
                        .foregroundStyle(Color.secondary)
                        .font(.title)
                    
                    TextField("Enter a threshold", value: $yellowThreshold, format: .number)
                        .keyboardType(.decimalPad)
                        .font(.largeTitle)
                }
            } header: {
                Text("Yellow Threshold")
            } footer: {
                Text("Changing this number will affect when the home tab's background is set to yellow.")
            }
            
            Section {
                Toggle("Include Upcoming Recurring", isOn: $includeUpcoming)

                Toggle("Include Savings", isOn: $savingsTotal)

                Toggle("Include Installment Balances", isOn: $includeInstallmentBalance)
            } footer: {
                Text("When off, each card's installment plan balance (set per-card in Cards & Accounts) is left out of the net total.")
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))

            Section {
                Picker(selection: $creditMode) {
                    ForEach([CreditCardBalanceType.balance, .statement]) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Label("Credit Card Mode", systemImage: "creditcard")
                }
                .foregroundStyle(.primary)
                .tint(.secondary)
            } footer: {
                Text("Total Balance subtracts each card's full outstanding balance; Amount Due subtracts only the last closed statement's balance. When SimpleFIN is connected, its reported balance is used, falling back to your transactions.")
            }
        }
        .navigationTitle("Net Total")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private var homeTxWindowSettings: some View {
        Form {
            Picker(selection: $selectedTimeRange) {
                ForEach(HomeTimeRange.allCases) { range in
                    Text(range.rawValue)
                        .tag(range)
                }
            } label: {
                Label("Time Range", systemImage: "calendar.day.timeline.left")
            }
            .tint(.secondary)
            
            if selectedTimeRange == .payPeriod {
                payPeriodSettings
            }
        }
        .foregroundStyle(.primary)
        .navigationTitle("Transaction Window")
        .navigationBarTitleDisplayMode(.inline)
    }
    /// Payday, cadence, and grace controls for the "Pay Period" range. Extracted
    /// from `body` so the Home Tab section stays within the SwiftUI type-checker's
    /// budget (the inline conditional pushed it over).
    @ViewBuilder
    private var payPeriodSettings: some View {
        Toggle("Track Payroll Category", systemImage: "dollarsign.arrow.circlepath", isOn: $payPeriodTrackPayroll)
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))

        if payPeriodTrackPayroll {
            // Auto-tracked: show the detected payday read-only, or say plainly when
            // none was found instead of silently showing today's date.
            if let detectedPayday {
                LabeledContent {
                    Text(detectedPayday, format: .dateTime.month(.abbreviated).day().year())
                } label: {
                    Label("Last Payday", systemImage: "calendar")
                }
            } else {
                Label("No Payroll transaction found", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        } else {
            // Manual: let the user pick the payday directly.
            DatePicker(selection: payPeriodAnchorDate, displayedComponents: .date) {
                Label("Last Payday", systemImage: "calendar")
            }
        }

        Picker(selection: $payPeriodCadence) {
            ForEach(PayPeriodCadence.allCases) { cadence in
                Text(cadence.rawValue).tag(cadence)
            }
        } label: {
            Label("Pay Frequency", systemImage: "arrow.triangle.2.circlepath")
        }
        .tint(.secondary)

        Stepper(value: $payPeriodGraceDays, in: 0...5) {
            Label("Payday Grace: \(payPeriodGraceDays) day\(payPeriodGraceDays == 1 ? "" : "s")", systemImage: "clock.arrow.circlepath")
        }
    }

    /// Label for the grace stepper, pluralized. Kept out of `body` so the row's
    /// expression stays within the SwiftUI type-checker's budget.

    /// Bridges the `Double`-backed `payPeriodAnchor` store to the `DatePicker`,
    /// normalizing to the start of the chosen day and defaulting to today when unset.
    private var payPeriodAnchorDate: Binding<Date> {
        Binding(
            get: { payPeriodAnchor > 0 ? Date(timeIntervalSince1970: payPeriodAnchor) : Date.now.startOfDay },
            set: { payPeriodAnchor = $0.startOfDay.timeIntervalSince1970 }
        )
    }

    private func allCurrencies() -> [[String]] {
        let displayLocale = Locale.current
        let currencyCodes = Locale.commonISOCurrencyCodes
        
        // 1. Build a quick lookup dictionary of all regional currency symbols
        let symbolLookup: [String: String] = {
            var lookup: [String: String] = [:]
            for identifier in Locale.availableIdentifiers {
                let locale = Locale(identifier: identifier)
                
                if let code = locale.currency?.identifier, let symbol = locale.currencySymbol {
                    // If we find multiple formats for a currency, keep the absolute shortest one
                    // (This brilliantly forces "US$" to become just "$")
                    if let existing = lookup[code] {
                        if symbol.count < existing.count {
                            lookup[code] = symbol
                        }
                    } else {
                        lookup[code] = symbol
                    }
                }
            }
            return lookup
        }()
        
        let currencies = currencyCodes.map { code -> [String] in
            // 2. Get the readable name (e.g., "US Dollar")
            let name = displayLocale.localizedString(forCurrencyCode: code) ?? code
            
            // 3. Grab our clean, regional symbol from the dictionary
            let symbol = symbolLookup[code] ?? code
            
            return [name, code, symbol]
        }
        
        // 4. Sort the final list alphabetically by the currency's name
        return currencies.sorted { $0[0] < $1[0] }
    }
    
    private func saveCurrency() -> Void {
        // 4. Update the save indexes to match the new 3-item structure
        currencyCode = currency[1]
        currencySymbol = currency[2]
    }
}
