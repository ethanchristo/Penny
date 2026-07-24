//
//  FundSettingsView.swift
//  Penny
//
//  Created by Ethan Christo on 6/4/26.
//

import SwiftData
import SwiftUI

struct FundSettingsView: View {
    // NOTE: the persisted UserDefaults key stays "plan_net_total" so existing
    // installs keep their setting; only the Swift property name was renamed.
    @AppStorage("plan_net_total", store: .group) private var fundNetTotal: Bool = true

    @Query(sort: \Fund.name) var funds: [Fund]

    @State private var newFund = false
    @State private var editingFund: Fund?
    
    private var endedFunds: [Fund] {
        funds.filter { $0.end < Date.now.endOfDay }
    }

    private var ongoingFunds: [Fund] {
        funds.filter { $0.end >= Date.now.endOfDay }
    }

    var body: some View {
        List {
            Section {
                Toggle("Use in Net Total", isOn: $fundNetTotal)
            } footer: {
                Text("Use fund contributions and uses in Net Total. Each contribution will be subtracted from the Net Total. If the use is greater than what has been contributed. The difference will also be subtracted from the Net Total.")
            }
            
            if !ongoingFunds.isEmpty {
                Section {
                    ForEach(ongoingFunds) { fund in
                        Button {
                            editingFund = fund
                        } label: {
                            Text(fund.name)
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Ongoing Funds")
                }
            }
            
            if !endedFunds.isEmpty {
                Section {
                    ForEach(endedFunds) { fund in
                        Button {
                            editingFund = fund
                        } label: {
                            Text(fund.name)
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Ended Funds")
                }
            }
        }
        .listRowSpacing(12)
        .navigationTitle("Funds")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFund = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $newFund) {
            NavigationStack {
                EditFundView(fund: nil)
            }
        }
        .sheet(item: $editingFund) { fund in
            NavigationStack {
                EditFundView(fund: fund)
            }
        }
    }
}
