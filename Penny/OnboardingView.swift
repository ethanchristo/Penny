//
//  OnboardingView.swift
//  Penny
//
//  Created by Ethan Christo on 6/18/26.
//

import SwiftData
import SwiftUI

enum OnboardingPage: Int, CaseIterable {
    case overview
    case budgets
    case housing
    case insights
    case connect

    var title: String {
        switch self {
        case .overview:
            return "Welcome to Penny"
        case .budgets:
            return "Budgets That Work"
        case .housing:
            return "Housing"
        case .insights:
            return "Know Where It Goes"
        case .connect:
            return "Connect Your Accounts"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return "Penny shows what you can actually spend, not just what's in your account."
        case .budgets:
            return "Set money aside for what matters and watch it work for you."
        case .housing:
            return "Add your rent or mortgage so upcoming payments count against your net total before they're due."
        case .insights:
            return "Clear breakdowns that help you spot trends before they surprise you."
        case .connect:
            return "Bring in your transactions automatically. You can always do this later in Settings."
        }
    }

    var symbol: String {
        switch self {
        case .overview:
            return "dollarsign.circle.fill"
        case .budgets:
            return "banknote.fill"
        case .housing:
            return "house.fill"
        case .insights:
            return "chart.bar.xaxis"
        case .connect:
            return "link.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview:
            return .green
        case .budgets:
            return .orange
        case .housing:
            return .teal
        case .insights:
            return .purple
        case .connect:
            return .blue
        }
    }

    var features: [OnboardingFeature] {
        switch self {
        case .overview:
            return [
                OnboardingFeature(
                    symbol: "dollarsign.circle",
                    title: "Net Total",
                    detail: "Starts with your checking balance, then subtracts credit card balances, upcoming recurring payments, and money you've set aside."
                ),
                OnboardingFeature(
                    symbol: "tag",
                    title: "Categories",
                    detail: "Every transaction gets a category, and rules sort imported ones automatically."
                )
            ]
        case .budgets:
            return [
                OnboardingFeature(
                    symbol: "lock.fill",
                    title: "Pre-Funded",
                    detail: "Choose whether money is set aside up front and comes out of your net total right away, so you don't spend it twice."
                ),
                OnboardingFeature(
                    symbol: "target",
                    title: "Goals",
                    detail: "Budgets without pre-funding work the other way. You contribute toward a goal over time."
                ),
                OnboardingFeature(
                    symbol: "calendar",
                    title: "One-Time",
                    detail: "Set a date range if you want to for a single event, like a trip."
                )
            ]
        case .insights:
            return [
                OnboardingFeature(
                    symbol: "arrow.left.arrow.right",
                    title: "Cash Flow",
                    detail: "See what's coming in and going out over time."
                ),
                OnboardingFeature(
                    symbol: "chart.pie",
                    title: "Spending by Category",
                    detail: "Find out which categories take the biggest share."
                ),
                OnboardingFeature(
                    symbol: "repeat",
                    title: "Recurring Charges",
                    detail: "Keep track of subscriptions and bills."
                )
            ]
        case .housing:
            return [
                OnboardingFeature(
                    symbol: "calendar.badge.clock",
                    title: "Counted Early",
                    detail: "Upcoming housing payments are subtracted from your net total before they're due."
                ),
                OnboardingFeature(
                    symbol: "gearshape",
                    title: "Change It Anytime",
                    detail: "You can edit or add housing payments later in Settings."
                )
            ]
        case .connect:
            return []
        }
    }

    var isLast: Bool {
        self == OnboardingPage.allCases.last
    }
}

struct OnboardingFeature: Identifiable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { title }
}

struct OnboardingView: View {
    /// Marks onboarding as seen so it isn't shown again on later launches.
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false

    @Environment(\.dismiss) private var dismiss

    @Query private var housing: [Housing]

