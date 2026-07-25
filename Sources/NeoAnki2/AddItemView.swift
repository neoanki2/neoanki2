import NeoAnkiCore
import SwiftUI

struct AddItemView: View {
    @Bindable var model: ItemsModel
    @Bindable var decksModel: DecksModel
    var onDismiss: () -> Void = {}

    @State private var fieldSpans: [UUID: [Span]] = [:]
    @State private var fieldText: [UUID: String] = [:]
    @State private var fieldMedia: [UUID: MediaRef] = [:]
    @State private var fieldMediaAltText: [UUID: String] = [:]
    @State private var fieldClozeBlanks: [UUID: [ClozeSpan]] = [:]
    @State private var selectedDeckID: UUID?
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

            if !decksModel.summaries.isEmpty || selectedDeckID != nil {
                Section("Deck") {
                    Picker("Deck", selection: $selectedDeckID) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(decksModel.summaries) { deck in
                            Text(deck.name).tag(Optional(deck.id))
                        }
                    }
                    .accessibilityIdentifier("addItemDeckPicker")
                }
            }

            if let itemType {
                Section(itemType.name) {
                    ForEach(itemType.fields) { field in
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
        .neoAnkiFormTypography()
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
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            selectedDeckID = model.addItemDeckID
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
            if let kind = field.type.mediaKind {
                MediaFieldEditor(
                    label: fieldLabel(field),
                    kind: kind,
                    media: mediaBinding(for: field.id),
                    altText: mediaAltTextBinding(for: field.id),
                    mediaStore: model.mediaStore,
                    accessibilityIdentifier: "field-\(field.name)"
                )
            }
        case .cloze:
            ClozeFieldEditor(
                label: fieldLabel(field),
                text: textBinding(for: field.id),
                blanks: clozeBlanksBinding(for: field.id),
                accessibilityIdentifier: "field-\(field.name)"
            )
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
        return itemType.fields.allSatisfy { field in
            guard field.isRequired else { return true }
            return !fieldPlainContent(for: field).isEmpty
        }
    }

    private func fieldLabel(_ field: FieldDef) -> String {
        field.isRequired ? field.name : "\(field.name) (optional)"
    }

    private func fieldPlainContent(for field: FieldDef) -> String {
        switch field.type {
        case .text, .richText:
            return SpanFormatting.plainText(from: fieldSpans[field.id, default: []])
        case .number, .cloze:
            return fieldText[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        case .audio, .image, .gif, .video:
            return fieldMedia[field.id] == nil ? "" : "media"
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

    private func mediaBinding(for fieldID: UUID) -> Binding<MediaRef?> {
        Binding(
            get: { fieldMedia[fieldID] },
            set: { fieldMedia[fieldID] = $0 }
        )
    }

    private func mediaAltTextBinding(for fieldID: UUID) -> Binding<String> {
        Binding(
            get: { fieldMediaAltText[fieldID, default: ""] },
            set: { fieldMediaAltText[fieldID] = $0 }
        )
    }

    private func clozeBlanksBinding(for fieldID: UUID) -> Binding<[ClozeSpan]> {
        Binding(
            get: { fieldClozeBlanks[fieldID, default: []] },
            set: { fieldClozeBlanks[fieldID] = $0 }
        )
    }

    private func resetFields() {
        guard let itemType else {
            fieldSpans = [:]
            fieldText = [:]
            fieldMedia = [:]
            fieldMediaAltText = [:]
            fieldClozeBlanks = [:]
            return
        }

        fieldSpans = Dictionary(
            uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .text || $0.type == .richText }
                .map { ($0.id, []) }
        )
        fieldText = Dictionary(
            uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .number || $0.type == .cloze }
                .map { ($0.id, "") }
        )
        fieldMedia = [:]
        fieldMediaAltText = [:]
        fieldClozeBlanks = Dictionary(
            uniqueKeysWithValues: itemType.fields
                .filter { $0.type == .cloze }
                .map { ($0.id, []) }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if await model.addItem(
            fieldSpans: fieldSpans,
            fieldText: fieldText,
            fieldMedia: fieldMedia,
            fieldMediaAltText: fieldMediaAltText,
            fieldClozeBlanks: fieldClozeBlanks,
            deckID: selectedDeckID
        ) {
            onDismiss()
        }
    }
}
