import NeoAnkiCore
import SwiftUI

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ItemsModel

    @State private var fieldText: [UUID: String] = [:]
    @State private var isSaving = false

    private var itemType: ItemType? { model.itemType }

    var body: some View {
        Form {
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
                Button("Cancel") { dismiss() }
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
            guard fieldText.isEmpty, let itemType else { return }
            fieldText = Dictionary(
                uniqueKeysWithValues: itemType.fields.filter(\.supportsTextInput).map { ($0.id, "") }
            )
        }
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

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if await model.addItem(fieldText: fieldText) {
            dismiss()
        }
    }
}
