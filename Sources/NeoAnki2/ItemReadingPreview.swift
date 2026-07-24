import NeoAnkiCore
import SwiftUI

/// Renders item field content in the study reading column typography.
struct ItemReadingPreview: View {
    let item: Item
    let itemType: ItemType

    private var displayFields: [(FieldDef, ContentValue)] {
        itemType.fields.compactMap { field in
            guard let value = item.value(for: field.id), !value.isEmpty else { return nil }
            return (field, value)
        }
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            ForEach(Array(displayFields.enumerated()), id: \.offset) { index, fieldPair in
                if index == 1 {
                    Divider()
                }

                VStack(spacing: DesignSystem.Spacing.rowTight) {
                    if index >= 2 {
                        Text(fieldPair.0.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    ContentValueView(value: fieldPair.1)
                        .font(font(for: index))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func font(for index: Int) -> Font {
        switch index {
        case 0: .title
        case 1: .title2
        default: .body
        }
    }
}

struct ItemDetailView: View {
    @Bindable var model: ItemsModel
    let summary: SavedItemSummary
    var onDeleted: () -> Void = {}

    @State private var item: Item?
    @State private var itemType: ItemType?
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView()
                    Text("Loading item…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading item")
            } else if let item, let itemType {
                ScrollView {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        ItemReadingPreview(item: item, itemType: itemType)

                        Text("\(summary.cardCount) cards · \(summary.itemTypeName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    .readingColumnLayout()
                }
            } else {
                ContentUnavailableView {
                    Label("Couldn't Load Item", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage ?? "This item may have been removed.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.detailBackground)
        .navigationTitle(summary.title)
        .toolbar {
            if item != nil, !isLoading {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("deleteItem")
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(summary.title)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Item", role: .destructive) {
                Task { await deleteItem() }
            }
            .accessibilityIdentifier("confirmDeleteItem")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the item and its \(summary.cardCount) study cards. This can't be undone."
            )
        }
        .task(id: summary.id) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil

        do {
            if let loaded = try await model.store.fetchItem(id: summary.id) {
                item = loaded.item
                itemType = loaded.itemType
            } else {
                errorMessage = "This item could not be found."
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }

        isLoading = false
    }

    @MainActor
    private func deleteItem() async {
        isDeleting = true
        defer { isDeleting = false }

        if await model.deleteItem(id: summary.id) {
            onDeleted()
        }
    }
}
