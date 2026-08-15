import NeoAnkiCore
import SwiftUI

struct TemplatesView: View {
    @Bindable var model: TemplatesModel
    @Binding private var isTemplateEditorPresented: Bool
    var onTemplatesChanged: () async -> Void = {}

    @State private var editingTemplate: Template?
    @State private var editingItemType: ItemType?
    @State private var isAddingTemplate = false
    @State private var isAddingItemType = false
    @State private var showDeleteItemTypeConfirm = false
    @State private var canDeleteSelectedItemType = false
    @State private var definitionToRepair: QuarantinedItemTypeDefinition?
    @State private var expandedIncludedGroupIDs: Set<UUID> = []
    @State private var showDuplicatePrompt = false
    @State private var duplicateName = ""

    init(
        model: TemplatesModel,
        isTemplateEditorPresented: Binding<Bool> = .constant(false),
        onTemplatesChanged: @escaping () async -> Void = {}
    ) {
        self.model = model
        _isTemplateEditorPresented = isTemplateEditorPresented
        self.onTemplatesChanged = onTemplatesChanged
    }

    var body: some View {
        Group {
            if isTemplateEditorActive, let itemType = model.selectedItemType {
                NavigationStack {
                    TemplateEditorView(
                        model: model,
                        itemType: itemType,
                        editingTemplate: editingTemplate,
                        onDismiss: dismissTemplateEditor
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignSystem.detailBackground)
            } else {
                HSplitView {
                    itemTypesSidebar
                        .frame(
                            minWidth: DesignSystem.sidebarMin,
                            idealWidth: DesignSystem.sidebarIdeal,
                            maxWidth: DesignSystem.sidebarMax
                        )
                        .layoutPriority(1)

                    itemTypeDetail
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("templatesPanel")
        .task {
            await model.load()
        }
        .onChange(of: model.selectedItemTypeID) { _, _ in
            editingItemType = nil
            editingTemplate = nil
            isAddingTemplate = false
            if let group = model.selectedIncludedGroup {
                expandedIncludedGroupIDs.insert(group.id)
            }
            Task { await refreshDeleteAvailability() }
        }
        .onChange(of: isTemplateEditorActive, initial: true) { _, active in
            isTemplateEditorPresented = active
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteItemTypeConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Item Type", role: .destructive) {
                Task {
                    if await model.deleteSelectedItemType() {
                        await onTemplatesChanged()
                        await refreshDeleteAvailability()
                    }
                }
            }
            .accessibilityIdentifier("confirmDeleteItemType")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelDeleteItemType")
        } message: {
            Text("This removes the item type and its templates. Items must be deleted first.")
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
                Task {
                    _ = await model.repairDefinition(definitionToRepair)
                    self.definitionToRepair = nil
                }
            }
            .accessibilityIdentifier("confirmRepairItemType")
            Button("Cancel", role: .cancel) { definitionToRepair = nil }
                .accessibilityIdentifier("cancelRepairItemType")
        } message: {
            Text("NeoAnki2 will preserve the unreadable definition, then create a minimal editable replacement. Existing items are not deleted.")
        }
        .alert("Duplicate as Item Type", isPresented: $showDuplicatePrompt) {
            TextField("Name", text: $duplicateName)
                .accessibilityLabel("New Item Type Name")
                .accessibilityIdentifier("duplicateItemTypeName")
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") {
                Task {
                    if await model.duplicateSelectedItemType(name: duplicateName) {
                        await onTemplatesChanged()
                    }
                }
            }
            .disabled(duplicateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("confirmDuplicateItemType")
        } message: {
            Text("The copy will be an independent, editable Item Type.")
        }
    }

    private var isTemplateEditorActive: Bool {
        isAddingTemplate || editingTemplate != nil
    }

    @ViewBuilder
    private var itemTypesSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Item Types")
                    .font(DesignSystem.Typography.uiSection)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("templatesItemTypesHeader")
                Spacer()
                Button("Add", systemImage: "plus") {
                    isAddingItemType = true
                }
                .accessibilityIdentifier("addItemTypeToolbar")
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.sm)
            .padding(.bottom, DesignSystem.Spacing.xs)

            if let errorMessage = model.errorMessage, !model.isLoading {
                ErrorBanner(message: errorMessage)
            }

            ForEach(model.corruptedDefinitions) { corruption in
                HStack {
                    Text(corruption.name)
                        .lineLimit(1)
                    Spacer()
                    Button("Repair") {
                        definitionToRepair = corruption
                    }
                    .accessibilityLabel("Repair damaged item type \(corruption.name)")
                    .accessibilityIdentifier("repairItemType-\(corruption.name)")
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }

            Group {
                if model.isLoading {
                    ProgressView("Loading item types…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.itemTypes.isEmpty && model.includedItemTypeGroups.isEmpty {
                    SidebarEmptyState(
                        title: "No Item Types",
                        message: "Create an item type to define fields and templates.",
                        systemImage: "square.grid.2x2",
                        actionTitle: "Add Item Type",
                        action: { isAddingItemType = true },
                        actionIdentifier: "addItemTypeEmptyState"
                    )
                } else {
                    List(selection: $model.selectedItemTypeID) {
                        Section {
                            ForEach(model.itemTypes) { itemType in
                                itemTypeRow(itemType, readOnly: false)
                                    .tag(itemType.id)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.sidebarBackground)
    }

    private func itemTypeRow(_ itemType: ItemType, readOnly: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                Text(itemType.name)
                    .font(DesignSystem.Typography.uiRowTitle)
                    .lineLimit(1)
                Text(itemTypeSummary(itemType))
                    .font(DesignSystem.Typography.uiRowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignSystem.Spacing.xs)

            if readOnly {
                Image(systemName: "lock")
                    .font(DesignSystem.Typography.uiRowMeta)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowTight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(itemType.name), \(itemType.templates.count) templates, \(itemType.fields.count) fields"
        )
        .accessibilityValue(readOnly ? "Read-only" : "Editable")
        .accessibilityIdentifier(
            readOnly ? "includedItemTypeRow-\(itemType.name)" : "itemTypeRow-\(itemType.name)"
        )
    }

    private func itemTypeSummary(_ itemType: ItemType) -> String {
        let templateNoun = itemType.templates.count == 1 ? "template" : "templates"
        let fieldNoun = itemType.fields.count == 1 ? "field" : "fields"
        return "\(itemType.templates.count) \(templateNoun) · \(itemType.fields.count) \(fieldNoun)"
    }

    private func includedGroupButton(_ group: IncludedItemTypeGroup) -> some View {
        Button {
            if expandedIncludedGroupIDs.contains(group.id) {
                expandedIncludedGroupIDs.remove(group.id)
            } else {
                expandedIncludedGroupIDs.insert(group.id)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(
                    systemName: expandedIncludedGroupIDs.contains(group.id)
                        ? "chevron.down"
                        : "chevron.right"
                )
                .font(DesignSystem.Typography.sidebarRowMeta)
                .frame(width: DesignSystem.Spacing.sm)
                .accessibilityHidden(true)

                Image(systemName: "folder")
                    .imageScale(.medium)
                    .accessibilityHidden(true)

                Text(group.deckPath)
                    .font(DesignSystem.Typography.sidebarRowTitle)
                    .lineLimit(1)

                Spacer(minLength: DesignSystem.Spacing.xs)

                Text(includedTypeCount(group.itemTypes.count))
                    .font(DesignSystem.Typography.sidebarRowMeta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.deckPath), \(includedTypeCount(group.itemTypes.count))")
        .accessibilityHint("Shows read-only item types provided by this deck")
        .accessibilityValue(
            expandedIncludedGroupIDs.contains(group.id) ? "Expanded" : "Collapsed"
        )
        .accessibilityIdentifier("includedDeckGroup-\(group.deckPath)")
    }

    private func includedTypeCount(_ count: Int) -> String {
        count == 1 ? "1 type" : "\(count) types"
    }

    @ViewBuilder
    private var itemTypeDetail: some View {
        if isAddingItemType {
            NavigationStack {
                ItemTypeEditorView(model: model, onDismiss: dismissItemTypeEditor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.detailBackground)
        } else if let editingItemType {
            NavigationStack {
                ItemTypeEditorView(
                    model: model,
                    editingItemType: editingItemType,
                    onDismiss: dismissItemTypeEditor
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.detailBackground)
        } else if isAddingTemplate, let itemType = model.selectedItemType {
            NavigationStack {
                TemplateEditorView(
                    model: model,
                    itemType: itemType,
                    onDismiss: dismissTemplateEditor
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.detailBackground)
        } else if let editingTemplate, let itemType = model.selectedItemType {
            NavigationStack {
                TemplateEditorView(
                    model: model,
                    itemType: itemType,
                    editingTemplate: editingTemplate,
                    onDismiss: dismissTemplateEditor
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.detailBackground)
        } else if model.isLoading {
            ProgressView("Loading item types…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let itemType = model.selectedItemType {
            itemTypeDetailContent(for: itemType)
                .task(id: itemType.id) {
                    await refreshDeleteAvailability()
                }
        } else {
            ContentUnavailableView {
                Label("Select an Item Type", systemImage: "square.grid.2x2")
            } description: {
                Text("Choose an item type to edit its fields and templates.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func itemTypeDetailContent(for itemType: ItemType) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                    Text(itemType.name)
                        .font(DesignSystem.Typography.uiSection)
                        .accessibilityIdentifier("templatesDetailTitle-\(itemType.name)")
                    if let group = model.selectedIncludedGroup {
                        Text("From \(group.deckPath) · Read-only")
                            .font(DesignSystem.Typography.uiCaption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("includedItemTypeOwner")
                    }
                }
                Spacer()
                if model.isSelectedItemTypeReadOnly {
                    Button("Duplicate as Item Type…", systemImage: "plus.square.on.square") {
                        duplicateName = "\(itemType.name) Copy"
                        showDuplicatePrompt = true
                    }
                    .accessibilityLabel("Duplicate \(itemType.name) as Item Type")
                    .accessibilityIdentifier("duplicateIncludedItemType")
                } else {
                    Button("Edit", systemImage: "pencil") {
                        editingItemType = itemType
                    }
                    .accessibilityIdentifier("editItemType")
                    if canDeleteSelectedItemType {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            showDeleteItemTypeConfirm = true
                        }
                        .accessibilityIdentifier("deleteItemType")
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    fieldsSection(for: itemType)
                    templatesSection(
                        for: itemType,
                        readOnly: model.isSelectedItemTypeReadOnly
                    )
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.detailBackground)
    }

    @ViewBuilder
    private func fieldsSection(for itemType: ItemType) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Fields")
                .font(DesignSystem.Typography.uiTitle)

            VStack(spacing: 0) {
                ForEach(itemType.fields) { field in
                    HStack {
                        Text(field.name)
                            .font(DesignSystem.Typography.uiBody)
                        Spacer()
                        if field.isRequired {
                            Text("Required")
                                .font(DesignSystem.Typography.uiCaption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Optional")
                                .font(DesignSystem.Typography.uiCaption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .accessibilityIdentifier("itemTypeFieldRow-\(field.name)")

                    if field.id != itemType.fields.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(DesignSystem.sidebarBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func templatesSection(for itemType: ItemType, readOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Templates")
                    .font(DesignSystem.Typography.uiTitle)
                Spacer()
                if !readOnly {
                    Button("Add Template", systemImage: "plus") {
                        isAddingTemplate = true
                    }
                    .accessibilityIdentifier("addTemplateToolbar")
                }
            }

            if itemType.templates.isEmpty {
                ContentUnavailableView {
                    Label("No Templates", systemImage: "doc.plaintext")
                } description: {
                    Text(
                        readOnly
                            ? "This deck-provided definition has no templates."
                            : "Add a template to generate study cards from items."
                    )
                } actions: {
                    if !readOnly {
                        Button("Add Template") { isAddingTemplate = true }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("addTemplateEmptyState")
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(itemType.templates) { template in
                        HStack {
                            if readOnly {
                                HStack {
                                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                                        Text(template.name)
                                            .font(DesignSystem.Typography.uiBody.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(model.templateSummary(template, in: itemType))
                                            .foregroundStyle(.secondary)
                                        Text(interactionLabel(template.interaction))
                                            .font(DesignSystem.Typography.uiCaption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, DesignSystem.Spacing.sm)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(
                                    "\(template.name), \(model.templateSummary(template, in: itemType)), \(interactionLabel(template.interaction)), read-only"
                                )
                                .accessibilityIdentifier("includedTemplateRow-\(template.name)")
                            } else {
                                Button {
                                    editingTemplate = template
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                                            Text(template.name)
                                                .font(DesignSystem.Typography.uiBody.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text(model.templateSummary(template, in: itemType))
                                                .foregroundStyle(.secondary)
                                            Text(interactionLabel(template.interaction))
                                                .font(DesignSystem.Typography.uiCaption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(DesignSystem.Typography.uiCaption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, DesignSystem.Spacing.sm)
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(
                                    "\(template.name), \(model.templateSummary(template, in: itemType)), \(interactionLabel(template.interaction))"
                                )
                                .accessibilityIdentifier("templateRow-\(template.name)")

                                Button("Edit", systemImage: "pencil") {
                                    editingTemplate = template
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit \(template.name)")
                                .accessibilityIdentifier("editTemplate-\(template.name)")
                            }
                        }

                        if template.id != itemType.templates.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .background(DesignSystem.sidebarBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var deleteDialogTitle: String {
        if let name = model.selectedItemType?.name {
            return "Delete \"\(name)\"?"
        }
        return "Delete item type?"
    }

    private func dismissItemTypeEditor() {
        isAddingItemType = false
        editingItemType = nil
        Task { await onTemplatesChanged() }
    }

    private func dismissTemplateEditor() {
        isAddingTemplate = false
        editingTemplate = nil
        Task { await onTemplatesChanged() }
    }

    private func refreshDeleteAvailability() async {
        canDeleteSelectedItemType = await model.canDeleteSelectedItemType()
    }

    private func interactionLabel(_ interaction: Interaction) -> String {
        switch interaction {
        case .reveal:
            "Reveal"
        case .type:
            "Type answer"
        case .choose:
            "Choose"
        case .record:
            "Record"
        case .audioSubmission:
            "Audio Submission"
        case .cloze:
            "Cloze"
        case .arrange:
            "Arrange"
        }
    }
}
