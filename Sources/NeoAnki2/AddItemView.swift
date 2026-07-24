import NeoAnkiCore
import SwiftUI

struct AddItemView: View {
    @Bindable var model: ItemsModel
    var onDismiss: () -> Void = {}

    @State private var fieldText: [UUID: String] = [:]
    @State private var isSaving = false

    private var itemType: ItemType? { model.itemType }

    var body: some View {
        Form {
            if model.itemTypes.count > 1 {
                Section("Item Type") {
                    Picker("Type", selection: addItemTypeBinding) {
                        ForEach(model.itemTypes) { type in
                            Text(type.name).tag(type.id)
                        }
                    }
                    .accessibilityIdentifier("addItemTypePicker")
                }
            }

            if let itemType {
                Section(itemType.name) {
                    ForEach(itemType.fields.filter(\.supportsTextInput)) { field in
                        TextField(fieldLabel(field), text: binding(for: field.id))
                            .accessibilityIdentifier("field-\(field.name)")
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add Item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onDismiss() }
                    .accessibilityIdentifier("cancelAddItem")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving || !canSave)
                .accessibilityIdentifier("saveAddItem")
            }
        }
        .frame(minWidth: 420, minHeight: 220)
        .onAppear {
            resetFieldText()
        }
        .onChange(of: model.addItemTypeID) { _, _ in
            resetFieldText()
        }
    }

    private var addItemTypeBinding: Binding<ItemType.ID> {
        Binding(
            get: { model.addItemTypeID ?? model.itemTypes.first!.id },
            set: { model.addItemTypeID = $0 }
        )
    }

    private var canSave: Bool {
        guard let itemType else { return false }
        return itemType.fields
            .filter(\.supportsTextInput)
            .filter(\.isRequired)
            .allSatisfy { field in
                !fieldText[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
    }

    private func fieldLabel(_ field: FieldDef) -> String {
        field.isRequired ? field.name : "\(field.name) (optional)"
    }

    private func binding(for fieldID: UUID) -> Binding<String> {
        Binding(
            get: { fieldText[fieldID, default: ""] },
            set: { fieldText[fieldID] = $0 }
        )
    }

    private func resetFieldText() {
        guard let itemType else {
            fieldText = [:]
            return
        }
        fieldText = Dictionary(
            uniqueKeysWithValues: itemType.fields.filter(\.supportsTextInput).map { ($0.id, "") }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if await model.addItem(fieldText: fieldText) {
            onDismiss()
        }
    }
}
