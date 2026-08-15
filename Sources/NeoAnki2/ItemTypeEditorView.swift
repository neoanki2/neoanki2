import NeoAnkiCore
import SwiftUI

enum FieldReordering {
    /// Swaps the element at `index` with its neighbour `offset` positions away,
    /// returning the input unchanged when either position is out of bounds.
    static func move<Element>(_ items: [Element], from index: Int, by offset: Int) -> [Element] {
        guard items.indices.contains(index) else { return items }
        let destination = index + offset
        guard items.indices.contains(destination) else { return items }
        var result = items
        result.swapAt(index, destination)
        return result
    }
}

struct ItemTypeEditorView: View {
    @Bindable var model: TemplatesModel
    var onDismiss: () -> Void = {}

    let editingItemType: ItemType?
    private let initialDraft: ItemTypeDraft

    @State private var draft: ItemTypeDraft
    @State private var isSaving = false
    @State private var showDiscardConfirmation = false
    @State private var pendingSchemaImpact: ItemTypeSchemaChangeImpact?

    init(
        model: TemplatesModel,
        editingItemType: ItemType? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onDismiss = onDismiss
        self.editingItemType = editingItemType
        let draft = editingItemType.map(ItemTypeDraft.init) ?? .new
        initialDraft = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section("Item Type") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("itemTypeNameField")
            }

            Section("Fields") {
                ForEach(Array(draft.fields.enumerated()), id: \.element.id) { index, field in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            TextField("Field name", text: $draft.fields[index].name)
                                .labelsHidden()
                                .accessibilityLabel("Field name")
                                .accessibilityIdentifier("itemTypeField-\(field.id.uuidString)")

                            Picker("Type", selection: $draft.fields[index].type) {
                                ForEach(FieldTypeLabels.authoringTypes, id: \.self) { type in
                                    Text(FieldTypeLabels.name(for: type)).tag(type)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .accessibilityIdentifier("itemTypeFieldType-\(field.id.uuidString)")

                            Toggle("Required", isOn: $draft.fields[index].isRequired)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Required")
                                .accessibilityIdentifier("itemTypeFieldRequired-\(field.id.uuidString)")

                            HStack(spacing: DesignSystem.Spacing.rowTight) {
                                // Per-row move buttons stay keyboard-reachable via Tab
                                // + Space. They intentionally carry no keyboard
                                // shortcut: a single shortcut repeated on every row
                                // would be ambiguous about which field it moves.
                                Button {
                                    moveField(from: index, by: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.plain)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                                .disabled(index == 0)
                                .accessibilityLabel("Move field \(field.name) up")
                                .accessibilityIdentifier("moveFieldUp-\(field.id.uuidString)")

                                Button {
                                    moveField(from: index, by: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.plain)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                                .disabled(index == draft.fields.count - 1)
                                .accessibilityLabel("Move field \(field.name) down")
                                .accessibilityIdentifier("moveFieldDown-\(field.id.uuidString)")

                                if draft.fields.count > 2 {
                                    Button(role: .destructive) {
                                        draft.fields.removeAll { $0.id == field.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                                    .accessibilityLabel("Remove field \(field.name)")
                                    .accessibilityIdentifier("removeItemTypeField-\(field.id.uuidString)")
                                }
                            }
                        }
                    }
                }

                Button("Add Field", systemImage: "plus") {
                    draft.fields.append(FieldDraft(name: "Field \(draft.fields.count + 1)"))
                }
                .accessibilityIdentifier("addItemTypeField")
            }

            Section {
                Text("New item types start with a default Card template using the first two fields.")
                    .font(DesignSystem.Typography.uiHint)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                }
            }
        }
        .formStyle(.grouped)
        .neoAnkiFormTypography()
        .navigationTitle(editingItemType == nil ? "Add Item Type" : "Edit Item Type")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { requestDismissal() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelItemTypeEditor")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !draft.isValid)
                .accessibilityIdentifier("saveItemType")
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .confirmationDialog(
            "Discard item type changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { onDismiss() }
                .accessibilityIdentifier("confirmDiscardItemType")
            Button("Keep Editing", role: .cancel) {}
                .accessibilityIdentifier("cancelDiscardItemType")
        } message: {
            Text("Your unsaved item type changes will be lost.")
        }
        .confirmationDialog(
            "Save potentially destructive changes?",
            isPresented: Binding(
                get: { pendingSchemaImpact != nil },
                set: { if !$0 { pendingSchemaImpact = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save Changes", role: .destructive) {
                pendingSchemaImpact = nil
                Task { await persistDraft() }
            }
            .accessibilityIdentifier("confirmRiskyItemTypeChanges")
            Button("Keep Editing", role: .cancel) { pendingSchemaImpact = nil }
                .accessibilityIdentifier("cancelRiskyItemTypeChanges")
        } message: {
            if let pendingSchemaImpact {
                Text(schemaImpactMessage(pendingSchemaImpact))
            }
        }
    }

    private func moveField(from index: Int, by offset: Int) {
        draft.fields = FieldReordering.move(draft.fields, from: index, by: offset)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if let editingItemType {
            guard let impact = await model.schemaChangeImpact(
                draft,
                editingID: editingItemType.id
            ) else { return }
            if impact.requiresConfirmation {
                pendingSchemaImpact = impact
                return
            }
        }

        await persistDraft(isSavingAlready: true)
    }

    private func persistDraft(isSavingAlready: Bool = false) async {
        if !isSavingAlready { isSaving = true }
        defer { if !isSavingAlready { isSaving = false } }

        let saved: Bool
        if let editingItemType {
            saved = await model.updateItemType(draft, editingID: editingItemType.id)
        } else {
            saved = await model.createItemType(draft)
        }

        if saved {
            onDismiss()
        }
    }

    private func schemaImpactMessage(_ impact: ItemTypeSchemaChangeImpact) -> String {
        var changes: [String] = []
        if !impact.removedPopulatedFields.isEmpty {
            changes.append("Removed: \(impact.removedPopulatedFields.joined(separator: ", ")).")
        }
        if !impact.typeChangedPopulatedFields.isEmpty {
            changes.append("Type changed: \(impact.typeChangedPopulatedFields.joined(separator: ", ")).")
        }
        let items = impact.affectedItemCount == 1
            ? "1 existing item has stored content in these fields."
            : "\(impact.affectedItemCount) existing items have stored content in these fields."
        return "\(items) That content may no longer be usable after this edit. \(changes.joined(separator: " "))"
    }

    private func requestDismissal() {
        switch EditorDecisionState.dismissalDecision(initial: initialDraft, current: draft) {
        case .dismiss:
            onDismiss()
        case .confirmDiscard:
            showDiscardConfirmation = true
        }
    }
}
