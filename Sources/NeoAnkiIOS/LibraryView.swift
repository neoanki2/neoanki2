import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import PoemDeckBuilder
import ProseDeckBuilder
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

private func mediaDescriptionPrompt(_ type: FieldType) -> String {
    if type == .audio { return "Audio description (optional)" }
    return [.image, .gif].contains(type) ? "Visual description (required)" : "Visual description (optional)"
}
// Mobile direction: calm native lists, prompt-led browsing, deliberate selection,
// focused authoring, and a single blue forward action. Native toolbar sizing is
// retained; reading content stays within a comfortable iPad measure.
struct LibraryView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var scope: DeckScope = .allDecks
    var embedsNavigation = true
    var navigationPath: Binding<NavigationPath>? = nil
    @State private var searchText = ""
    @State private var isAddingItem = false
    @State private var path = NavigationPath()
    @State private var items: [SavedItemSummary] = []
    @State private var sort: ItemSortOrder = .createdAscending
    @State private var attentionOnly = false
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var pendingDeletion: Set<UUID> = []
    @State private var affectedResponseCount = 0
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    private var visibleItems: [SavedItemSummary] {
        ItemBrowsing.arrange(attentionOnly ? items.filter { $0.schedule?.needsAttention == true } : items,
                             sort: sort, search: searchText)
    }
    private var deckID: UUID? { if case let .deck(id, _) = scope { id } else { nil } }

    var body: some View {
        Group {
            if embedsNavigation { NavigationStack(path: navigationPath ?? $path) { browser.modifier(MobileTabBarVisibility()) } }
            else { browser }
        }
        .sheet(isPresented: $isAddingItem, onDismiss: { Task { await load() } }) {
            AddItemView(model: model, deckID: deckID)
        }
        .task { await load() }
        .onChange(of: model.items) { _, _ in Task { await load() } }
        .onChange(of: model.route, initial: true) { _, route in
            guard embedsNavigation else { return }
            if case let .itemDetail(id) = route {
                if let navigationPath { navigationPath.wrappedValue = NavigationPath([id]) } else { path = NavigationPath([id]) }
            }
        }
        .confirmationDialog(pendingDeletion.count == 1 ? "Delete this item?" : "Delete these items?",
                            isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = pendingDeletion
                Task { await perform { try await model.deleteItems(ids) } }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(affectedResponseCount > 0
                 ? "This also permanently deletes \(affectedResponseCount) saved spoken responses."
                 : "This permanently deletes the selected items and their study cards.")
        }
        .alert("Could Not Update Library", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Please try again.") }
    }

    private var browser: some View {
        List {
            if embedsNavigation {
                Section {
                    NavigationLink { SavedResponsesMobileView(library: model.library) } label: {
                        Label("Saved Responses", systemImage: "waveform")
                    }
                }
            }
            Section {
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(.blue).accessibilityHidden(true)
                        Text("Build Your Library").font(.title2.weight(.semibold))
                        Text("Add something you want to remember.")
                        Button { isAddingItem = true } label: { Text("Add First Item").frame(minHeight: 44) }
                            .buttonStyle(.borderedProminent).neoAnkiMobilePrimaryActionTint()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("emptyLibraryScroll")
                    .listRowBackground(Color.clear)
                } else if visibleItems.isEmpty {
                    ContentUnavailableView(attentionOnly ? "Nothing Needs Attention" : "No Matching Items",
                                           systemImage: attentionOnly ? "checkmark.circle" : "magnifyingglass")
                } else {
                    ForEach(visibleItems) { item in
                        Group {
                            if selecting {
                                Button {
                                    if !selection.insert(item.id).inserted { selection.remove(item.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        itemRow(item)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
                                .accessibilityIdentifier("library-select-\(item.id)")
                            } else {
                                NavigationLink { ItemDetailView(model: model, itemID: item.id) } label: { itemRow(item) }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { requestDeletion([item.id]) }
                            if item.schedule?.needsAttention == true {
                                Button("Mark OK") { Task { await markOK([item.id]) } }
                            }
                        }
                    }
                }
            } header: { Text(attentionOnly ? "Repeatedly Forgotten" : "Items") }
        }
        .navigationTitle(embedsNavigation ? "Library" : "Browse Items")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(for: UUID.self) { ItemDetailView(model: model, itemID: $0) }
        .searchable(text: $searchText, prompt: "Search items")
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Browse Options", systemImage: "line.3.horizontal.decrease") {
                    Picker("Sort", selection: $sort) {
                        Text("Reading Order").tag(ItemSortOrder.createdAscending)
                        Text("Newest First").tag(ItemSortOrder.createdDescending)
                        Text("Due Soonest").tag(ItemSortOrder.dueSoonest)
                        Text("Title").tag(ItemSortOrder.titleAscending)
                    }
                    Toggle("Repeatedly Forgotten", isOn: $attentionOnly)
                    Toggle("Conceal Answers", isOn: $model.concealsAnswers)
                    Button(selecting ? "Done Selecting" : "Select Items") { selecting.toggle(); selection = [] }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Item", systemImage: "plus") { isAddingItem = true }
            }

        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                VStack(spacing: 12) {
                    Text("\(selection.count) selected").font(.subheadline)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) { selectionActions }
                    } else {
                        HStack(spacing: 12) { selectionActions }
                    }
                }.padding(16).background(.bar)
            }
        }
    }

    @ViewBuilder
    private var selectionActions: some View {
        Menu {
            Button("Unassigned") { move(to: nil) }
            ForEach(model.decks) { deck in Button(deck.name) { move(to: deck.id) } }
        } label: { Label("Move", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44) }
            .disabled(selection.isEmpty).buttonStyle(.bordered)
        Button { Task { await markOK(selection) } } label: { Text("Mark OK").frame(maxWidth: .infinity, minHeight: 44) }
            .disabled(selection.isEmpty).buttonStyle(.bordered)
        Button(role: .destructive) { requestDeletion(selection) } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44) }
            .disabled(selection.isEmpty).buttonStyle(.bordered)
    }

    private func itemRow(_ item: SavedItemSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title.isEmpty ? "Untitled Item" : item.title).font(.body.weight(.medium)).lineLimit(3)
            if !model.concealsAnswers, !item.subtitle.isEmpty {
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(item.itemTypeName + (item.schedule?.needsAttention == true ? " · Needs attention" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 4)
    }
    private func load() async {
        do { items = try await model.library.items(scope: scope, sort: .createdAscending, search: "") }
        catch { errorMessage = MobileAppModel.message(for: error) }
    }
    private func perform(_ action: () async throws -> Void) async {
        do { try await action(); selection = []; await load() }
        catch { errorMessage = MobileAppModel.message(for: error) }
    }
    private func move(to deck: UUID?) { Task { await perform { try await model.moveItems(selection, to: deck) } } }
    private func markOK(_ ids: Set<UUID>) async {
        await perform { _ = try await model.library.acknowledgeRepeatedLapses(itemIDs: ids, asOf: .now); await model.refresh() }
    }
    private func requestDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
        Task {
            do { affectedResponseCount = try await model.studyResponseCount(itemIDs: ids); showDeleteConfirmation = true }
            catch { errorMessage = MobileAppModel.message(for: error) }
        }
    }
}

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: UUID?
    @Bindable var model: MobileAppModel
    @State private var confirmsDiscard = false
    @State private var selectedTypeID: UUID?
    @State private var selectedDeckID: UUID?
    @State private var values: [UUID: String] = [:]
    @State private var richValues: [UUID: [Span]] = [:]
    @State private var mediaValues: [UUID: MediaRef] = [:]
    @State private var mediaDescriptions: [UUID: String] = [:]
    @State private var occlusionDraftReferences: [MediaRef] = []
    @State private var occlusions: [UUID: ImageOcclusionContent] = [:]
    @State private var clozeBlanks: [UUID: [ClozeSpan]] = [:]
    @State private var selectedMediaField: FieldDef?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImportingMediaFile = false
    @State private var isCapturingMedia = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private func closeEditor() {
        let refs = occlusionDraftReferences + occlusions.values.map(\.image)
        Task { for ref in refs { try? await model.mediaStore?.discardDraftReference(ref) } }
        dismiss()
    }

    private var hasChanges: Bool {
        !occlusions.isEmpty || values.values.contains { !$0.isEmpty } || !richValues.isEmpty || !mediaValues.isEmpty || !clozeBlanks.isEmpty || mediaDescriptions.values.contains { !$0.isEmpty }
    }

    private var selectedType: ItemType? {
        model.itemTypes.first(where: { $0.id == selectedTypeID }) ?? model.itemTypes.first
    }

    init(model: MobileAppModel, deckID: UUID? = nil) {
        self.model = model
        _selectedDeckID = State(initialValue: deckID)
        _selectedTypeID = State(initialValue: model.itemTypes.first?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.itemTypes.isEmpty {
                    ContentUnavailableView(
                        "No Item Types",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Create an item type from the Create tab or import a deck before adding items here.")
                    )
                } else {
                    Section("Item") {
                        Picker("Item type", selection: $selectedTypeID) {
                            ForEach(model.itemTypes) { type in
                                Text(type.name).tag(Optional(type.id))
                            }
                        }
                        .accessibilityIdentifier("add-card-type")
                        Picker("Deck", selection: $selectedDeckID) {
                            Text("Unassigned").tag(Optional<UUID>.none)
                            ForEach(model.decks) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                        .accessibilityIdentifier("add-card-deck")
                    }

                    if let selectedType {
                        DictionaryFieldLookupSection(fields: selectedType.fields) { id in
                            Binding(
                                get: {
                                    if selectedType.fields.first(where: { $0.id == id })?.type == .richText {
                                        return (richValues[id] ?? []).map(\.text).joined()
                                    }
                                    return values[id] ?? ""
                                },
                                set: { value in
                                    if selectedType.fields.first(where: { $0.id == id })?.type == .richText {
                                        richValues[id] = value.isEmpty ? [] : [Span(value)]
                                    } else { values[id] = value }
                                }
                            )
                        }.id(selectedType.id)
                        Section("Content") {
                            ForEach(selectedType.fields) { field in
                                MobileItemFieldRow(field: field) {
                                    fieldEditor(field)
                                    if let issue = validationIssue(field) {
                                        Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Item")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                        .accessibilityIdentifier("add-card-keyboard-done")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if hasChanges { confirmsDiscard = true } else { closeEditor() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel("Saving item")
                    } else {
                        Button("Save") { save() }
                            .accessibilityIdentifier("add-card-save")
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Discard this item?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { closeEditor() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Could Not Save Item", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please check the card and try again.")
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item, let field = selectedMediaField else { return }
                Task { await ingest(item, for: field) }
            }
            .fileImporter(isPresented: $isImportingMediaFile, allowedContentTypes: allowedMediaTypes) { result in
                guard let field = selectedMediaField else { return }
                Task { await ingestFile(result, for: field) }
            }
            .sheet(isPresented: $isCapturingMedia) {
                if let field = selectedMediaField {
                    MobileCameraPicker(allowsVideo: field.type == .video) { result in
                        isCapturingMedia = false
                        Task { await ingestCapture(result, for: field) }
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: FieldDef) -> some View {
        switch field.type {
        case .number:
            TextField("Enter \(field.name.lowercased())", text: valueBinding(for: field.id))
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field.id)
        case .richText:
            RichSpanTextEditor(spans: Binding(
                get: { richValues[field.id] ?? [] },
                set: { richValues[field.id] = $0 }
            ))
            .modifier(MobileTextEditorHeight())
        case .audio, .image, .gif, .video:
            VStack(alignment: .leading, spacing: 8) {
                TextField(mediaDescriptionPrompt(field.type), text: Binding(
                    get: { mediaDescriptions[field.id] ?? "" },
                    set: { description in
                        mediaDescriptions[field.id] = description
                        if var reference = mediaValues[field.id] {
                            reference.altText = description
                            mediaValues[field.id] = reference
                        }
                    }
                ), axis: .vertical)
                .accessibilityIdentifier("add-card-description-\(field.name.lowercased())")
                .focused($focusedField, equals: field.id)
                if field.type != .audio {
                    PhotosPicker(selection: Binding(
                        get: { selectedPhoto },
                        set: { selectedMediaField = field; selectedPhoto = $0 }
                    ), matching: field.type == .image || field.type == .gif ? .images : .videos) {
                        Label(mediaValues[field.id] == nil ? "Photos" : "Replace from Photos", systemImage: "photo.on.rectangle")
                            .frame(minHeight: 44)
                    }
                }
                MobileAdaptiveActionGroup {
                    Button {
                        selectedMediaField = field
                        isImportingMediaFile = true
                    } label: { Label("Files", systemImage: "folder").frame(minHeight: 44) }
                    if field.type == .image || field.type == .video {
                        Button {
                            selectedMediaField = field
                            isCapturingMedia = true
                        } label: { Label("Camera", systemImage: "camera").frame(minHeight: 44) }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                }
                if mediaValues[field.id] != nil {
                    if [.image, .gif].contains(field.type), let reference = mediaValues[field.id] {
                        MobileContentValueView(value: .media(reference), mediaStore: model.mediaStore, isAnswerRevealed: true)
                            .frame(maxHeight: 160)
                            .accessibilityIdentifier("add-card-preview-\(field.name.lowercased())")
                    }
                    Label("Media ready", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(role: .destructive) { mediaValues[field.id] = nil } label: { Text("Remove Media").frame(minHeight: 44) }
                }
            }
        case .imageOcclusion:
            ImageOcclusionFieldEditor(label: field.name, content: Binding(get: { occlusions[field.id] }, set: { value in
                if let value { occlusionDraftReferences.append(value.image) }
                occlusions[field.id] = value
            }), mediaStore: model.mediaStore)
        case .cloze:
            ClozeSelectionEditor(text: valueBinding(for: field.id), blanks: Binding(
                get: { clozeBlanks[field.id] ?? [] },
                set: { clozeBlanks[field.id] = $0 }
            ))
        case .text:
            TextField("Enter \(field.name.lowercased())", text: valueBinding(for: field.id), axis: .vertical)
                .accessibilityIdentifier("add-card-field-\(field.name.lowercased())")
                .focused($focusedField, equals: field.id)
                .lineLimit(2...6)
        }
    }

    private func validationIssue(_ field: FieldDef) -> String? {
        let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if field.type == .imageOcclusion, let content = occlusions[field.id] {
            do { try ImageOcclusionValidation.validate(content) } catch { return error.localizedDescription }
        }
        if field.type == .number, !value.isEmpty {
            let formatter = NumberFormatter(); formatter.locale = .current; formatter.numberStyle = .decimal
            if formatter.number(from: value) == nil { return "Enter a valid number." }
        }
        if [.image, .gif].contains(field.type), mediaValues[field.id] != nil,
           (mediaDescriptions[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a visual description before saving."
        }
        return nil
    }

    private var canSave: Bool {
        guard let selectedType else { return false }
        var text = values
        for (id, spans) in richValues { text[id] = spans.map(\.text).joined() }
        return selectedType.fields.allSatisfy { validationIssue($0) == nil }
            && ItemDraftValidation.canSave(
                ItemDraftContent(text: text, media: mediaValues, mediaDescriptions: mediaDescriptions, clozeBlanks: clozeBlanks, occlusions: occlusions),
                itemType: selectedType
            )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func valueBinding(for fieldID: UUID) -> Binding<String> {
        Binding(
            get: { values[fieldID] ?? "" },
            set: { values[fieldID] = $0 }
        )
    }

    private func save() {
        guard let selectedType else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                var content: [UUID: ContentValue] = [:]
                for field in selectedType.fields {
                    switch field.type {
                    case .richText: content[field.id] = .rich(richValues[field.id] ?? [])
                    case .audio, .image, .gif, .video:
                        if var reference = mediaValues[field.id] {
                            reference.altText = mediaDescriptions[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                            content[field.id] = .media(reference)
                        } else { content[field.id] = .empty }
                    case .number:
                        let raw = values[field.id] ?? ""
                        let formatter = NumberFormatter(); formatter.locale = .current; formatter.numberStyle = .decimal
                        guard raw.isEmpty || formatter.number(from: raw) != nil else { throw ItemDraftError.invalidNumber(field.name) }
                        content[field.id] = raw.isEmpty ? .empty : .number(formatter.number(from: raw)!.doubleValue)
                    case .imageOcclusion: content[field.id] = occlusions[field.id].map(ContentValue.imageOcclusion) ?? .empty
                    case .cloze: content[field.id] = .cloze(values[field.id] ?? "", blanks: clozeBlanks[field.id] ?? [])
                    case .text: content[field.id] = .text(values[field.id] ?? "")
                    }
                }
                try await model.createItem(itemType: selectedType, deckID: selectedDeckID, values: content)
                closeEditor()
            } catch {
                errorMessage = MobileAppModel.message(for: error)
            }
        }
    }

    private func ingest(_ item: PhotosPickerItem, for field: FieldDef) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let kind: MediaKind = switch field.type { case .audio: .audio; case .image: .image; case .gif: .gif; case .video: .video; default: .image }
            mediaValues[field.id] = try await model.reserveMedia(data: data, kind: kind, altText: mediaDescriptions[field.id] ?? "")
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }

    private var allowedMediaTypes: [UTType] {
        guard let field = selectedMediaField else { return [.data] }
        return switch field.type {
        case .audio: [.audio]
        case .image: [.image]
        case .gif: [.gif]
        case .video: [.movie]
        default: [.data]
        }
    }

    private func ingestFile(_ result: Result<URL, Error>, for field: FieldDef) async {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await ingestData(Data(contentsOf: url, options: [.mappedIfSafe]), for: field)
        } catch { if (error as NSError).code != CocoaError.userCancelled.rawValue { errorMessage = MobileAppModel.message(for: error) } }
    }

    private func ingestCapture(_ result: Result<MobileCameraCapture, Error>, for field: FieldDef) async {
        do {
            let capture = try result.get()
            defer { if let temporaryURL = capture.temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }
            try await ingestData(capture.data, for: field)
        } catch { if (error as NSError).code != CocoaError.userCancelled.rawValue { errorMessage = MobileAppModel.message(for: error) } }
    }

    private func ingestData(_ data: Data, for field: FieldDef) async throws {
        let kind: MediaKind = switch field.type { case .audio: .audio; case .image: .image; case .gif: .gif; case .video: .video; default: .image }
        mediaValues[field.id] = try await model.reserveMedia(data: data, kind: kind, altText: mediaDescriptions[field.id] ?? "")
    }
}

private struct MobileCameraCapture {
    let data: Data
    let temporaryURL: URL?
}

private struct MobileCameraPicker: UIViewControllerRepresentable {
    let allowsVideo: Bool
    let completion: (Result<MobileCameraCapture, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = allowsVideo ? [UTType.movie.identifier] : [UTType.image.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (Result<MobileCameraCapture, Error>) -> Void
        init(completion: @escaping (Result<MobileCameraCapture, Error>) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(.failure(CocoaError(.userCancelled)))
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                completion(.success(MobileCameraCapture(data: data, temporaryURL: nil)))
            } else if let url = info[.mediaURL] as? URL {
                do { completion(.success(MobileCameraCapture(data: try Data(contentsOf: url, options: [.mappedIfSafe]), temporaryURL: url))) }
                catch { completion(.failure(error)) }
            } else {
                completion(.failure(CocoaError(.fileReadUnknown)))
            }
        }
    }
}

private struct ItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    let itemID: UUID
    @State private var loaded: (item: Item, itemType: ItemType)?
    @State private var cardMaturityDetails: [CardMaturityDetail] = []
    @State private var errorMessage: String?
    @State private var isEditing = false
    @State private var confirmsDelete = false
    @State private var affectedResponseCount = 0
    @State private var deletionError: String?

    var body: some View {
        Group {
            if let loaded {
                List {
                    ForEach(loaded.itemType.fields) { field in
                        Section(field.name) {
                            MobileContentValueView(
                                value: loaded.item.value(for: field.id) ?? .empty,
                                mediaStore: model.mediaStore,
                                isAnswerRevealed: true
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        }
                    }
                    if !cardMaturityDetails.isEmpty {
                        Section("Card maturity") {
                            ForEach(cardMaturityDetails) { detail in
                                LabeledContent(
                                    cardMaturityName(detail, itemType: loaded.itemType),
                                    value: detail.status.displayName
                                )
                            }
                        }
                    }
                }
                .navigationTitle(loaded.itemType.name)
                .toolbar {
                    Button("Edit") { isEditing = true }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task {
                            do { affectedResponseCount = try await model.studyResponseCount(itemIDs: [itemID]); confirmsDelete = true }
                            catch { deletionError = MobileAppModel.message(for: error) }
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Load Item",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading item…")
            }
        }
        .task {
            do {
                loaded = try await model.item(id: itemID)
                cardMaturityDetails = try await model.library.cardMaturityDetails(itemID: itemID)
                if loaded == nil { errorMessage = "This item no longer exists." }
            } catch {
                errorMessage = MobileAppModel.message(for: error)
            }
        }
        .sheet(isPresented: $isEditing) {
            if let loaded {
                if loaded.itemType.name == "Poem Line",
                   let deckID = loaded.item.deckID {
                    PoemDeckEditorView(
                        library: model.library,
                        deckID: deckID,
                        itemTypeID: loaded.itemType.id,
                        deckName: model.decks.first(where: { $0.id == deckID })?.name ?? "Poem",
                        onSaved: {
                            isEditing = false
                            Task { await reloadAfterSourceEditing() }
                        },
                        onCancel: { isEditing = false }
                    )
                } else if loaded.itemType.name == "Prose Unit",
                          let deckID = loaded.item.deckID {
                    ProseDeckEditorView(
                        library: model.library,
                        deckID: deckID,
                        itemTypeID: loaded.itemType.id,
                        deckName: model.decks.first(where: { $0.id == deckID })?.name ?? "Prose",
                        onSaved: {
                            isEditing = false
                            Task { await reloadAfterSourceEditing() }
                        },
                        onCancel: { isEditing = false }
                    )
                } else {
                    ItemEditMobileView(model: model, loaded: loaded) { self.loaded = $0 }
                }
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await model.deleteItems([itemID]); dismiss() }
                    catch { deletionError = MobileAppModel.message(for: error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(affectedResponseCount > 0 ? "This also permanently deletes \(affectedResponseCount) saved spoken responses." : "This permanently deletes the item and its study cards.")
        }
        .alert("Could Not Delete Item", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deletionError ?? "Please try again.") }
    }

    private func reloadAfterSourceEditing() async {
        await model.refresh()
        do {
            // Reconciliation can replace the selected unit. Return to its scoped
            // browser rather than leaving a detail for a retired item mounted.
            guard let updated = try await model.item(id: itemID) else { dismiss(); return }
            loaded = updated
            cardMaturityDetails = try await model.library.cardMaturityDetails(itemID: itemID)
        } catch {
            loaded = nil
            errorMessage = MobileAppModel.message(for: error)
        }
    }

    private func cardMaturityName(_ detail: CardMaturityDetail, itemType: ItemType) -> String {
        let setup = itemType.templates.first(where: { $0.id == detail.templateID })?.name ?? "Card"
        if let group = detail.occlusionGroup { return "\(setup) · region group \(group)" }
        if let group = detail.clozeGroup { return "\(setup) · blank \(group)" }
        return setup
    }
}

struct MobileAdaptiveActionGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout { content() }
    }
}

private struct MobileItemFieldRow<Editor: View>: View {
    let field: FieldDef
    @ViewBuilder var editor: () -> Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.name).font(.subheadline.weight(.medium))
                if field.isRequired { Text("Required").font(.caption).foregroundStyle(.secondary) }
            }
            editor()
        }.padding(.vertical, 4)
            .buttonStyle(.borderless)
    }
}

struct ItemEditMobileView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @State var item: Item
    private let originalItem: Item
    let itemType: ItemType
    let onSaved: ((item: Item, itemType: ItemType)) -> Void
    @State private var errorMessage: String?
    @State private var mediaDescriptions: [UUID: String]
    @State private var selectedMediaField: FieldDef?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImportingMediaFile = false
    @State private var isCapturingMedia = false
    @State private var confirmsDiscard = false
    @State private var occlusionDraftReferences: [MediaRef] = []

    init(model: MobileAppModel, loaded: (item: Item, itemType: ItemType), onSaved: @escaping ((item: Item, itemType: ItemType)) -> Void) {
        self.model = model
        _item = State(initialValue: loaded.item)
        originalItem = loaded.item
        itemType = loaded.itemType
        self.onSaved = onSaved
        _mediaDescriptions = State(initialValue: Dictionary(uniqueKeysWithValues: loaded.item.fields.compactMap { value in
            guard let reference = value.value.mediaReference else { return nil }
            return (value.fieldID, reference.altText ?? "")
        }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Deck") {
                    Picker("Deck", selection: $item.deckID) {
                        Text("Unassigned").tag(Optional<UUID>.none)
                        ForEach(model.decks) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Content") {
                    ForEach(itemType.fields) { field in
                        MobileItemFieldRow(field: field) {
                            editor(field)
                            if let issue = fieldIssue(field) {
                                Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Item").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if item == originalItem { closeEditor() } else { confirmsDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(itemType.fields.contains { fieldIssue($0) != nil }) }
            }
            .interactiveDismissDisabled(item != originalItem)
            .alert("Could Not Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
            .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { closeEditor() }
                Button("Keep Editing", role: .cancel) {}
            }
            .onChange(of: selectedPhoto) { _, selection in
                guard let selection, let field = selectedMediaField else { return }
                Task { await ingest(selection, for: field) }
            }
            .fileImporter(isPresented: $isImportingMediaFile, allowedContentTypes: allowedMediaTypes) { result in
                guard let field = selectedMediaField else { return }
                Task { await ingestFile(result, for: field) }
            }
            .sheet(isPresented: $isCapturingMedia) {
                if let field = selectedMediaField {
                    MobileCameraPicker(allowsVideo: field.type == .video) { result in
                        isCapturingMedia = false
                        Task { await ingestCapture(result, for: field) }
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    @ViewBuilder private func editor(_ field: FieldDef) -> some View {
        let value = item.value(for: field.id) ?? .empty
        switch field.type {
        case .richText:
            let spans: [Span] = if case let .rich(value) = value { value } else { [] }
            RichSpanTextEditor(spans: Binding(get: { spansFor(field.id) ?? spans }, set: { set(.rich($0), field.id) }))
                .modifier(MobileTextEditorHeight())
        case .imageOcclusion:
            ImageOcclusionFieldEditor(label: field.name, content: Binding(get: {
                if case let .imageOcclusion(content) = item.value(for: field.id) { return content }
                return nil
            }, set: { set($0.map(ContentValue.imageOcclusion) ?? .empty, field.id) }), mediaStore: model.mediaStore)
        case .cloze:
            let text = textFor(field.id) ?? ""
            let blanks: [ClozeSpan] = clozeFor(field.id) ?? []
            ClozeSelectionEditor(text: Binding(get: { textFor(field.id) ?? text }, set: { set(.cloze($0, blanks: clozeFor(field.id) ?? blanks), field.id) }), blanks: Binding(get: { clozeFor(field.id) ?? blanks }, set: { set(.cloze(textFor(field.id) ?? text, blanks: $0), field.id) }))
        case .audio, .image, .gif, .video:
            VStack(alignment: .leading, spacing: 8) {
                TextField(mediaDescriptionPrompt(field.type), text: Binding(
                    get: { mediaDescriptions[field.id] ?? "" },
                    set: { description in
                        mediaDescriptions[field.id] = description
                        if case .media(var reference) = item.value(for: field.id) {
                            reference.altText = description
                            set(.media(reference), field.id)
                        }
                    }
                ), axis: .vertical)
                .accessibilityIdentifier("edit-card-description-\(field.name.lowercased())")
                if field.type != .audio {
                    PhotosPicker(selection: Binding(
                        get: { selectedPhoto },
                        set: { selectedMediaField = field; selectedPhoto = $0 }
                    ), matching: field.type == .image || field.type == .gif ? .images : .videos) {
                        Label(mediaReference(field.id) == nil ? "Photos" : "Replace from Photos", systemImage: "photo.on.rectangle")
                            .frame(minHeight: 44)
                    }
                }
                MobileAdaptiveActionGroup {
                    Button { selectedMediaField = field; isImportingMediaFile = true } label: { Label("Files", systemImage: "folder").frame(minHeight: 44) }
                    if field.type == .image || field.type == .video {
                        Button { selectedMediaField = field; isCapturingMedia = true } label: { Label("Camera", systemImage: "camera").frame(minHeight: 44) }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                }
                if mediaReference(field.id) != nil {
                    if [.image, .gif].contains(field.type), let reference = mediaReference(field.id) {
                        MobileContentValueView(value: .media(reference), mediaStore: model.mediaStore, isAnswerRevealed: true)
                            .frame(maxHeight: 160)
                    }
                    Label("Media ready", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(role: .destructive) { set(.empty, field.id) } label: { Text("Remove Media").frame(minHeight: 44) }
                }
            }
        case .number:
            TextField("Number", value: Binding(get: { numberFor(field.id) }, set: { set($0.map(ContentValue.number) ?? .empty, field.id) }), format: .number)
                .keyboardType(.decimalPad)
        case .text:
            TextField(field.name, text: Binding(get: { textFor(field.id) ?? "" }, set: { set(.text($0), field.id) }), axis: .vertical)
        }
    }
    private func fieldIssue(_ field: FieldDef) -> String? {
        let value = item.value(for: field.id) ?? .empty
        if field.isRequired {
            switch value {
            case .empty: return "This field is required."
            case let .text(text, _), let .cloze(text, _):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "This field is required." }
            case let .rich(spans):
                if spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "This field is required." }
            default: break
            }
        }
        if case let .imageOcclusion(content) = value {
            do { try ImageOcclusionValidation.validate(content) } catch { return error.localizedDescription }
        }
        if [.image, .gif].contains(field.type), case let .media(reference) = value,
           (reference.altText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a visual description." }
        return nil
    }

    private func closeEditor() {
        let refs = occlusionDraftReferences
        Task { for ref in refs { try? await model.mediaStore?.discardDraftReference(ref) } }
        dismiss()
    }

    private func set(_ value: ContentValue, _ fieldID: UUID) {
        if case let .imageOcclusion(content) = value { occlusionDraftReferences.append(content.image) }
        if let index = item.fields.firstIndex(where: { $0.fieldID == fieldID }) { item.fields[index].value = value }
        else { item.fields.append(FieldValue(fieldID: fieldID, value: value)) }
    }
    private func textFor(_ id: UUID) -> String? { switch item.value(for: id) { case let .text(v, _), let .cloze(v, _): v; default: nil } }
    private func spansFor(_ id: UUID) -> [Span]? { if case let .rich(v) = item.value(for: id) { v } else { nil } }
    private func clozeFor(_ id: UUID) -> [ClozeSpan]? { if case let .cloze(_, v) = item.value(for: id) { v } else { nil } }
    private func numberFor(_ id: UUID) -> Double? { if case let .number(v) = item.value(for: id) { v } else { nil } }
    private func mediaReference(_ id: UUID) -> MediaRef? { if case let .media(value) = item.value(for: id) { value } else { nil } }
    private var allowedMediaTypes: [UTType] {
        guard let field = selectedMediaField else { return [.data] }
        return switch field.type { case .audio: [.audio]; case .image: [.image]; case .gif: [.gif]; case .video: [.movie]; default: [.data] }
    }
    private func ingest(_ selection: PhotosPickerItem, for field: FieldDef) async {
        do { if let data = try await selection.loadTransferable(type: Data.self) { try await ingestData(data, for: field) } }
        catch { errorMessage = MobileAppModel.message(for: error) }
    }
    private func ingestFile(_ result: Result<URL, Error>, for field: FieldDef) async {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await ingestData(Data(contentsOf: url, options: [.mappedIfSafe]), for: field)
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }
    private func ingestCapture(_ result: Result<MobileCameraCapture, Error>, for field: FieldDef) async {
        do {
            let capture = try result.get()
            defer { if let url = capture.temporaryURL { try? FileManager.default.removeItem(at: url) } }
            try await ingestData(capture.data, for: field)
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }
    private func ingestData(_ data: Data, for field: FieldDef) async throws {
        let kind: MediaKind = switch field.type { case .audio: .audio; case .image: .image; case .gif: .gif; case .video: .video; default: .image }
        let reference = try await model.reserveMedia(data: data, kind: kind, altText: mediaDescriptions[field.id] ?? "")
        set(.media(reference), field.id)
    }
    private func save() async {
        do {
            for field in itemType.fields where [.image, .gif].contains(field.type) {
                if let reference = item.value(for: field.id)?.mediaReference,
                   (reference.altText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ItemDraftError.missingMediaDescription(field.name)
                }
            }
            try await model.updateItem(item); onSaved((item, itemType)); closeEditor()
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }
}
#endif
