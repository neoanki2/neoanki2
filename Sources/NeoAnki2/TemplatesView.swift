import NeoAnkiCore
import SwiftUI

struct TemplatesView: View {
    @Bindable var model: TemplatesModel
    var onTemplatesChanged: () async -> Void = {}

    @State private var editingTemplate: Template?
    @State private var editingItemType: ItemType?
    @State private var isAddingTemplate = false
    @State private var isAddingItemType = false
    @State private var showDeleteItemTypeConfirm = false
    @State private var canDeleteSelectedItemType = false

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("templatesPanel")
        .task {
            await model.load()
        }
        .onChange(of: model.selectedItemTypeID) { _, _ in
            editingItemType = nil
            editingTemplate = nil
            isAddingTemplate = false
            Task { await refreshDeleteAvailability() }
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
        } message: {
            Text("This removes the item type and its templates. Items must be deleted first.")
        }
    }

    @ViewBuilder
    private var itemTypesSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Types")
                    .font(DesignSystem.Typography.uiSection)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add", systemImage: "plus") {
                    isAddingItemType = true
                }
                .accessibilityIdentifier("addItemTypeToolbar")
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.sm)
            .padding(.bottom, DesignSystem.Spacing.xs)
            .accessibilityIdentifier("templatesItemTypesHeader")

            if let errorMessage = model.errorMessage, !model.isLoading {
                ErrorBanner(message: errorMessage)
            }

            Group {
                if model.isLoading {
                    ProgressView("Loading item types…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.itemTypes.isEmpty {
                    SidebarEmptyState(
                        title: "No Item Types",
                        message: "Create an item type to define fields and templates.",
                        systemImage: "square.grid.2x2",
                        actionTitle: "Add Item Type",
                        action: { isAddingItemType = true },
                        actionIdentifier: "addItemTypeEmptyState"
                    )
                } else {
                    List(model.itemTypes, selection: $model.selectedItemTypeID) { itemType in
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                            Text(itemType.name)
                                .font(DesignSystem.Typography.uiTitle)
                            Text("\(itemType.templates.count) templates · \(itemType.fields.count) fields")
                                .font(DesignSystem.Typography.uiCaption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(itemType.name), \(itemType.templates.count) templates, \(itemType.fields.count) fields"
                        )
                        .accessibilityIdentifier("itemTypeRow-\(itemType.name)")
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.sidebarBackground)
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
                Text(itemType.name)
                    .font(DesignSystem.Typography.uiSection)
                    .accessibilityIdentifier("templatesDetailTitle-\(itemType.name)")
                Spacer()
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
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    fieldsSection(for: itemType)
                    templatesSection(for: itemType)
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
    private func templatesSection(for itemType: ItemType) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Templates")
                    .font(DesignSystem.Typography.uiTitle)
                Spacer()
                Button("Add Template", systemImage: "plus") {
                    isAddingTemplate = true
                }
                .accessibilityIdentifier("addTemplateToolbar")
            }

            if itemType.templates.isEmpty {
                ContentUnavailableView {
                    Label("No Templates", systemImage: "doc.plaintext")
                } description: {
                    Text("Add a template to generate study cards from items.")
                } actions: {
                    Button("Add Template") { isAddingTemplate = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("addTemplateEmptyState")
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(itemType.templates) { template in
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
        case .cloze:
            "Cloze"
        case .arrange:
            "Arrange"
        }
    }
}
