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
    case insights
    case funds
    
    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .netTotal:
            return "Net Total"
        case .budget:
            return "Budget"
        case .insights:
            return "Insights"
        case .funds:
            return "Funds"
        }
    }
}

struct OnboardingView: View {
    @State private var currentPage = 0
    
    var body: some View {
        VStack {
            TabView(selection: $currentPage) {
                ForEach(OnboardingPage.allCases, id: \.self) { page in
                    pageView(for: page)
                }
            }
        }
    }
    
    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        EmptyView()
    }
}

#Preview {
    OnboardingView()
}
