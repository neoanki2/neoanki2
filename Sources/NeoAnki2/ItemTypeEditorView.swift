import NeoAnkiCore
import SwiftUI

struct ItemTypeEditorView: View {
    @Bindable var model: TemplatesModel
    var onDismiss: () -> Void = {}

    let editingItemType: ItemType?
    private let initialDraft: ItemTypeDraft

    @State private var draft: ItemTypeDraft
    @State private var isSaving = false
    @State private var showDiscardConfirmation = false

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
                ForEach($draft.fields) { $field in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            TextField("Field name", text: $field.name)
                                .accessibilityIdentifier("itemTypeField-\(field.id.uuidString)")

                            Picker("Type", selection: $field.type) {
                                ForEach(FieldTypeLabels.authoringTypes, id: \.self) { type in
                                    Text(FieldTypeLabels.name(for: type)).tag(type)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .accessibilityIdentifier("itemTypeFieldType-\(field.id.uuidString)")

                            Toggle("Required", isOn: $field.isRequired)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Required")

                            if draft.fields.count > 2 {
                                Button(role: .destructive) {
                                    draft.fields.removeAll { $0.id == field.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove field \(field.name)")
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
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your unsaved item type changes will be lost.")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

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

    private func requestDismissal() {
        switch EditorDecisionState.dismissalDecision(initial: initialDraft, current: draft) {
        case .dismiss:
            onDismiss()
        case .confirmDiscard:
            showDiscardConfirmation = true
        }
    }
}