    @State private var currentPage = OnboardingPage.overview.rawValue
    // Bank-sync configs live in UserDefaults and aren't observable, so they're
    // re-read whenever the pager reappears (e.g. after returning from setup).
    @State private var simpleFINConnected = SimpleFINConfig.isConfigured
    @State private var financeKitConnected = FinanceKitConfig.isConfigured

    private var page: OnboardingPage {
        OnboardingPage(rawValue: currentPage) ?? .overview
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background

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
                    .tint(page.tint)
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                // Measure the bottom padding from the screen edge rather than above the
                // home indicator, so the button sits as low as its side margins.
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                simpleFINConnected = SimpleFINConfig.isConfigured
                financeKitConnected = FinanceKitConfig.isConfigured
            }
        }
    }

    /// A soft tinted backdrop that shifts color with the page, giving the glass
    /// something to refract.
    private var background: some View {
        LinearGradient(
            colors: [page.tint.opacity(0.35), page.tint.opacity(0.08), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: currentPage)
    }

    /// "Skip" on the connect page until something is connected, otherwise
    /// "Continue", with "Get Started" on the final page.
    private var primaryButtonTitle: String {
        if page.isLast {
            return anythingConnected ? "Get Started" : "Skip & Get Started"
        }
        if page == .housing {
            return housing.isEmpty ? "Skip" : "Continue"
        }
        return "Continue"
    }

    private var anythingConnected: Bool {
        simpleFINConnected || financeKitConnected
    }

    private var pageIndicator: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(OnboardingPage.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == page ? page.tint : Color.secondary.opacity(0.3))
                        .frame(width: item == page ? 20 : 8, height: 8)
                        .animation(.easeInOut, value: currentPage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.top, 8)
    }

    private func pageView(for page: OnboardingPage) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                header(for: page)

                if page == .connect {
                    connectCards
                } else {
                    featureCards(for: page)
                }

                if page == .housing {
                    housingAction
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func header(for page: OnboardingPage) -> some View {
        VStack(spacing: 16) {
            Image(systemName: page.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(page.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular.tint(page.tint.opacity(0.2)), in: .circle)

            Text(page.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(page.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureCards(for page: OnboardingPage) -> some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                ForEach(page.features) { feature in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: feature.symbol)
                            .font(.title2)
                            .foregroundStyle(page.tint)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                }
            }
        }
    }

    private var housingAction: some View {
        VStack(spacing: 8) {
            NavigationLink {
                HousingView()
            } label: {
                Label(housing.isEmpty ? "Set Up Housing" : "Manage Housing", systemImage: "house")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            if !housing.isEmpty {
                Label("\(housing.count) housing payment\(housing.count == 1 ? "" : "s") added", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private var connectCards: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                connectCard(
                    symbol: "icloud.and.arrow.down",
                    title: "SimpleFIN",
                    detail: "Securely imports transactions and balances from your bank and credit cards. It costs $1.50 a month or $15 a year, and your bank login never touches Penny.",
                    isConnected: simpleFINConnected,
                    connectTitle: "Register with SimpleFIN",
                    manageTitle: "Manage SimpleFIN"
                ) {
                    SimpleFinSetupView()
                }

                connectCard(
                    symbol: "wallet.bifold",
                    title: "Apple Wallet",
                    detail: "Connect Apple Card, Apple Cash, Apple Savings, and other cards in your Wallet. Everything stays on your device.",
                    isConnected: financeKitConnected,
                    connectTitle: "Connect Apple Wallet",
                    manageTitle: "Manage Apple Wallet"
                ) {
                    FinanceKitSetupView()
                }
            }
        }
    }

    private func connectCard<Destination: View>(
        symbol: String,
        title: String,
        detail: String,
        isConnected: Bool,
        connectTitle: String,
        manageTitle: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(OnboardingPage.connect.tint)
                    .frame(width: 32)

                Text(title)
                    .font(.headline)

                Spacer(minLength: 0)

                if isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink(destination: destination) {
                Text(isConnected ? manageTitle : connectTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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
