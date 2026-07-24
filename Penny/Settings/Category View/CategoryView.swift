//
//  CategoryView.swift
//  Penny
//
//  Created by Ethan Christo on 12/31/25.
//

import OSLog
import SwiftData
import SwiftUI

private let log = Logger(subsystem: "com.opal.Penny", category: "category")

struct CategoryView: View {
    @Environment(\.modelContext) var modelContext

    @Query(sort: \Category.name) var categories: [Category]

    @State private var showAddCategory = false
    @State private var selectedCategory: Category?
    
    var body: some View {
        List {
            ForEach(categories) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack {
                        Text(category.symbol)
                        Text(category.name)
                    }
                }
                .tint(.primary)
            }
        }
        .listRowSpacing(12)
        .navigationTitle("Categories")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Seed pre-built categories") {
                        seedPreBuiltCategories()
                    }
                }
            }
            
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddCategory = true
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddCategory) {
            NavigationStack {
                EditCategoryView(category: nil)
            }
        }
        .sheet(item: $selectedCategory) { category in
            NavigationStack {
                EditCategoryView(category: category)
            }
        }
    }

    /// Inserts any pre-built categories that are missing, matching on name so
    /// existing categories (including ones the user renamed away from) are never
    /// duplicated. Lets the user restore the defaults after deleting some.
    private func seedPreBuiltCategories() {
        let existingNames = Set(categories.map(\.name))
        for option in CategoryOptions.allCases where !existingNames.contains(option.rawValue) {
            modelContext.insert(option.preBuiltCategory)
        }

        do {
            try modelContext.save()
        } catch {
            log.error("Failed to seed pre-built categories: \(error.localizedDescription)")
        }
    }
}
