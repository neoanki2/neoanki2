import NeoAnkiCore
import SwiftUI

/// Everything the library sidebar can select. Deck scopes remain model state;
/// recordings are a separate destination, but they participate in the same
/// native List selection so the sidebar cannot highlight two places at once.
private enum LibrarySidebarDestination: Hashable {
    case scope(SidebarSelection)
    case recordings
}

struct DeckSidebarView: View {
    @Bindable var decksModel: DecksModel
    @Binding var selection: SidebarSelection
    @Binding var isShowingSavedResponses: Bool
    var onDeleteAllUnassigned: () -> Void = {}
    var onDeckSettingsSaved: () async -> Void = {}
    var onDeckProgressReset: () async -> Void = {}
    @State private var deckToRename: DeckSummary?
    @State private var deckToConfigure: DeckSummary?
    @State private var renameText = ""
    @State private var deckToDelete: DeckSummary?
    @State private var affectedResponseCount = 0
    @State private var showDeleteAllUnassignedConfirm = false
    @State private var showNewDeckPrompt = false
    @State private var newDeckName = ""
    @State private var newDeckParentID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = decksModel.errorMessage, !decksModel.isLoading {
                ErrorBanner(message: errorMessage)
            }

            Group {
                if decksModel.isLoading {
                    ProgressView("Loading decks…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: sidebarSelection) {
                        Section("Library") {
                            virtualRow(
                                title: "All Decks",
                                subtitle: dueCaption(decksModel.allDecksDueCount),
                                systemImage: "square.stack.3d.up",
                                tag: .allDecks
                            )

                            sidebarRow(
                                title: "Recordings",
                                subtitle: nil,
                                systemImage: "waveform",
                                destination: .recordings
                            )
                            .accessibilityHint("Opens spoken responses saved during study")
                            .accessibilityIdentifier("savedResponsesSidebar")
                        }

                        Section("Decks") {
                            if decksModel.deckTree.isEmpty {
                                Text("No decks yet")
                                    .font(DesignSystem.Typography.uiCaption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(decksModel.deckTree) { node in
                                    DeckSidebarNode(
                                        node: node,
                                        decksModel: decksModel,
                                        onConfigure: { deckToConfigure = $0 },
                                        onRename: beginRename,
                                        onDelete: prepareDeckDeletion,
                                        onNewSubdeck: beginNewSubdeck
                                    )
                                }
                            }

                            virtualRow(
                                title: "Unassigned",
                                subtitle: SidebarScopeCaption.compactText(
                                    itemCount: decksModel.unassignedItemCount,
                                    dueCount: decksModel.unassignedDueCount
                                ),
                                systemImage: "tray",
                                tag: .unassigned
                            )
                            .accessibilityLabel(
                                "Unassigned, " + SidebarScopeCaption.text(
                                    itemCount: decksModel.unassignedItemCount,
                                    dueCount: decksModel.unassignedDueCount
                                )
                            )
                            .contextMenu {
                                if decksModel.unassignedItemCount > 0 {
                                    Button("Delete All", role: .destructive) {
                                        showDeleteAllUnassignedConfirm = true
                                    }
                                    .accessibilityIdentifier("deleteAllUnassignedMenu")
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.sidebarBackground)
        .navigationTitle("Decks")
        .sheet(item: $deckToConfigure) { deck in
            DeckSettingsView(
                decksModel: decksModel,
                deck: deck,
                onSaved: onDeckSettingsSaved,
                onProgressReset: onDeckProgressReset
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Deck", systemImage: "plus") {
                    newDeckParentID = nil
                    newDeckName = ""
                    showNewDeckPrompt = true
                }
                .accessibilityIdentifier("newDeckToolbar")
            }
        }
        .alert("New Deck", isPresented: $showNewDeckPrompt) {
            TextField("Name", text: $newDeckName)
            Button("Create") {
                Task {
                    if let deck = await decksModel.createDeck(
                        name: newDeckName,
                        parentID: newDeckParentID
                    ) {
                        isShowingSavedResponses = false
                        selection = .deck(deck.id)
                    }
                }
            }
            .accessibilityIdentifier("confirmCreateDeck")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelCreateDeck")
        } message: {
            if newDeckParentID != nil {
                Text("Create a subdeck inside the selected deck.")
            } else {
                Text("Create a top-level deck for organizing items.")
            }
        }
        .alert("Rename Deck", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Save") {
                guard let deck = deckToRename else { return }
                Task {
                    if await decksModel.renameDeck(id: deck.id, name: renameText) {
                        deckToRename = nil
                    }
                }
            }
            .accessibilityIdentifier("confirmRenameDeck")
            Button("Cancel", role: .cancel) {
                deckToRename = nil
            }
            .accessibilityIdentifier("cancelRenameDeck")
        }
        .confirmationDialog(
            deckToDelete.map { "Delete \"\($0.name)\"?" } ?? "Delete deck?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Deck", role: .destructive) {
                guard let deck = deckToDelete else { return }
                Task {
                    _ = await decksModel.deleteDeck(id: deck.id)
                    deckToDelete = nil
                }
            }
            .accessibilityIdentifier("confirmDeleteDeck")
            Button("Cancel", role: .cancel) {
                deckToDelete = nil
            }
            .accessibilityIdentifier("cancelDeleteDeck")
        } message: {
            if affectedResponseCount > 0 {
                Text("This permanently deletes the deck, all subdecks, every item they contain, and \(affectedResponseCount) saved spoken \(affectedResponseCount == 1 ? "response" : "responses").")
            } else {
                Text("This permanently deletes the deck, all subdecks, and every item they contain.")
            }
        }
        .confirmationDialog(
            "Delete all unassigned items?",
            isPresented: $showDeleteAllUnassignedConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                onDeleteAllUnassigned()
            }
            .accessibilityIdentifier("confirmDeleteAllUnassigned")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelDeleteAllUnassigned")
        } message: {
            Text(
                "This permanently deletes all \(decksModel.unassignedItemCount) unassigned items and their study cards."
            )
        }
    }

    private var sidebarSelection: Binding<LibrarySidebarDestination> {
        Binding(
            get: {
                isShowingSavedResponses ? .recordings : .scope(selection)
            },
            set: { destination in
                switch destination {
                case .recordings:
                    isShowingSavedResponses = true
                case let .scope(scope):
                    // Close Recordings even if this is the scope that was
                    // already active before the user opened it.
                    isShowingSavedResponses = false
                    selection = scope
                }
            }
        )
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { deckToRename != nil },
            set: { if !$0 { deckToRename = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deckToDelete != nil },
            set: { if !$0 { deckToDelete = nil } }
        )
    }

    private func beginRename(_ summary: DeckSummary) {
        deckToRename = summary
        renameText = summary.name
    }

    private func prepareDeckDeletion(_ summary: DeckSummary) {
        Task {
            guard let impact = await decksModel.deletionImpact(id: summary.id) else { return }
            affectedResponseCount = impact.studyResponseCount
            deckToDelete = summary
        }
    }

    private func beginNewSubdeck(parentID: UUID) {
        newDeckParentID = parentID
        newDeckName = ""
        showNewDeckPrompt = true
    }

    @ViewBuilder
    private func virtualRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tag: SidebarSelection
    ) -> some View {
        sidebarRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            destination: .scope(tag)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityIdentifier(scopeAccessibilityIdentifier(for: tag))
    }

