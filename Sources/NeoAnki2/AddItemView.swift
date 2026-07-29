import NeoAnkiCore
import SwiftUI

struct AddItemView: View {
    @Bindable var model: ItemsModel
    @Bindable var decksModel: DecksModel
    let editingItem: Item?
    let editingItemType: ItemType?
    var onDismiss: () -> Void = {}

    @State private var fieldSpans: [UUID: [Span]] = [:]
    @State private var fieldText: [UUID: String] = [:]
    @State private var fieldMedia: [UUID: MediaRef] = [:]
    @State private var fieldMediaAltText: [UUID: String] = [:]
    @State private var fieldClozeBlanks: [UUID: [ClozeSpan]] = [:]
    @State private var selectedDeckID: UUID?
    @State private var isSaving = false
    @State private var didInitialize = false
    @State private var initialSnapshot: ItemEditorSnapshot?
    @State private var showDiscardConfirmation = false
    @State private var showTypeChangeConfirmation = false
    @State private var pendingItemTypeID: UUID?
    @FocusState private var focusedFieldID: UUID?

    init(
        model: ItemsModel,
        decksModel: DecksModel,
        editingItem: Item? = nil,
        editingItemType: ItemType? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.model = model
        self.decksModel = decksModel
        self.editingItem = editingItem
        self.editingItemType = editingItemType
        self.onDismiss = onDismiss
    }

    private var itemType: ItemType? { editingItemType ?? model.itemType }
    private var isEditing: Bool { editingItem != nil }

