//
//  OnboardingView.swift
//  Penny
//
//  Created by Ethan Christo on 6/18/26.
//

import SwiftUI

enum OnboardingPage: Int, CaseIterable {
    case welcome
    case netTotal
    case budget
    case funds
    case insights

    var title: String {
        switch self {
        case .welcome:
            return "Welcome to Penny"
        case .netTotal:
            return "Net Total"
        case .budget:
            return "Budgets"
        case .funds:
            return "Funds"
        case .insights:
            return "Insights"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "A simple, private way to track your money and always know where you stand."
        case .netTotal:
            return "See exactly how much money you truly have to spend, with upcoming transactions and card balances factored in."
        case .budget:
            return "Set spending limits by category and watch your progress throughout the month at a glance."
        case .funds:
            return "Set aside money for goals and recurring expenses so it's ready when you need it."
        case .insights:
            return "Understand your spending with clear breakdowns of cash flow, categories, and recurring charges."
        }
    }

    /// Name of the image asset shown on this page. Add these to the asset
    /// catalog — until then a placeholder is shown in their place.
    var imageName: String {
        switch self {
        case .welcome:
            return "onboarding_welcome"
        case .netTotal:
            return "onboarding_net_total"
        case .budget:
            return "onboarding_budget"
        case .funds:
            return "onboarding_funds"
        case .insights:
            return "onboarding_insights"
        }
    }

    /// SF Symbol used as a fallback while the image asset is missing.
    var fallbackSymbol: String {
        switch self {
        case .welcome:
            return "sparkles"
        case .netTotal:
            return "dollarsign.circle"
        case .budget:
            return "chart.pie"
        case .funds:
            return "banknote"
        case .insights:
            return "chart.bar.xaxis"
        }
    }

    var isLast: Bool {
        self == OnboardingPage.allCases.last
    }
}

struct OnboardingView: View {
    /// Marks onboarding as seen so it isn't shown again on later launches.
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false

    @State private var currentPage = OnboardingPage.welcome.rawValue

    private var page: OnboardingPage {
        OnboardingPage(rawValue: currentPage) ?? .welcome
    }

    var body: some View {
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
                Text(page.isLast ? "Get Started" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
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
        VStack(spacing: 32) {
            Spacer()

            imageArea(for: page)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
    }

    /// Displays the page's image asset, falling back to an SF Symbol
    /// placeholder while the artwork hasn't been added yet.
    @ViewBuilder
    private func imageArea(for page: OnboardingPage) -> some View {
        Group {
            if UIImage(named: page.imageName) != nil {
                Image(page.imageName)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: page.fallbackSymbol)
                            .font(.system(size: 64, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
            }
        }
        .frame(maxWidth: 280, maxHeight: 280)
        .padding(.horizontal, 24)
    }

    private func advance() {
        if page.isLast {
            hasCompletedOnboarding = true
        } else {
            withAnimation {
                currentPage += 1
            }
        }
    }
}

#Preview {
    OnboardingView()
}
