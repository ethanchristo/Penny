//
//  OnboardingView.swift
//  Penny
//
//  Created by Ethan Christo on 6/18/26.
//

import SwiftData
import SwiftUI

enum OnboardingPage: Int, CaseIterable {
    case netTotal
    case categories
    case budgets
    case insights
    case housing
    case simpleFIN
    case financeKit

    var title: String {
        switch self {
        case .netTotal:
            return "Net Total"
        case .categories:
            return "Categories"
        case .budgets:
            return "Pre-Funded & One-Time Budgets"
        case .insights:
            return "Insights"
        case .housing:
            return "Housing"
        case .simpleFIN:
            return "Connect Your Bank"
        case .financeKit:
            return "Apple Wallet"
        }
    }

    var subtitle: String {
        switch self {
        case .netTotal:
            return "Your net total is what you actually have to spend. Penny starts with your checking balance, then subtracts credit card balances, upcoming recurring payments, and money you've set aside, so the number on the Home tab is real."
        case .categories:
            return "Every transaction gets a category, like Groceries, Dining, or Payroll. Categories power your budgets and insights, and you can add rules so imported transactions get sorted automatically."
        case .budgets:
            return "Pre-funded budgets set money aside up front and you spend it down. That money comes out of your net total right away, so you don't spend it twice. Budgets without pre-funding work the other way: you contribute toward a goal over time. One-time budgets cover a set date range, like a trip, instead of resetting every month."
        case .insights:
            return "See where your money goes with breakdowns of cash flow, spending by category, and recurring charges, so you can spot trends before they surprise you."
        case .housing:
            return "Add your rent or mortgage so upcoming payments count against your net total before they're due. You can always change this later in Settings."
        case .simpleFIN:
            return "SimpleFIN securely imports transactions and balances from your bank and credit cards. It costs $1.50 a month or $15 a year, and your bank login never touches Penny."
        case .financeKit:
            return "Connect Apple Card, Apple Cash, Apple Savings, and other cards in your Wallet. Everything stays on your device."
        }
    }

    /// Name of the screenshot asset shown on this page. Add these to the asset
    /// catalog. Until then, a placeholder is shown in their place.
    var imageName: String {
        switch self {
        case .netTotal:
            return "onboarding_net_total"
        case .categories:
            return "onboarding_categories"
        case .budgets:
            return "onboarding_budgets"
        case .insights:
            return "onboarding_insights"
        case .housing:
            return "onboarding_housing"
        case .simpleFIN:
            return "onboarding_simplefin"
        case .financeKit:
            return "onboarding_financekit"
        }
    }

    /// SF Symbol used in the placeholder while the screenshot is missing.
    var fallbackSymbol: String {
        switch self {
        case .netTotal:
            return "dollarsign.circle"
        case .categories:
            return "tag"
        case .budgets:
            return "banknote"
        case .insights:
            return "chart.bar.xaxis"
        case .housing:
            return "house"
        case .simpleFIN:
            return "icloud.and.arrow.down"
        case .financeKit:
            return "wallet.bifold"
        }
    }

    /// Pages that let the user set something up (or skip it) rather than just
    /// explaining a feature.
    var isSetup: Bool {
        switch self {
        case .housing, .simpleFIN, .financeKit:
            return true
        default:
            return false
        }
    }

    var isLast: Bool {
        self == OnboardingPage.allCases.last
    }
}

struct OnboardingView: View {
    /// Marks onboarding as seen so it isn't shown again on later launches.
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false

    @Environment(\.dismiss) private var dismiss

    @Query private var housing: [Housing]

    @State private var currentPage = OnboardingPage.netTotal.rawValue
    // Bank-sync configs live in UserDefaults and aren't observable, so they're
    // re-read whenever the pager reappears (e.g. after returning from setup).
    @State private var simpleFINConnected = SimpleFINConfig.isConfigured
    @State private var financeKitConnected = FinanceKitConfig.isConfigured

    private var page: OnboardingPage {
        OnboardingPage(rawValue: currentPage) ?? .netTotal
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(OnboardingPage.allCases, id: \.self) { page in
                        pageView(for: page)
                            .tag(page.rawValue)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)

                pageIndicator

                Button(action: advance) {
                    Text(primaryButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                simpleFINConnected = SimpleFINConfig.isConfigured
                financeKitConnected = FinanceKitConfig.isConfigured
            }
        }
    }

    /// "Skip" on setup pages that haven't been completed, otherwise "Continue",
    /// with "Get Started" on the final page.
    private var primaryButtonTitle: String {
        if page.isSetup && !isComplete(page) {
            return page.isLast ? "Skip & Get Started" : "Skip"
        }
        return page.isLast ? "Get Started" : "Continue"
    }

    private func isComplete(_ page: OnboardingPage) -> Bool {
        switch page {
        case .housing:
            return !housing.isEmpty
        case .simpleFIN:
            return simpleFINConnected
        case .financeKit:
            return financeKitConnected
        default:
            return true
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: item == page ? 20 : 8, height: 8)
                    .animation(.easeInOut, value: currentPage)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            screenshotArea(for: page)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            if page.isSetup {
                setupAction(for: page)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    /// Displays the page's screenshot, falling back to a phone-shaped
    /// placeholder while the artwork hasn't been added yet. Fills whatever
    /// vertical space the text leaves over.
    @ViewBuilder
    private func screenshotArea(for page: OnboardingPage) -> some View {
        Group {
            if UIImage(named: page.imageName) != nil {
                Image(page.imageName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28))
            } else {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.secondary.opacity(0.12))
                    .aspectRatio(9 / 19.5, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: page.fallbackSymbol)
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Text("Screenshot")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    /// The button that opens the relevant setup screen, or a confirmation once
    /// it's been set up.
    @ViewBuilder
    private func setupAction(for page: OnboardingPage) -> some View {
        VStack(spacing: 8) {
            NavigationLink {
                switch page {
                case .housing:
                    HousingView()
                case .simpleFIN:
                    SimpleFinSetupView()
                default:
                    FinanceKitSetupView()
                }
            } label: {
                Label(setupButtonTitle(for: page), systemImage: page.fallbackSymbol)
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if isComplete(page) {
                Label(setupStatus(for: page), systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private func setupButtonTitle(for page: OnboardingPage) -> String {
        switch page {
        case .housing:
            return housing.isEmpty ? "Set Up Housing" : "Manage Housing"
        case .simpleFIN:
            return simpleFINConnected ? "Manage SimpleFIN" : "Register with SimpleFIN"
        default:
            return financeKitConnected ? "Manage Apple Wallet" : "Connect Apple Wallet"
        }
    }

    private func setupStatus(for page: OnboardingPage) -> String {
        switch page {
        case .housing:
            return "\(housing.count) housing payment\(housing.count == 1 ? "" : "s") added"
        case .simpleFIN:
            return "SimpleFIN connected"
        default:
            return "Apple Wallet connected"
        }
    }

    private func advance() {
        if page.isLast {
            hasCompletedOnboarding = true
            dismiss()
        } else {
            withAnimation {
                currentPage += 1
            }
        }
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: [Housing.self], inMemory: true)
}
