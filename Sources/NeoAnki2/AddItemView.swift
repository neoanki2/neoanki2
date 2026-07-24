import NeoAnkiCore
import SwiftUI

struct AddItemView: View {
    @Bindable var model: ItemsModel
    var onDismiss: () -> Void = {}

    @State private var fieldSpans: [UUID: [Span]] = [:]
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
                        fieldEditor(for: field)
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
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            resetFields()
        }
        .onChange(of: model.addItemTypeID) { _, _ in
            resetFields()
        }
    }

    @ViewBuilder
    private func fieldEditor(for field: FieldDef) -> some View {
        switch field.type {
        case .text, .richText:
            RichTextFieldEditor(
                label: fieldLabel(field),
                spans: spanBinding(for: field.id),
                accessibilityIdentifier: "field-\(field.name)"
            )
        case .number:
            TextField(fieldLabel(field), text: textBinding(for: field.id))
                .accessibilityIdentifier("field-\(field.name)")
        case .audio, .image, .gif, .video:
            EmptyView()
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
                !fieldPlainText(for: field).isEmpty
            }
    }

    private func fieldLabel(_ field: FieldDef) -> String {
        field.isRequired ? field.name : "\(field.name) (optional)"
    }

    private func fieldPlainText(for field: FieldDef) -> String {
        switch field.type {
        case .text, .richText:
            return SpanFormatting.plainText(from: fieldSpans[field.id, default: []])
        case .number:
            return fieldText[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        case .audio, .image, .gif, .video:
            return ""
        }
    }

    private func spanBinding(for fieldID: UUID) -> Binding<[Span]> {
        Binding(
            get: { fieldSpans[fieldID, default: []] },
            set: { fieldSpans[fieldID] = $0 }
        )
    }

    private func textBinding(for fieldID: UUID) -> Binding<String> {
        Binding(
            get: { fieldText[fieldID, default: ""] },
            set: { fieldText[fieldID] = $0 }
        )
    }

    private func resetFields() {
        guard let itemType else {
            fieldSpans = [:]
            fieldText = [:]
            return
        }

        fieldSpans = Dictionary(
            uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .text || $0.type == .richText }
                .map { ($0.id, []) }
        )
        fieldText = Dictionary(
            uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .number }
                .map { ($0.id, "") }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if await model.addItem(fieldSpans: fieldSpans, fieldText: fieldText) {
            onDismiss()
        }
    }
}