    var body: some View {
        Form {
            if !isEditing, !decksModel.summaries.isEmpty || selectedDeckID != nil {
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

            if !isEditing {
                Section("Item Type") {
                    Picker("Type", selection: addItemTypeBinding) {
                        Text("Choose an Item Type")
                            .tag(ItemType.ID?.none)
                        if !model.policyItemTypes.isEmpty {
                            Section("For This Deck") {
                                ForEach(model.policyItemTypes) { type in
                                    if model.isRecommendedItemType(type.id) {
                                        Text("\(type.name) — Recommended")
                                            .tag(Optional(type.id))
                                    } else {
                                        Text(type.name)
                                            .tag(Optional(type.id))
                                    }
                                }
                            }
                        }
                        if let retained = model.retainedItemType {
                            Section("Current Item Type") {
                                Text("\(retained.name) — Retained")
                                    .tag(Optional(retained.id))
                            }
                        }
                        Section("Item Types") {
                            ForEach(model.normalItemTypes) { type in
                                Text(type.name).tag(Optional(type.id))
                            }
                        }
                    }
                    .accessibilityLabel("Item Type")
                    .accessibilityHint(
                        "Types included for this deck appear first. Ordinary Item Types are always available."
                    )
                    .accessibilityIdentifier("addItemTypePicker")

                    if model.effectiveItemTypePolicy != nil,
                       model.addItemTypeID == nil {
                        Text("Choose the item type that matches what you want to add.")
                            .font(DesignSystem.Typography.uiCaption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("addItemTypeChoiceRequired")
                    }
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
        .navigationTitle(isEditing ? "Edit Item" : "Add Item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { requestDismissal() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(isEditing ? "cancelEditItem" : "cancelAddItem")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !canSave)
                .accessibilityIdentifier(isEditing ? "saveEditItem" : "saveAddItem")
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            initializeIfNeeded()
        }
        .task {
            guard !isEditing else { return }
            await model.configureAddItem(for: selectedDeckID)
        }
        .onChange(of: selectedDeckID) { _, deckID in
            guard didInitialize, !isEditing else { return }
            model.addItemDeckID = deckID
            let shouldResolve = !hasEnteredContent
            Task {
                await model.configureAddItem(
                    for: deckID,
                    resolveSelection: shouldResolve
                )
            }
        }
        .onChange(of: model.addItemTypeID) { _, _ in
            guard !isEditing else { return }
            resetFields()
            initialSnapshot = currentSnapshot
        }
        .confirmationDialog(
            "Discard item changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { onDismiss() }
                .accessibilityIdentifier("confirmDiscardItem")
            Button("Keep Editing", role: .cancel) {}
                .accessibilityIdentifier("cancelDiscardItem")
        } message: {
            Text("Your unsaved changes will be lost.")
        }
        .confirmationDialog(
            "Change item type and clear entered content?",
            isPresented: $showTypeChangeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Change Item Type", role: .destructive) {
                model.addItemTypeID = pendingItemTypeID
                pendingItemTypeID = nil
            }
            .accessibilityIdentifier("confirmChangeItemType")
            Button("Keep Current Type", role: .cancel) {
                pendingItemTypeID = nil
            }
            .accessibilityIdentifier("cancelChangeItemType")
        } message: {
            Text("Fields differ between item types, so the content already entered will be cleared.")
        }
    }

    @ViewBuilder
    private func fieldEditor(for field: FieldDef) -> some View {
        switch field.type {
        case .text, .richText:
            RichTextFieldEditor(
                label: fieldLabel(field),
                spans: spanBinding(for: field.id),
                accessibilityIdentifier: "field-\(field.name)",
                isFocused: richTextFocusBinding(for: field.id)
            )
        case .number:
            TextField(fieldLabel(field), text: textBinding(for: field.id))
                .focused($focusedFieldID, equals: field.id)
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
            .focused($focusedFieldID, equals: field.id)
        }
    }

    private var addItemTypeBinding: Binding<ItemType.ID?> {
        Binding(
            get: { model.addItemTypeID },
            set: { newValue in
                guard newValue != model.addItemTypeID else { return }
                if hasEnteredContent {
                    pendingItemTypeID = newValue
                    showTypeChangeConfirmation = true
                } else {
                    model.addItemTypeID = newValue
                }
            }
        )
    }

    private var hasEnteredContent: Bool {
        fieldSpans.values.contains {
            !SpanFormatting.plainText(from: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
            || fieldText.values.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            || !fieldMedia.isEmpty
            || fieldMediaAltText.values.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            || fieldClozeBlanks.values.contains { !$0.isEmpty }
    }

    private var canSave: Bool {
        ItemEditorState.canSave(currentSnapshot, itemType: itemType)
    }

    private func fieldLabel(_ field: FieldDef) -> String {
        field.isRequired ? field.name : "\(field.name) (optional)"
    }

    private func spanBinding(for fieldID: UUID) -> Binding<[Span]> {
        Binding(
            get: { fieldSpans[fieldID, default: []] },
            set: { fieldSpans[fieldID] = $0 }
        )
    }

    private func richTextFocusBinding(for fieldID: UUID) -> Binding<Bool> {
        Binding(
            get: { focusedFieldID == fieldID },
            set: { isFocused in
                if isFocused {
                    focusedFieldID = fieldID
                } else if focusedFieldID == fieldID {
                    focusedFieldID = nil
                }
            }
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
        apply(ItemEditorState.empty(for: itemType))
        focusFirstField()
    }

    private func initializeIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        selectedDeckID = editingItem?.deckID ?? model.addItemDeckID
        if let editingItem {
            loadFields(from: editingItem)
        } else {
            resetFields()
        }
        initialSnapshot = currentSnapshot
    }

    private func loadFields(from item: Item) {
        guard let itemType else { return }
        apply(ItemEditorState.hydrated(from: item, itemType: itemType))
        focusFirstField()
    }

    private func apply(_ snapshot: ItemEditorSnapshot) {
        fieldSpans = snapshot.fieldSpans
        fieldText = snapshot.fieldText
        fieldMedia = snapshot.fieldMedia
        fieldMediaAltText = snapshot.fieldMediaAltText
        fieldClozeBlanks = snapshot.fieldClozeBlanks
    }

    private var currentSnapshot: ItemEditorSnapshot {
        ItemEditorSnapshot(
            fieldSpans: fieldSpans,
            fieldText: fieldText,
            fieldMedia: fieldMedia,
            fieldMediaAltText: fieldMediaAltText,
            fieldClozeBlanks: fieldClozeBlanks
        )
    }

    private func requestDismissal() {
        if isEditing, initialSnapshot != currentSnapshot {
            showDiscardConfirmation = true
        } else {
            onDismiss()
        }
    }

    private func focusFirstField() {
        guard let firstFieldID = itemType?.fields.first(where: \.supportsTextInput)?.id else {
            focusedFieldID = nil
            return
        }
        Task { @MainActor in
            await Task.yield()
            focusedFieldID = firstFieldID
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let didSave: Bool
        if let editingItem {
            didSave = await model.updateItem(
                id: editingItem.id,
                fieldSpans: fieldSpans,
                fieldText: fieldText,
                fieldMedia: fieldMedia,
                fieldMediaAltText: fieldMediaAltText,
                fieldClozeBlanks: fieldClozeBlanks
            )
        } else {
            didSave = await model.addItem(
                fieldSpans: fieldSpans,
                fieldText: fieldText,
                fieldMedia: fieldMedia,
                fieldMediaAltText: fieldMediaAltText,
                fieldClozeBlanks: fieldClozeBlanks,
                deckID: selectedDeckID
            )
        }
        if didSave {
            onDismiss()
        }
    }
}
