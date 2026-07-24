import NeoAnkiCore
import SwiftUI

struct DeckDetailView: View {
    @Bindable var itemsModel: ItemsModel
    @Bindable var decksModel: DecksModel
    let scope: StudyScope
    @Binding var selectedItemID: SavedItemSummary.ID?
    let onAddItem: () -> Void
    let onStudy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = itemsModel.errorMessage, !itemsModel.isLoading {
                ErrorBanner(message: errorMessage)
            }

            Group {
                if itemsModel.isLoading {
                    ProgressView("Loading items…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if itemsModel.items.isEmpty {
                    emptyState
                } else {
                    List(itemsModel.items, selection: $selectedItemID) { item in
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.subtitle)
                                .foregroundStyle(.secondary)
                            Text("\(item.cardCount) cards · \(item.itemTypeName)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(item.title), \(item.subtitle), \(item.cardCount) cards, \(item.itemTypeName)"
                        )
                        .accessibilityIdentifier("itemRow-\(item.title)")
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.detailBackground)
        .navigationTitle(scope.label)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    onStudy()
                } label: {
                    if itemsModel.dueCount > 0 {
                        Label("Study", systemImage: "play.fill")
                            .badge(itemsModel.dueCount)
                    } else {
                        Label("Study", systemImage: "play.fill")
                    }
                }
                .disabled(itemsModel.dueCount == 0)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .accessibilityIdentifier("studyButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Item", systemImage: "plus") {
                    onAddItem()
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("addItemToolbar")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch scope.filter {
        case .allDecks:
            SidebarEmptyState(
                title: "No Items Yet",
                message: "Add an item to generate study cards.",
                systemImage: "rectangle.stack.badge.plus",
                actionTitle: "Add Item",
                action: onAddItem,
                actionIdentifier: "addItemEmptyState"
            )
        case .unassigned:
            SidebarEmptyState(
                title: "No Unassigned Items",
                message: "Items without a deck appear here.",
                systemImage: "tray",
                actionTitle: nil,
                action: nil,
                actionIdentifier: nil
            )
        case .deck:
            SidebarEmptyState(
                title: "No Items in Deck",
                message: "Add an item to this deck to start studying.",
                systemImage: "rectangle.stack.badge.plus",
                actionTitle: "Add Item",
                action: onAddItem,
                actionIdentifier: "addItemEmptyState"
            )
        }
    }
}
