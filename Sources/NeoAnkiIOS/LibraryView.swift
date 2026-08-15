import NeoAnkiCore
import NeoAnkiFeatures
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
struct LibraryView: View {
    @Bindable var model: MobileAppModel
    @State private var searchText = ""
    @State private var isAddingItem = false
    @State private var path = NavigationPath()
    @State private var pendingDeletion: Set<UUID> = []
    @State private var affectedResponseCount = 0
    @State private var showDeleteConfirmation = false
    @State private var deletionError: String?

    private var visibleItems: [SavedItemSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.items }
        return model.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
                || $0.itemTypeName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavigationLink {
                    SavedResponsesMobileView(library: model.library)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved Responses")
                                .font(.headline)
                            Text("Persistent spoken responses · Local only")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens recordings saved from Audio Submission cards")
                Divider()

                Group {
                    if model.items.isEmpty {
                        ScrollView {
                            ContentUnavailableView {
                                Label("Build Your Library", systemImage: "rectangle.stack.badge.plus")
                            } description: {
                                Text("Add a question and answer. NeoAnki2 will turn them into cards and schedule each review.")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            } actions: {
                                Button("Add First Card") { isAddingItem = true }
                                    .buttonStyle(.plain)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .padding(.horizontal, 20)
                                    .frame(minHeight: 44)
                                    .background(Color.primary, in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    } else if visibleItems.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        List(visibleItems, selection: $model.selectedItemIDs) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title.isEmpty ? "Untitled" : item.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text("\(item.itemTypeName) · \(item.cardCount) \(item.cardCount == 1 ? "card" : "cards")")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { requestDeletion([item.id]) }
                        }
                    }
                        .refreshable { await model.refresh() }
                    }
                }
            }
            .navigationTitle("Library")
            .modifier(ConditionalLibrarySearch(text: $searchText, isEnabled: !model.items.isEmpty))
            .navigationDestination(for: UUID.self) { itemID in
                ItemDetailView(model: model, itemID: itemID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Card", systemImage: "plus") {
                        isAddingItem = true
                    }
                }
                if !model.selectedItemIDs.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Menu("Move \(model.selectedItemIDs.count) Items", systemImage: "folder") {
                            Button("Unassigned") { Task { try? await model.moveItems(model.selectedItemIDs, to: nil) } }
                            ForEach(model.decks) { deck in Button(deck.name) { Task { try? await model.moveItems(model.selectedItemIDs, to: deck.id) } } }
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            requestDeletion(model.selectedItemIDs)
                        }
                    }
                }
            }
            .sheet(isPresented: $isAddingItem) {
                AddItemView(model: model)
            }
            .onChange(of: model.route) { _, route in
                if case let .itemDetail(id) = route { path = NavigationPath([id]) }
            }
            .task {
                if case let .itemDetail(id) = model.route { path = NavigationPath([id]) }
            }
            .confirmationDialog(
                pendingDeletion.count == 1 ? "Delete this item?" : "Delete \(pendingDeletion.count) items?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDeletion
                    Task {
                        do { try await model.deleteItems(ids) }
                        catch { deletionError = MobileAppModel.message(for: error) }
                    }
                    pendingDeletion = []
                }
                Button("Cancel", role: .cancel) { pendingDeletion = [] }
            } message: {
                if affectedResponseCount > 0 {
                    Text("This also permanently deletes \(affectedResponseCount) saved spoken \(affectedResponseCount == 1 ? "response" : "responses").")
                } else {
                    Text("This permanently deletes the selected items and their study cards.")
                }
            }
            .alert("Could Not Delete", isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionError ?? "The items could not be deleted.")
            }
        }
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
        Task {
            do {
                affectedResponseCount = try await model.studyResponseCount(itemIDs: ids)
                showDeleteConfirmation = true
            } catch {
                pendingDeletion = []
                deletionError = MobileAppModel.message(for: error)
            }
        }
    }
}