    private func sidebarRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        destination: LibrarySidebarDestination
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: systemImage)
                .imageScale(.medium)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .font(DesignSystem.Typography.sidebarRowTitle)
                .lineLimit(1)

            Spacer(minLength: DesignSystem.Spacing.xs)

            if let subtitle {
                Text(subtitle)
                    .font(DesignSystem.Typography.sidebarRowMeta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .tag(destination)
    }

    private func dueCaption(_ count: Int) -> String {
        count > 0 ? "\(count) due" : "Up to date"
    }

    private func scopeAccessibilityIdentifier(for tag: SidebarSelection) -> String {
        switch tag {
        case .allDecks: "scopeRow-AllDecks"
        case .unassigned: "scopeRow-Unassigned"
        case .deck: "scopeRow-Deck"
        }
    }
}

private struct DeckSidebarNode: View {
    let node: DeckNode
    @Bindable var decksModel: DecksModel
    let onConfigure: (DeckSummary) -> Void
    let onRename: (DeckSummary) -> Void
    let onDelete: (DeckSummary) -> Void
    let onNewSubdeck: (UUID) -> Void
    @State private var isExpanded = false

    var body: some View {
        if node.children.isEmpty {
            deckRow(node.summary)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    DeckSidebarNode(
                        node: child,
                        decksModel: decksModel,
                        onConfigure: onConfigure,
                        onRename: onRename,
                        onDelete: onDelete,
                        onNewSubdeck: onNewSubdeck
                    )
                }
            } label: {
                deckRow(node.summary)
            }
            .onChange(of: decksModel.selectedScope, initial: true) { _, selection in
                guard case let .deck(selectedID) = selection else { return }
                if containsDescendant(selectedID) {
                    isExpanded = true
                }
            }
        }
    }

    private func containsDescendant(_ id: UUID) -> Bool {
        node.children.contains { child in
            child.id == id || containsDeck(id, in: child)
        }
    }

    private func containsDeck(_ id: UUID, in node: DeckNode) -> Bool {
        node.children.contains { child in
            child.id == id || containsDeck(id, in: child)
        }
    }

    private func deckRow(_ summary: DeckSummary) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "folder")
                .imageScale(.medium)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(summary.name)
                .font(DesignSystem.Typography.sidebarRowTitle)
                .lineLimit(1)

            Spacer(minLength: DesignSystem.Spacing.xs)

            Text(compactSubtitle(for: summary))
                .font(DesignSystem.Typography.sidebarRowMeta)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .tag(LibrarySidebarDestination.scope(.deck(summary.id)))
        .contextMenu {
            Button("Deck Settings…") {
                onConfigure(summary)
            }
            .accessibilityIdentifier("deckSettingsMenu")
            Divider()
            Button("New Subdeck") {
                onNewSubdeck(summary.id)
            }
            Button("Rename") {
                onRename(summary)
            }
            Button("Delete", role: .destructive) {
                onDelete(summary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.name), \(rowSubtitle(for: summary))")
        .accessibilityIdentifier("deckRow-\(summary.name)")
    }

    private func rowSubtitle(for summary: DeckSummary) -> String {
        SidebarScopeCaption.text(itemCount: summary.itemCount, dueCount: summary.dueCount)
    }

    private func compactSubtitle(for summary: DeckSummary) -> String {
        SidebarScopeCaption.compactText(
            itemCount: summary.itemCount,
            dueCount: summary.dueCount
        )
    }
}

/// The line under a sidebar scope's name. Every scope row uses this, so a deck
/// and Unassigned cannot describe the same emptiness in different words.
enum SidebarScopeCaption {
    static func text(itemCount: Int, dueCount: Int) -> String {
        var parts: [String] = []
        if itemCount > 0 {
            parts.append(itemCount == 1 ? "1 item" : "\(itemCount) items")
        }
        if dueCount > 0 {
            parts.append("\(dueCount) due")
        }
        return parts.isEmpty ? "No items" : parts.joined(separator: " · ")
    }

    /// Sidebar rows prioritize the next action over inventory. Full counts
    /// remain in the scope home and VoiceOver label, while the visual row stays
    /// scannable even with long deck names and a narrow sidebar.
    static func compactText(itemCount: Int, dueCount: Int) -> String {
        if dueCount > 0 { return "\(dueCount) due" }
        if itemCount > 0 { return itemCount == 1 ? "1 item" : "\(itemCount) items" }
        return "Empty"
    }
}
