//
//  ImportTransactionsView.swift
//  Penny
//
//  Created by Ethan Christo on 5/22/26.
//

import SwiftUI

struct ImportTransactionsView: View {
    @State private var emailImportSheet = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SimpleFinSetupView()
                } label: {
                    Label("SimpleFIN", systemImage: "icloud.and.arrow.down")
                }
            } footer: {
                Text("An open-source API that lets you import transactions from your bank and credit card statements. It costs $1.50 a month or $15 a year to use and you can use it anywhere that accepts SimpleFIN.")
            }
            
            Section {
                NavigationLink {
                    FinanceKitSetupView()
                } label: {
                    Label("Finance Kit", systemImage: "wallet.bifold")
                }
            } footer: {
                Text("Connect Penny to Apple Card, Apple High-Yield Savings Account, Apple Cash, and connected bank cards in your Apple Wallet.")
            }
        }
        .tint(.primary)
        .navigationTitle("Bank Sync")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $emailImportSheet) {
            NavigationStack {
                EmailImportSettingsView()
            }
        }
    }
}
