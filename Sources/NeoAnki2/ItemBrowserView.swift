import NeoAnkiCore
import SwiftUI

/// Deliberate browse mode: find, inspect, and triage items by their scheduling
/// state. The answer column is available but hidden, so opening the library
/// never spoils a card you have not been asked yet.
struct ItemBrowserView: View {
    @Bindable var itemsModel: ItemsModel
    @Bindable var decksModel: DecksModel
    /// Owned by the window so the choice survives leaving browse mode, and
    /// driven by a menu command so it is discoverable and keyboard-reachable
    /// rather than hiding behind a right-click on a table header.
    @Binding var showsAnswerColumn: Bool
    let scope: StudyScope
    let onOpenItem: (SavedItemSummary.ID) -> Void
    let onAddItem: () -> Void
    let onStudy: () -> Void
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: Set<SavedItemSummary.ID> = []
    @State private var columnCustomization = TableColumnCustomization<SavedItemSummary>()
    @State private var pendingDeleteIDs: Set<SavedItemSummary.ID>?

    /// Reads the table's own state, so revealing the column through the header
    /// context menu and revealing it through the Library menu stay in agreement.
    private var answerColumnIsVisible: Bool {
        columnCustomization[visibility: "answer"] != .hidden
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = itemsModel.errorMessage, !itemsModel.isLoading {
                ErrorBanner(message: errorMessage)
            }

            Group {
                if itemsModel.isLoading {
                    ProgressView("Loading items…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("itemBrowserLoading")
                } else if itemsModel.items.isEmpty {
                    emptyScope
                } else if itemsModel.visibleItems.isEmpty {
                    ContentUnavailableView.search(text: itemsModel.searchText)
                        .accessibilityIdentifier("browseNoSearchResults")
                } else {
                    table
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.detailBackground)
        .navigationTitle(scope.label)
        .navigationSubtitle(subtitle)
        .searchable(text: $itemsModel.searchText, placement: .toolbar, prompt: "Search items")
        .onExitCommand(perform: onDone)
        .onChange(of: showsAnswerColumn, initial: true) { _, shows in
            columnCustomization[visibility: "answer"] = shows ? .visible : .hidden
        }
        .onChange(of: answerColumnIsVisible) { _, visible in
            showsAnswerColumn = visible
        }
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .automatic) {
                    moveMenu(for: selection)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDeleteIDs = selection
                    }
                    .accessibilityIdentifier("browseDeleteSelection")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Study", systemImage: "play.fill") {
                    onStudy()
                }
                .disabled(itemsModel.dueCount == 0)
                .help(studyHelp)
                .accessibilityIdentifier("studyButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Item", systemImage: "plus") {
                    onAddItem()
                }
                .accessibilityIdentifier("addItemToolbar")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("browseDone")
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingDeleteIDs != nil },
                set: { if !$0 { pendingDeleteIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let ids = pendingDeleteIDs else { return }
                pendingDeleteIDs = nil
                Task {
                    let now = Date.now
                    await itemsModel.deleteItems(ids: ids, scope: scope, asOf: now)
                    selection = []
                    await decksModel.load(asOf: now)
                }
            }
            .accessibilityIdentifier("browseConfirmDelete")
            Button("Cancel", role: .cancel) {
                pendingDeleteIDs = nil
            }
            .accessibilityIdentifier("browseCancelDelete")
        } message: {
            Text("This also deletes the study cards these items generated. It can't be undone.")
        }
    }

    private var subtitle: String {
        let total = itemsModel.items.count
        let shown = itemsModel.visibleItems.count
        let noun = total == 1 ? "item" : "items"
        if shown != total {
            return "\(shown) of \(total) \(noun)"
        }
        return "\(total) \(noun)"
    }

    private var studyHelp: String {
        itemsModel.dueCount > 0
            ? "Study the \(itemsModel.dueCount) cards due in this scope"
            : "Nothing is due in this scope yet"
    }

    private var deleteConfirmationTitle: String {
        let count = pendingDeleteIDs?.count ?? 0
        return count == 1 ? "Delete this item?" : "Delete \(count) items?"
    }

    // MARK: - Table

    private var table: some View {
        Table(
            of: SavedItemSummary.self,
            selection: $selection,
            sortOrder: $itemsModel.tableSort,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Prompt", value: \.title) { item in
                Text(item.title)
                    .lineLimit(textLineLimit)
                    .help(item.title)
                    .accessibilityLabel(accessibilityLabel(for: item))
                    .accessibilityIdentifier("itemRow-\(item.title)")
            }
            .width(min: promptMinWidth, ideal: promptIdealWidth)
            .customizationID("prompt")

            TableColumn("Due", value: \.dueSortKey) { item in
                Text(dueText(for: item))
                    .foregroundStyle(item.schedule?.isDue() == true ? .primary : .secondary)
                    .accessibilityLabel(dueAccessibilityLabel(for: item))
            }
            .customizationID("due")

            TableColumn("State", value: \.phaseSortKey) { item in
                Text(phaseText(for: item))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(phaseAccessibilityLabel(for: item))
            }
            .customizationID("state")

            TableColumn("Lapses", value: \.lapseSortKey) { item in
                Text(item.lapseSortKey == 0 ? "" : "\(item.lapseSortKey)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(lapseAccessibilityLabel(for: item))
            }
            .customizationID("lapses")

            TableColumn("Type", value: \.itemTypeName) { item in
                Text(item.itemTypeName)
                    .foregroundStyle(.secondary)
            }
            .customizationID("type")

            TableColumn("Cards", value: \.cardCount) { item in
                Text("\(item.cardCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(item.cardCount) cards")
            }
            .customizationID("cards")

            TableColumn("Answer", value: \.subtitle) { item in
                Text(item.subtitle)
                    .lineLimit(textLineLimit)
                    .help(item.subtitle)
                    .foregroundStyle(.secondary)
            }
            .customizationID("answer")
        } rows: {
            ForEach(itemsModel.visibleItems) { item in
                TableRow(item)
            }
        }
        .contextMenu(forSelectionType: SavedItemSummary.ID.self) { ids in
            if ids.isEmpty {
                Button("Add Item", systemImage: "plus", action: onAddItem)
                    .accessibilityIdentifier("browseMenuAddItem")
            } else {
                if ids.count == 1, let id = ids.first {
                    Button("Open", systemImage: "arrow.forward") { onOpenItem(id) }
                        .accessibilityIdentifier("browseMenuOpen")
                }
                moveMenu(for: ids)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeleteIDs = ids
                }
                .accessibilityIdentifier("browseMenuDelete")
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            onOpenItem(id)
        }
        .accessibilityIdentifier("itemBrowserTable")
    }

    private func moveMenu(for ids: Set<SavedItemSummary.ID>) -> some View {
        Menu("Move to Deck", systemImage: "folder") {
            ForEach(decksModel.summaries) { deck in
                Button(deck.name) {
                    move(ids, to: deck.id)
                }
                .accessibilityIdentifier("browseMoveToDeck-\(deck.name)")
            }
            if !decksModel.summaries.isEmpty {
                Divider()
            }
            Button("No Deck") {
                move(ids, to: nil)
            }
            .accessibilityIdentifier("browseMoveToNoDeck")
        }
        .accessibilityIdentifier("browseMoveToDeck")
    }

    private func move(_ ids: Set<SavedItemSummary.ID>, to deckID: UUID?) {
        Task {
            // One instant for both reloads; two `.now` reads are exactly how the
            // sidebar total and the detail pane learned to disagree.
            let now = Date.now
            await itemsModel.moveItems(ids: ids, to: deckID, scope: scope, asOf: now)
            selection = []
            await decksModel.load(asOf: now)
        }
    }

    // MARK: - Dynamic Type
    //
    // A table row cannot grow without limit, so at accessibility sizes the prompt
    // gets a third line and a wider measure, and hover carries the full text. A
    // truncated prompt is a failed lookup, and this surface exists to look things
    // up.

    private var textLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    private var promptMinWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 240 : 160
    }

    private var promptIdealWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 420 : 320
    }

    // MARK: - Cell text

    private func dueText(for item: SavedItemSummary) -> String {
        guard let dueAt = item.schedule?.dueAt else { return "—" }
        if dueAt <= .now { return "Now" }
        return dueAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private func phaseText(for item: SavedItemSummary) -> String {
        guard let phase = item.schedule?.phase else { return "—" }
        switch phase {
        case .new: return "New"
        case .learning: return "Learning"
        case .relearning: return "Relearning"
        case .review: return "Review"
        }
    }

    /// The row's headline for VoiceOver. Card count and type stop here because
    /// their own cells already announce them; repeating them makes a
    /// cell-by-cell traversal say everything twice.
    private func accessibilityLabel(for item: SavedItemSummary) -> String {
        "\(item.title), \(phaseText(for: item)), due \(dueText(for: item))"
    }

    private func dueAccessibilityLabel(for item: SavedItemSummary) -> String {
        item.schedule?.dueAt == nil ? "Not scheduled" : "Due \(dueText(for: item))"
    }

    /// An em-dash placeholder reads as nothing at all, so the empty cases say
    /// what they mean.
    private func phaseAccessibilityLabel(for item: SavedItemSummary) -> String {
        item.schedule?.phase == nil ? "No cards yet" : phaseText(for: item)
    }

    private func lapseAccessibilityLabel(for item: SavedItemSummary) -> String {
        item.lapseSortKey == 0 ? "No lapses" : "\(item.lapseSortKey) lapses"
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyScope: some View {
        switch scope.filter {
        case .allDecks:
            SidebarEmptyState(
                title: "Nothing to Remember Yet",
                message: "Add an item and NeoAnki2 turns it into cards, then brings each one back "
                    + "just before you would forget it.",
                systemImage: "rectangle.stack.badge.plus",
                actionTitle: "Add Item",
                action: onAddItem,
                actionIdentifier: "addItemEmptyState",
                contentIdentifier: "emptyLibraryState"
            )
        case .unassigned:
            SidebarEmptyState(
                title: "No Unassigned Items",
                message: "Items you add without choosing a deck collect here.",
                systemImage: "tray",
                actionTitle: nil,
                action: nil,
                actionIdentifier: nil,
                contentIdentifier: "emptyUnassignedState"
            )
        case .deck:
            SidebarEmptyState(
                title: "No Items in This Deck",
                message: "Add an item here and its cards join this deck's reviews.",
                systemImage: "folder.badge.plus",
                actionTitle: "Add Item",
                action: onAddItem,
                actionIdentifier: "addItemEmptyState",
                contentIdentifier: "emptyDeckState"
            )
        }
    }
}

extension SavedItemSummary {
    /// `Table` needs a total order per column, so unscheduled items collapse to
    /// a sentinel that keeps them together at one end.
    var dueSortKey: Date { schedule?.dueAt ?? .distantFuture }

    /// Ordered by how far a card has progressed, not alphabetically.
    var phaseSortKey: Int {
        switch schedule?.phase {
        case .new: 0
        case .learning: 1
        case .relearning: 2
        case .review: 3
        case nil: 4
        }
    }

    var lapseSortKey: Int { schedule?.lapses ?? 0 }
}
