import NeoAnkiCore
import SwiftUI

/// Renders item field content in the study reading column typography.
struct ItemReadingPreview: View {
    let item: Item
    let itemType: ItemType
    var mediaStore: MediaStore?

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
                            .font(DesignSystem.Typography.uiHint)
                            .foregroundStyle(.tertiary)
                    }

                    ContentValueView(
                        value: fieldPair.1,
                        isAnswerRevealed: true,
                        richTextPointSize: pointSize(for: index),
                        mediaStore: mediaStore
                    )
                        .font(font(for: index))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func font(for index: Int) -> Font {
        switch index {
        case 0: DesignSystem.Typography.cardPrompt
        case 1: DesignSystem.Typography.cardAnswer
        default: DesignSystem.Typography.uiBody
        }
    }

    private func pointSize(for index: Int) -> CGFloat {
        switch index {
        case 0: DesignSystem.Typography.cardPromptPointSize
        case 1: DesignSystem.Typography.cardAnswerPointSize
        default: DesignSystem.Typography.richTextPointSize
        }
    }
}

struct ItemDetailView: View {
    @Bindable var model: ItemsModel
    @Bindable var decksModel: DecksModel
    let scope: StudyScope
    let summary: SavedItemSummary
    var onDeleted: () -> Void = {}

    @State private var item: Item?
    @State private var itemType: ItemType?
    @State private var selectedDeckID: UUID?
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var isMovingDeck = false
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
                        ItemReadingPreview(
                            item: item,
                            itemType: itemType,
                            mediaStore: model.mediaStore
                        )

                        if !decksModel.summaries.isEmpty {
                            Picker("Deck", selection: $selectedDeckID) {
                                Text("Unassigned").tag(UUID?.none)
                                ForEach(decksModel.summaries) { deck in
                                    Text(deck.name).tag(Optional(deck.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Deck")
                            .accessibilityIdentifier("itemDeckPicker")
                            .onChange(of: selectedDeckID) { oldValue, newValue in
                                guard oldValue != newValue, !isLoading else { return }
                                Task { await moveDeck(to: newValue) }
                            }
                        }

                        Text("\(summary.cardCount) cards · \(summary.itemTypeName)")
                            .font(DesignSystem.Typography.uiCaption)
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
                .accessibilityIdentifier("cancelDeleteItem")
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
                selectedDeckID = loaded.item.deckID
            } else {
                errorMessage = "This item could not be found."
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }

        isLoading = false
    }

    @MainActor
    private func moveDeck(to deckID: UUID?) async {
        guard !isMovingDeck else { return }
        isMovingDeck = true
        defer { isMovingDeck = false }

        if await model.moveItem(id: summary.id, to: deckID, scope: scope) {
            item?.deckID = deckID
            await decksModel.load()
        } else {
            selectedDeckID = item?.deckID
        }
    }

    @MainActor
    private func deleteItem() async {
        isDeleting = true
        defer { isDeleting = false }

        if await model.deleteItem(id: summary.id, scope: scope) {
            onDeleted()
        }
    }
}
