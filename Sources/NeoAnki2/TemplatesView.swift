import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI

private struct PendingItemTypeUnlock {
    let itemTypeID: UUID
    let itemTypeName: String
    let impact: ItemTypeEditingImpact
}

/// The macOS Item Types navigator. Editing is delegated to one atomic Studio
/// draft so fields and Card setups are never persisted independently.
struct TemplatesView: View {
    @Bindable var model: ItemTypesFeatureModel
    @Binding private var isTemplateEditorPresented: Bool
    var onTemplatesChanged: () async -> Void = {}

    @State private var expandedIncludedGroupIDs: Set<UUID> = []
    @State private var definitionToRepair: QuarantinedItemTypeDefinition?
    @State private var pendingUnlock: PendingItemTypeUnlock?
    @State private var pendingSelectionID: UUID?
    @State private var showDiscardForSelection = false
    @State private var showDuplicatePrompt = false
    @State private var duplicateName = ""
    @State private var showDeleteConfirmation = false
    @State private var actionError: String?
    @State private var isWorking = false

    init(
        model: ItemTypesFeatureModel,
        isTemplateEditorPresented: Binding<Bool> = .constant(false),
        onTemplatesChanged: @escaping () async -> Void = {}
    ) {
        self.model = model
        _isTemplateEditorPresented = isTemplateEditorPresented
        self.onTemplatesChanged = onTemplatesChanged
    }