private struct ConditionalLibrarySearch: ViewModifier {
    @Binding var text: String
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, prompt: "Search cards")
        } else {
            content
        }
    }
}

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @State private var selectedTypeID: UUID?
    @State private var selectedDeckID: UUID?
    @State private var values: [UUID: String] = [:]
    @State private var richValues: [UUID: [Span]] = [:]
    @State private var mediaValues: [UUID: MediaRef] = [:]
    @State private var mediaDescriptions: [UUID: String] = [:]
    @State private var clozeBlanks: [UUID: [ClozeSpan]] = [:]
    @State private var selectedMediaField: FieldDef?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImportingMediaFile = false
    @State private var isCapturingMedia = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var selectedType: ItemType? {
        model.itemTypes.first(where: { $0.id == selectedTypeID }) ?? model.itemTypes.first
    }

    init(model: MobileAppModel) {
        self.model = model
        _selectedTypeID = State(initialValue: model.itemTypes.first?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.itemTypes.isEmpty {
                    ContentUnavailableView(
                        "No Item Types",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Create an item type from the Create tab or import a deck before adding cards here.")
                    )
                } else {
                    Section("Card type") {
                        Picker("Item type", selection: $selectedTypeID) {
                            ForEach(model.itemTypes) { type in
                                Text(type.name).tag(Optional(type.id))
                            }
                        }
                        Picker("Deck", selection: $selectedDeckID) {
                            Text("Unassigned").tag(Optional<UUID>.none)
                            ForEach(model.decks) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                    }

                    if let selectedType {
                        Section("Content") {
                            ForEach(selectedType.fields) { field in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Text(field.name)
                                            .font(.subheadline.weight(.medium))
                                        if field.isRequired {
                                            Text("Required")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    fieldEditor(field)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel("Saving card")
                    } else {
                        Button("Save") { save() }
                            .accessibilityIdentifier("add-card-save")
                            .disabled(!canSave)
                    }
                }
            }
            .alert("Could Not Save Card", isPresented: errorBinding) {
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
        case .richText:
            RichSpanTextEditor(spans: Binding(
                get: { richValues[field.id] ?? [] },
                set: { richValues[field.id] = $0 }
            ))
            .frame(minHeight: 96)
        case .audio, .image, .gif, .video:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Visual description (required)", text: Binding(
                    get: { mediaDescriptions[field.id] ?? "" },
                    set: { mediaDescriptions[field.id] = $0 }
                ), axis: .vertical)
                if field.type != .audio {
                    PhotosPicker(selection: $selectedPhoto, matching: field.type == .image || field.type == .gif ? .images : .videos) {
                        Label(mediaValues[field.id] == nil ? "Photos" : "Replace from Photos", systemImage: "photo.on.rectangle")
                            .frame(minHeight: 44)
                    }
                    .simultaneousGesture(TapGesture().onEnded { selectedMediaField = field })
                }
                HStack {
                    Button("Files", systemImage: "folder") {
                        selectedMediaField = field
                        isImportingMediaFile = true
                    }
                    .frame(minHeight: 44)
                    if field.type == .image || field.type == .video {
                        Button("Camera", systemImage: "camera") {
                            selectedMediaField = field
                            isCapturingMedia = true
                        }
                        .frame(minHeight: 44)
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                }
                if mediaValues[field.id] != nil { Label("Media ready", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        case .cloze:
            ClozeSelectionEditor(text: valueBinding(for: field.id), blanks: Binding(
                get: { clozeBlanks[field.id] ?? [] },
                set: { clozeBlanks[field.id] = $0 }
            ))
        case .text:
            TextField("Enter \(field.name.lowercased())", text: valueBinding(for: field.id), axis: .vertical)
                .accessibilityIdentifier("add-card-field-\(field.name.lowercased())")
                .lineLimit(2...6)
        }
    }

    private var canSave: Bool {
        guard let selectedType else { return false }
        return selectedType.fields.allSatisfy { field in
            if !field.isRequired { return true }
            switch field.type {
            case .richText: return !(richValues[field.id] ?? []).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .audio, .image, .gif, .video: return mediaValues[field.id] != nil && !(mediaDescriptions[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return !(values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
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
                    case .audio, .image, .gif, .video: content[field.id] = mediaValues[field.id].map(ContentValue.media) ?? .empty
                    case .number:
                        let raw = values[field.id] ?? ""
                        let formatter = NumberFormatter(); formatter.locale = .current; formatter.numberStyle = .decimal
                        guard raw.isEmpty || formatter.number(from: raw) != nil else { throw ItemDraftError.invalidNumber(field.name) }
                        content[field.id] = raw.isEmpty ? .empty : .number(formatter.number(from: raw)!.doubleValue)
                    case .cloze: content[field.id] = .cloze(values[field.id] ?? "", blanks: clozeBlanks[field.id] ?? [])
                    case .text: content[field.id] = .text(values[field.id] ?? "")
                    }
                }
                try await model.createItem(itemType: selectedType, deckID: selectedDeckID, values: content)
                dismiss()
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
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }

    private func ingestCapture(_ result: Result<MobileCameraCapture, Error>, for field: FieldDef) async {
        do {
            let capture = try result.get()
            defer { if let temporaryURL = capture.temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }
            try await ingestData(capture.data, for: field)
        } catch { errorMessage = MobileAppModel.message(for: error) }
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
    @Bindable var model: MobileAppModel
    let itemID: UUID
    @State private var loaded: (item: Item, itemType: ItemType)?
    @State private var errorMessage: String?
    @State private var isEditing = false
    @State private var confirmsDelete = false

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
                }
                .navigationTitle(loaded.itemType.name)
                .toolbar {
                    Button("Edit") { isEditing = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Load Card",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading card…")
            }
        }
        .task {
            do {
                loaded = try await model.item(id: itemID)
                if loaded == nil { errorMessage = "This card no longer exists." }
            } catch {
                errorMessage = MobileAppModel.message(for: error)
            }
        }
        .sheet(isPresented: $isEditing) {
            if let loaded { ItemEditMobileView(model: model, loaded: loaded) { self.loaded = $0 } }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { Task { try? await model.deleteItems([itemID]) } }
            Button("Cancel", role: .cancel) {}
        }
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

    init(model: MobileAppModel, loaded: (item: Item, itemType: ItemType), onSaved: @escaping ((item: Item, itemType: ItemType)) -> Void) {
        self.model = model
        _item = State(initialValue: loaded.item)
        originalItem = loaded.item
        itemType = loaded.itemType
        self.onSaved = onSaved
        _mediaDescriptions = State(initialValue: Dictionary(uniqueKeysWithValues: loaded.item.fields.compactMap { value in
            guard case let .media(reference) = value.value else { return nil }
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
                ForEach(itemType.fields) { field in
                    Section(field.name) { editor(field) }
                }
            }
            .navigationTitle("Edit Item").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if item == originalItem { dismiss() } else { confirmsDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
            .interactiveDismissDisabled(item != originalItem)
            .alert("Could Not Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
            .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
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
            RichSpanTextEditor(spans: Binding(get: { spansFor(field.id) ?? spans }, set: { set(.rich($0), field.id) })).frame(minHeight: 96)
        case .cloze:
            let text = textFor(field.id) ?? ""
            let blanks: [ClozeSpan] = clozeFor(field.id) ?? []
            ClozeSelectionEditor(text: Binding(get: { textFor(field.id) ?? text }, set: { set(.cloze($0, blanks: clozeFor(field.id) ?? blanks), field.id) }), blanks: Binding(get: { clozeFor(field.id) ?? blanks }, set: { set(.cloze(textFor(field.id) ?? text, blanks: $0), field.id) }))
        case .audio, .image, .gif, .video:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Visual description (required)", text: Binding(
                    get: { mediaDescriptions[field.id] ?? "" },
                    set: { description in
                        mediaDescriptions[field.id] = description
                        if case .media(var reference) = item.value(for: field.id) {
                            reference.altText = description
                            set(.media(reference), field.id)
                        }
                    }
                ), axis: .vertical)
                if field.type != .audio {
                    PhotosPicker(selection: $selectedPhoto, matching: field.type == .image || field.type == .gif ? .images : .videos) {
                        Label(mediaReference(field.id) == nil ? "Photos" : "Replace from Photos", systemImage: "photo.on.rectangle")
                            .frame(minHeight: 44)
                    }
                    .simultaneousGesture(TapGesture().onEnded { selectedMediaField = field })
                }
                HStack {
                    Button("Files", systemImage: "folder") { selectedMediaField = field; isImportingMediaFile = true }
                        .frame(minHeight: 44)
                    if field.type == .image || field.type == .video {
                        Button("Camera", systemImage: "camera") { selectedMediaField = field; isCapturingMedia = true }
                            .frame(minHeight: 44)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                }
                if mediaReference(field.id) != nil { Label("Media ready", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        case .number:
            TextField("Number", value: Binding(get: { numberFor(field.id) }, set: { set($0.map(ContentValue.number) ?? .empty, field.id) }), format: .number)
                .keyboardType(.decimalPad)
        case .text:
            TextField(field.name, text: Binding(get: { textFor(field.id) ?? "" }, set: { set(.text($0), field.id) }), axis: .vertical)
        }
    }
    private func set(_ value: ContentValue, _ fieldID: UUID) {
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
            for field in itemType.fields where field.type.mediaKind != nil {
                if case let .media(reference) = item.value(for: field.id),
                   (reference.altText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ItemDraftError.missingMediaDescription(field.name)
                }
            }
            try await model.updateItem(item); onSaved((item, itemType)); dismiss()
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }
}
#endif
