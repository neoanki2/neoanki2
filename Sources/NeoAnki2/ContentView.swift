import NeoAnkiCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ItemsModel
    @State private var isAddingItem = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Loading items…")
                } else if model.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Items Yet", systemImage: "rectangle.stack.badge.plus")
                    } description: {
                        Text("Add an item to generate study cards.")
                    } actions: {
                        Button("Add Item") { isAddingItem = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("addItemEmptyState")
                    }
                } else {
                    List(model.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.subtitle)
                                .foregroundStyle(.secondary)
                            Text("\(item.cardCount) cards · \(item.itemTypeName)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("itemRow-\(item.title)")
                    }
                }
            }
            .navigationTitle("Items")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Item", systemImage: "plus") {
                        isAddingItem = true
                    }
                    .accessibilityIdentifier("addItemToolbar")
                }
            }
            .sheet(isPresented: $isAddingItem) {
                NavigationStack {
                    AddItemView(model: model)
                }
            }
        }
        .task {
            await model.load()
        }
    }
}
