//
//  EmailImportSettingsView.swift
//  Penny
//
//  Created by Ethan Christo on 3/5/26.
//

import FoundationModels
import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.opal.Penny", category: "emailImport")

struct EmailImportSettingsView: View {
    @AppStorage("googleScriptUrl") private var scriptUrl: String = ""
    @AppStorage("googleScriptSecret") private var scriptSecret: String = ""
    
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    
    @Query var categories: [Category]
    
    @State private var isLoading = false
    @State private var generateScript = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showInstructions = false

    var body: some View {
        Form {
            Section {
                // URL Input
                TextField("Paste Web App URL Here", text: $scriptUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                
                // Secret Password Input
                SecureField("Secret Password", text: $scriptSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
               Text("Import Configuration")
            
            } footer: {
                Text("Input your Google script web app link and unique password to start inporting transactons.")
            }
            
            Section {
                Button {
                    fetchTransactions()
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Import Transactions")
                    }
                }
                // Disable button if either field is empty
                .disabled(scriptUrl.isEmpty || scriptSecret.isEmpty || isLoading)
            } footer: {
                Text("Enter the Web App URL and the Secret Password defined in your Google Script.")
            }
        }
        .navigationTitle("Email Import Settings")
        .toolbarTitleDisplayMode(.inline)
        .alert("Import Status", isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .fileExporter(
            isPresented: $generateScript,
            document: GoogleScriptDocument(),
            contentType: .plainText,
            defaultFilename: "PennyScript.gs"
        ) { result in
            // Handle success or error
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                   showInstructions = true
                } label: {
                    Label("Show Instructions", systemImage: "questionmark")
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            Button {
                generateScript.toggle()
            } label: {
                Text("Generate Script")
            }
            .buttonStyle(.glassProminent)
            .tint(Color(.systemBlue))
            .controlSize(.extraLarge)
            .buttonSizing(.flexible)
            .padding(.horizontal)
        }
        .sheet(isPresented: $showInstructions) {
            EmptyView()
        }
    }
    
    func fetchTransactions() {
        let cleanUrl = scriptUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = scriptSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        let allowedCharacters = CharacterSet.alphanumerics
        guard let encodedSecret = cleanSecret.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            alertMessage = "Failed to encode password."
            showAlert = true
            return
        }

        let separator = cleanUrl.contains("?") ? "&" : "?"
        guard let finalUrl = URL(string: "\(cleanUrl)\(separator)secret=\(encodedSecret)") else {
            alertMessage = "Invalid URL."
            showAlert = true
            return
        }

        isLoading = true

        Task {
            defer { isLoading = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: finalUrl)

                if let jsonString = String(data: data, encoding: .utf8), jsonString.contains("Unauthorized") {
                    alertMessage = "Access Denied. Check your Secret Password."
                    showAlert = true
                    return
                }

                let rawEmails = try JSONDecoder().decode([RawEmailDTO].self, from: data)

                let importedTransactions = await withTaskGroup(of: TransactionDTO?.self) { group in
                    for rawEmail in rawEmails {
                        group.addTask {
                            await extractDataWithAI(from: rawEmail.body, date: rawEmail.date)
                        }
                    }
                    var results: [TransactionDTO] = []
                    for await dto in group {
                        if let dto { results.append(dto) }
                    }
                    return results
                }

                await saveToDatabase(dtos: importedTransactions)

                alertMessage = "Successfully imported \(importedTransactions.count) transactions."
                showAlert = true
            } catch {
                alertMessage = "Error: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }
    
    func saveToDatabase(dtos: [TransactionDTO]) async {
        let formatter = ISO8601DateFormatter()
        
        // 1. Fetch all existing accounts from SwiftData
        var existingAccounts = [Account]()
        do {
            let descriptor = FetchDescriptor<Account>()
            existingAccounts = try modelContext.fetch(descriptor)
        } catch {
            log.error("Failed to fetch existing accounts.")
        }
        
        // 2. Safely grab the Miscellaneous category fallback
        guard let miscCategory = categories.first(where: { $0.name == "Miscellaneous" }) else {
            log.error("Miscellaneous category is missing from the database")
            return
        }
        
        let categoryNames = categories.map { $0.name }
        
        for dto in dtos {
            let actualDate = formatter.date(from: dto.date) ?? Date()
            
            // --- 🚨 NEW CARD AUTO-CATEGORIZATION 🚨 ---
            // Combine all the text from the imported transaction into one searchable string
            let transactionText = "\(dto.name) \(dto.account ?? "")".lowercased()
            
            // Check if any of your real Card names exist anywhere in that text!
            // If it finds a match, it links it. If no names match, it safely stays nil.
            let transactionAccount = existingAccounts.first { account in
                transactionText.contains(account.name.lowercased())
            }
            // ------------------------------------------
            
            // 5. The Hybrid Categorization Logic
            var finalCategory: Category = miscCategory
            
            if let ruleMatchedCategory = findCategoryByRule(for: dto, categories: categories) {
                finalCategory = ruleMatchedCategory
            }
            else if let predictedName = await autoCategorize(text: dto.name, categories: categoryNames) {
                if let matchedCategory = categories.first(where: { $0.name == predictedName }) {
                    finalCategory = matchedCategory
                }
            }
                        
            let newTransaction = Transaction(
                amount: dto.amount,
                date: actualDate,
                account: transactionAccount,
                category: finalCategory,
                notes: dto.name
            )

            modelContext.insert(newTransaction)
        }

        try? modelContext.save()
    }
}


