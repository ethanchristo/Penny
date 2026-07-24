//
//  DecimalPadSettingsView.swift
//  Penny
//
//  Created by Ethan Christo on 4/29/26.
//

import SwiftUI

struct DecimalPadSettingsView: View {
    @AppStorage("decimal_pad_type") private var decimalPadType: DecimalPadType = .ATM
    
    @State private var amount: String = "0.00"
        
    private var footer: String {
        switch decimalPadType {
        case .ATM:
            "Automatically inserts a decimal point as you type."
        case .decimal:
            "Requires you to manually enter a decimal point."
        }
    }

    var body: some View {
        VStack {
            Section {
                Picker("Decimal Pad Type", selection: $decimalPadType) {
                    ForEach(DecimalPadType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
            } footer: {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Color(.label))
            }
            .padding(.top)
            
            Spacer()
            
            HStack(spacing: 0) {
                Text("$")
                    .foregroundStyle(Color.secondary)
                
                Text(amount)
            }
            .font(.largeTitle.bold())
            .lineLimit(1)
            
            Spacer()
            
            LazyVGrid(columns: Array(repeating: GridItem(), count: 3)) {
                ForEach(1...9, id: \.self) { index in
                    Button {
                        handleInput(for: String(index))
                    } label: {
                        Text("\(index)")
                            .font(.title.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                            .glassEffect(.regular.interactive())
                    }
                }
                if decimalPadType == .ATM {
                    Spacer()
                } else {
                    Button {
                        handleInput(for: ".")
                    } label: {
                        Text("•")
                            .font(.title.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                            .glassEffect(.regular.interactive())
                    }
                }
                
                ForEach(["0", "delete.backward.fill"], id: \.self) { string in
                    Button {
                        handleInput(for: string)
                    } label: {
                        Group {
                            if string == "0" {
                                Text("0")
                            } else {
                                Image(systemName: string)
                            }
                        }
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 15)
                        .glassEffect(.regular.interactive())
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .foregroundStyle(.primary)
        .navigationTitle("Decimal Pad Type")
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: decimalPadType, initial: true) {
            switch decimalPadType {
            case .ATM:
                amount = "0.00"
            case .decimal:
                amount = ""
            }
        }
    }
    
    private func handleInput(for input: String) -> Void {
        if decimalPadType == .ATM {
            if input == "delete.backward.fill" {
                var rawDigits = amount.replacingOccurrences(of: ".", with: "")
                
                if !rawDigits.isEmpty {
                    rawDigits.removeLast()
                }
                
                let doubleValue = (Double(rawDigits) ?? 0.0) / 100
                
                amount = String(format: "%.2f", doubleValue)
                
            } else {
                var rawDigits = amount.replacingOccurrences(of: ".", with: "")
                
                rawDigits.append(input)
                
                let doubleValue = (Double(rawDigits) ?? 0.0) / 100
                
                amount = String(format: "%.2f", doubleValue)
            }
        } else {
            if input == "delete.backward.fill" {
                if !amount.isEmpty {
                    amount.removeLast()
                }
                                
            } else {
                amount.append(input)
                
            }
        }
    }
}