    var body: some View {
        GeometryReader { geometry in
            let dividerWidth: CGFloat = 1
            let navigatorWidth = min(
                geometry.size.width,
                min(
                    DesignSystem.sidebarMax,
                    max(DesignSystem.sidebarMin, geometry.size.width * 0.26)
                )
            )
            let detailWidth = max(0, geometry.size.width - navigatorWidth - dividerWidth)

            HStack(spacing: 0) {
                itemTypesNavigator
                    .frame(width: navigatorWidth, height: geometry.size.height)
                Divider()
                    .frame(width: dividerWidth, height: geometry.size.height)
                detail
                    .frame(width: detailWidth, height: geometry.size.height)
            }
            // A nested AppKit split can publish a post-mount fitting width back
            // to the host window. Keep both navigator and Studio inside the
            // finite viewport proposed by the app window instead.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.load() }
        .onChange(of: model.selectedItemTypeID) { _, _ in
            if let group = model.selectedIncludedGroup {
                expandedIncludedGroupIDs.insert(group.id)
            }
        }
        .onChange(of: model.studioDraft != nil, initial: true) { _, active in
            isTemplateEditorPresented = active
        }
        .confirmationDialog(
            "Discard unsaved Studio changes?",
            isPresented: $showDiscardForSelection,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                model.discardStudioDraft()
                model.selectItemType(id: pendingSelectionID)
                pendingSelectionID = nil
            }
            .accessibilityIdentifier("discardItemTypeStudioSelection")
            Button("Keep Editing", role: .cancel) { pendingSelectionID = nil }
                .accessibilityIdentifier("keepEditingItemTypeStudioSelection")
        } message: {
            Text("Fields and Card setup changes have not been saved.")
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Item Type", role: .destructive) {
                Task { await deleteSelectedItemType() }
            }
            .accessibilityIdentifier("confirmDeleteItemType")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelDeleteItemType")
        } message: {
            Text("This removes the Item Type and all of its Card setups. This cannot be undone.")
        }
        .confirmationDialog(
            "Repair damaged item type?",
            isPresented: Binding(
                get: { definitionToRepair != nil },
                set: { if !$0 { definitionToRepair = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive Original and Repair") {
                guard let definitionToRepair else { return }
                Task { await repair(definitionToRepair) }
            }
            .accessibilityIdentifier("confirmRepairItemType")
            Button("Cancel", role: .cancel) { definitionToRepair = nil }
                .accessibilityIdentifier("cancelRepairItemType")
        } message: {
            Text("NeoAnki2 preserves the unreadable definition before creating a minimal editable replacement. Existing items are not deleted.")
        }
        .alert("Duplicate as Item Type", isPresented: $showDuplicatePrompt) {
            TextField("Name", text: $duplicateName)
                .accessibilityLabel("New Item Type Name")
                .accessibilityIdentifier("duplicateItemTypeName")
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") { Task { await duplicateSelectedItemType() } }
                .disabled(duplicateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("confirmDuplicateItemType")
        } message: {
            Text("The copy is an independent, editable Item Type.")
        }
        .confirmationDialog(
            "Unlock \(pendingUnlock?.itemTypeName ?? "item type") for editing?",
            isPresented: Binding(
                get: { pendingUnlock != nil },
                set: { if !$0 { pendingUnlock = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let requested = pendingUnlock {
                Button("Unlock for Editing") { Task { await unlockItemType(requested) } }
                    .accessibilityIdentifier("confirmUnlockIncludedItemType")
            }
            Button("Cancel", role: .cancel) { pendingUnlock = nil }
                .accessibilityIdentifier("cancelUnlockIncludedItemType")
        } message: {
            if let impact = pendingUnlock?.impact { Text(unlockImpactMessage(impact)) }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedItemTypeID },
            set: { requestedID in
                guard requestedID != model.selectedItemTypeID else { return }
                if hasUnsavedStudioChanges {
                    pendingSelectionID = requestedID
                    showDiscardForSelection = true
                } else {
                    model.discardStudioDraft()
                    model.selectItemType(id: requestedID)
                }
            }
        )
    }

    /// New Studio drafts have no persisted snapshot even before the user types.
    /// Switching the navigator must therefore offer the same discard safeguard
    /// as an edited existing definition.
    private var hasUnsavedStudioChanges: Bool {
        guard let draft = model.studioDraft else { return false }
        return draft.originalSnapshot == nil || draft.isDirty
    }

    @ViewBuilder
    private var itemTypesNavigator: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Item Types")
                    .font(DesignSystem.Typography.uiSection)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("templatesItemTypesHeader")
                Spacer()
                Button("Add", systemImage: "plus") { model.beginCreatingItemType() }
                    .disabled(model.studioDraft != nil)
                    .accessibilityIdentifier("addItemTypeToolbar")
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            if let actionError {
                ErrorBanner(message: actionError)
                    .accessibilityIdentifier("itemTypeStudioActionError")
            }

            ForEach(model.corruptedDefinitions) { corruption in
                HStack {
                    Text(corruption.name).lineLimit(1)
                    Spacer()
                    Button("Repair") { definitionToRepair = corruption }
                        .accessibilityIdentifier("repairItemType-\(corruption.name)")
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }

            switch model.loadState {
            case .loading:
                ProgressView("Loading item types…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(error):
                ContentUnavailableView {
                    Label(error.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                }
            case .ready:
                if model.itemTypes.isEmpty && model.includedItemTypeGroups.isEmpty {
                    SidebarEmptyState(
                        title: "No Item Types",
                        message: "Create an Item Type with fields and a ready-to-use Card setup.",
                        systemImage: "square.grid.2x2",
                        actionTitle: "Add Item Type",
                        action: { model.beginCreatingItemType() },
                        actionIdentifier: "addItemTypeEmptyState"
                    )
                } else {
                    List(selection: selection) {
                        Section {
                            ForEach(model.itemTypes) { itemType in
                                itemTypeRow(itemType, readOnly: false).tag(itemType.id)
                            }
                        }
                        if !model.includedItemTypeGroups.isEmpty {
                            Section("From Decks") {
                                ForEach(model.includedItemTypeGroups) { group in
                                    includedGroupButton(group)
                                    if expandedIncludedGroupIDs.contains(group.id) {
                                        ForEach(group.itemTypes) { itemType in
                                            itemTypeRow(itemType, readOnly: true)
                                                .tag(itemType.id)
                                                .padding(.leading, DesignSystem.Spacing.lg)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        .background(DesignSystem.sidebarBackground)
    }

    private func itemTypeRow(_ itemType: ItemType, readOnly: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                Text(itemType.name).font(DesignSystem.Typography.uiRowTitle).lineLimit(1)
                Text("\(cardSetupCount(itemType.templates.count)) · \(fieldCount(itemType.fields.count))")
                    .font(DesignSystem.Typography.uiRowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignSystem.Spacing.xs)
            if readOnly {
                Image(systemName: "lock").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowTight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(itemType.name), \(cardSetupCount(itemType.templates.count)), \(fieldCount(itemType.fields.count))")
        .accessibilityValue(readOnly ? "Read-only" : "Editable")
        .accessibilityIdentifier(readOnly ? "includedItemTypeRow-\(itemType.name)" : "itemTypeRow-\(itemType.name)")
    }

    private func includedGroupButton(_ group: IncludedItemTypeGroup) -> some View {
        Button {
            if !expandedIncludedGroupIDs.insert(group.id).inserted {
                expandedIncludedGroupIDs.remove(group.id)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: expandedIncludedGroupIDs.contains(group.id) ? "chevron.down" : "chevron.right")
                    .frame(width: DesignSystem.Spacing.sm)
                Image(systemName: "folder")
                Text(group.deckPath).lineLimit(1)
                Spacer()
                Text(group.itemTypes.count == 1 ? "1 type" : "\(group.itemTypes.count) types")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.deckPath), \(group.itemTypes.count) item types")
        .accessibilityValue(expandedIncludedGroupIDs.contains(group.id) ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("includedDeckGroup-\(group.deckPath)")
    }

    @ViewBuilder
    private var detail: some View {
        if model.studioDraft != nil {
            MacItemTypeStudioView(model: model, onSaved: onTemplatesChanged)
        } else if let itemType = model.selectedItemType {
            selectedItemTypeOverview(itemType)
        } else if case .ready = model.loadState {
            ContentUnavailableView {
                Label("Select an Item Type", systemImage: "square.grid.2x2")
            } description: {
                Text("Choose an Item Type, or create one with a prefilled Basic Card setup.")
            }
        } else {
            ProgressView()
        }
    }

    private func selectedItemTypeOverview(_ itemType: ItemType) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(itemType.name)
                        .font(DesignSystem.Typography.uiSection)
                        .accessibilityIdentifier("templatesDetailTitle-\(itemType.name)")
                    Text("\(fieldCount(itemType.fields.count)) · \(cardSetupCount(itemType.templates.count))")
                        .foregroundStyle(.secondary)
                    if let group = model.selectedIncludedGroup {
                        Text("From \(group.deckPath) · Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("includedItemTypeOwner")
                    }
                }
                Spacer()
                if model.isSelectedItemTypeReadOnly {
                    Button("Unlock for Editing…", systemImage: "lock.open") {
                        Task { await prepareUnlock(itemType) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                    .accessibilityIdentifier("unlockIncludedItemType")
                    Button("Duplicate as Item Type…", systemImage: "plus.square.on.square") {
                        duplicateName = "\(itemType.name) Copy"
                        showDuplicatePrompt = true
                    }
                    .accessibilityIdentifier("duplicateIncludedItemType")
                } else {
                    Button("Edit in Studio", systemImage: "pencil") {
                        _ = model.beginEditingSelectedItemType()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editItemType")
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await prepareDeleteSelectedItemType() }
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("deleteItemType")
                }
            }
            .padding(DesignSystem.Spacing.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    overviewSection("Fields") {
                        ForEach(itemType.fields) { field in
                            HStack {
                                Text(field.name)
                                Spacer()
                                Text(field.type.studioDisplayName).foregroundStyle(.secondary)
                                Text(field.isRequired ? "Required" : "Optional").foregroundStyle(.tertiary)
                            }
                            .accessibilityIdentifier("itemTypeFieldRow-\(field.name)")
                        }
                    }
                    overviewSection("Card setups") {
                        ForEach(itemType.templates) { setup in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(setup.name)
                                    Text(setup.interaction.studioAnswerMethodName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(setup.layout.displayName).foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier(model.isSelectedItemTypeReadOnly ? "includedCardSetupRow-\(setup.name)" : "cardSetupRow-\(setup.name)")
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.detailBackground)
    }

    private func overviewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title).font(DesignSystem.Typography.uiTitle)
            VStack(spacing: DesignSystem.Spacing.sm) { content() }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var deleteDialogTitle: String {
        "Delete \(model.selectedItemType?.name ?? "item type")?"
    }

    private func prepareDeleteSelectedItemType() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let count = try await model.selectedItemTypeDeletionImpact()
            guard count == 0 else {
                actionError = "Remove the \(count) existing item\(count == 1 ? "" : "s") before deleting this Item Type."
                return
            }
            showDeleteConfirmation = true
        } catch { actionError = error.localizedDescription }
    }

    private func deleteSelectedItemType() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.deleteSelectedItemType()
            actionError = nil
            await onTemplatesChanged()
        } catch { actionError = error.localizedDescription }
    }

    private func repair(_ definition: QuarantinedItemTypeDefinition) async {
        isWorking = true
        defer { isWorking = false; definitionToRepair = nil }
        do {
            _ = try await model.repairDefinition(definition)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    private func prepareUnlock(_ itemType: ItemType) async {
        isWorking = true
        defer { isWorking = false }
        do {
            pendingUnlock = PendingItemTypeUnlock(
                itemTypeID: itemType.id,
                itemTypeName: itemType.name,
                impact: try await model.editingImpactForIncludedItemType(id: itemType.id)
            )
        } catch { actionError = error.localizedDescription }
    }

    private func unlockItemType(_ requested: PendingItemTypeUnlock) async {
        isWorking = true
        defer { isWorking = false; pendingUnlock = nil }
        do {
            _ = try await model.unlockItemType(id: requested.itemTypeID)
            actionError = nil
            await onTemplatesChanged()
        } catch { actionError = error.localizedDescription }
    }

    private func duplicateSelectedItemType() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.duplicateSelectedIncludedItemType(name: duplicateName)
            actionError = nil
            await onTemplatesChanged()
        } catch { actionError = error.localizedDescription }
    }

    private func unlockImpactMessage(_ impact: ItemTypeEditingImpact) -> String {
        let itemText = impact.itemCount == 1 ? "1 existing item" : "\(impact.itemCount) existing items"
        let deckText = impact.deckCount == 1 ? "1 deck" : "\(impact.deckCount) decks"
        return "This definition is used by \(itemText) across \(deckText). Unlocking makes it editable without changing its stable identity."
    }

    private func cardSetupCount(_ count: Int) -> String {
        count == 1 ? "1 Card setup" : "\(count) Card setups"
    }

    private func fieldCount(_ count: Int) -> String {
        count == 1 ? "1 field" : "\(count) fields"
    }
}

extension FieldType {
    var studioDisplayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .audio: "Audio"
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        case .number: "Number"
        case .cloze: "Cloze"
        }
    }
}

extension Interaction {
    var studioAnswerMethodName: String {
        switch self {
        case .reveal: "Show answer"
        case .type: "Type answer"
        case .choose: "Choose"
        case .record: "Record"
        case .audioSubmission: "Audio submission"
        case .cloze: "Cloze"
        case .arrange: "Arrange"
        }
    }
}
