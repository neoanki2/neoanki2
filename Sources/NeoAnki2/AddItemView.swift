import NeoAnkiCore
import NeoAnkiSharedUI
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
    @State private var occlusionDraftReferences: [MediaRef] = []
    @State private var fieldOcclusions: [UUID: ImageOcclusionContent] = [:]
    @State private var fieldClozeBlanks: [UUID: [ClozeSpan]] = [:]
    @State private var actionError: String?
    @State private var showTypeChooser = false
    @State private var deckRequestGeneration = 0
    @State private var pendingDeckID: UUID?
    @State private var showDeckChangeConfirmation = false
    @State private var selectedDeckID: UUID?
    @State private var isSaving = false
    @State private var processingAttachments = 0
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
        _selectedDeckID = State(
            initialValue: editingItem?.deckID ?? model.addItemDeckID
        )
    }

    private var itemType: ItemType? { editingItemType ?? model.itemType }
    private var isEditing: Bool { editingItem != nil }

    var body: some View {
        Form {
            if !isEditing {
                Section {
                    Picker("Deck", selection: deckBinding) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(decksModel.summaries) { deck in Text(deck.name).tag(Optional(deck.id)) }
                    }.accessibilityIdentifier("addItemDeckPicker")
                    Picker("Item type", selection: addItemTypeBinding) {
                        Text("Choose a type").tag(ItemType.ID?.none)
                        ForEach(model.policyItemTypes) { type in Text(type.name).tag(Optional(type.id)) }
                    }
                    .accessibilityIdentifier("addItemTypePicker")
                    .disabled(processingAttachments > 0)
                    Button("Use another type…") { showTypeChooser = true }
                        .disabled(processingAttachments > 0)
                }
            }

            if let itemType {
                if !isEditing {
                    DictionaryFieldLookupSection(fields: itemType.fields) { id in
                        Binding(
                            get: { SpanFormatting.plainText(from: fieldSpans[id] ?? []) },
                            set: { fieldSpans[id] = $0.isEmpty ? [] : [Span($0)] }
                        )
                    }.id(itemType.id)
                }
                Section {
                    ForEach(itemType.fields) { field in
                        fieldEditor(for: field)
                    }
                }
            }

            if let errorMessage = actionError ?? model.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                }
            }
        }
        .environment(\.attachmentProcessing, processingAttachments > 0)
        .onPreferenceChange(AttachmentProcessingPreferenceKey.self) { processingAttachments = $0 }
        .formStyle(.grouped)
        .neoAnkiFormTypography()
        .navigationTitle(isEditing ? "Edit Item" : "Add Item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { requestDismissal() }
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(isEditing ? "cancelEditItem" : "cancelAddItem")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || processingAttachments > 0 || !canSave)
                .accessibilityIdentifier(isEditing ? "saveEditItem" : "saveAddItem")
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .interactiveDismissDisabled(isSaving || initialSnapshot != currentSnapshot)
        .onAppear {
            initializeIfNeeded()
        }
        .task {
            guard !isEditing else { return }
            await model.configureAddItem(for: selectedDeckID)
        }
        .onChange(of: model.addItemTypeID) { _, _ in
            guard !isEditing else { return }
            resetFields()
            initialSnapshot = currentSnapshot
        }
        .sheet(isPresented: $showTypeChooser) {
            ItemTypeChooserView(library: model.library, deckID: selectedDeckID) { type in
                await model.configureAddItem(for: selectedDeckID, resolveSelection: false)
                addItemTypeBinding.wrappedValue = type.id
            }
        }
        .confirmationDialog("Use this type in the new deck?", isPresented: $showDeckChangeConfirmation, titleVisibility: .visible) {
            if pendingDeckID != nil {
                Button("Attach Type and Keep Content") {
                    Task {
                        do {
                            if let id = itemType?.id, let deck = pendingDeckID { try await model.library.attachItemType(id: id, to: deck) }
                            selectedDeckID = pendingDeckID; model.addItemDeckID = pendingDeckID
                            await model.configureAddItem(for: selectedDeckID, resolveSelection: false)
                        } catch { actionError = error.localizedDescription }
                    }
                }
            }
            Button("Clear Content and Change Deck", role: .destructive) {
                Task {
                    selectedDeckID = pendingDeckID; model.addItemDeckID = pendingDeckID
                    await model.configureAddItem(for: selectedDeckID)
                    resetFields()
                }
            }
            Button("Keep Original Deck", role: .cancel) {}
        } message: { Text("The current type is not available in that deck. Your entered content has been kept.") }
        .confirmationDialog(
            "Discard item changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { closeEditor() }
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
        case .imageOcclusion:
            ImageOcclusionFieldEditor(label: fieldLabel(field), content: Binding(
                get: { fieldOcclusions[field.id] }, set: { value in
                    if let value { occlusionDraftReferences.append(value.image) }
                    fieldOcclusions[field.id] = value
                }
            ), mediaStore: model.mediaStore)
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

    private var deckBinding: Binding<UUID?> {
        Binding(get: { selectedDeckID }, set: { deckID in
            guard deckID != selectedDeckID, !isSaving, processingAttachments == 0 else { return }
            deckRequestGeneration += 1
            let generation = deckRequestGeneration
            Task {
                do {
                    let choices = try await model.library.authoringItemTypes(for: deckID)
                    guard generation == deckRequestGeneration, !isSaving else { return }
                    if hasEnteredContent, let id = itemType?.id, !choices.itemTypes.contains(where: { $0.id == id }) {
                        pendingDeckID = deckID; showDeckChangeConfirmation = true
                    } else {
                        selectedDeckID = deckID; model.addItemDeckID = deckID
                        await model.configureAddItem(for: deckID, resolveSelection: !hasEnteredContent)
                    }
                } catch { if generation == deckRequestGeneration { actionError = error.localizedDescription } }
            }
        })
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
            || !fieldOcclusions.isEmpty
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
        fieldOcclusions = snapshot.fieldOcclusions
        fieldClozeBlanks = snapshot.fieldClozeBlanks
    }

    private var currentSnapshot: ItemEditorSnapshot {
        ItemEditorSnapshot(
            fieldSpans: fieldSpans,
            fieldText: fieldText,
            fieldMedia: fieldMedia,
            fieldMediaAltText: fieldMediaAltText,
            fieldClozeBlanks: fieldClozeBlanks,
            fieldOcclusions: fieldOcclusions
        )
    }

    private func closeEditor() {
        let refs = occlusionDraftReferences + fieldOcclusions.values.map(\.image)
        Task { for ref in refs { try? await model.mediaStore?.discardDraftReference(ref) } }
        onDismiss()
    }

    private func requestDismissal() {
        guard !isSaving else { return }
        if initialSnapshot != currentSnapshot {
            showDiscardConfirmation = true
        } else {
            closeEditor()
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
        guard !isSaving, processingAttachments == 0 else { return }
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
                fieldClozeBlanks: fieldClozeBlanks,
                fieldOcclusions: fieldOcclusions
            )
        } else {
            didSave = await model.addItem(
                fieldSpans: fieldSpans,
                fieldText: fieldText,
                fieldMedia: fieldMedia,
                fieldMediaAltText: fieldMediaAltText,
                fieldClozeBlanks: fieldClozeBlanks,
                fieldOcclusions: fieldOcclusions,
                deckID: selectedDeckID
            )
        }
        if didSave {
            closeEditor()
        }
    }
}
