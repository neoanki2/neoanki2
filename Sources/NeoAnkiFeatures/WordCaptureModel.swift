import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Observation

public struct VocabularyContentChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let detail: String?
    public let audio: AudioReference?
    public let senseID: String?
    public let formID: String?
    public init(id: String, text: String, detail: String? = nil, audio: AudioReference? = nil,
                senseID: String? = nil, formID: String? = nil) {
        self.id = id; self.text = text; self.detail = detail; self.audio = audio
        self.senseID = senseID; self.formID = formID
    }
}

/// Shared capture state. Search and per-entry choices never become saved pair configuration.
@MainActor @Observable public final class WordCaptureModel {
    public private(set) var decks: [DeckSummary] = []
    public private(set) var authoringTypes: [ItemType] = []
    public private(set) var itemTypes: [ItemType] = []
    public private(set) var packs: [InstalledVocabularyPack] = []
    public private(set) var deckID: UUID?
    public private(set) var dictionaryID: String?
    public private(set) var preferences = VocabularyCapturePreferences()
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            requestGeneration += 1
            lookup.invalidate(); selectedEntry = nil; selectedChoices = [:]; selectedRequestKey = nil
            chosenSenseID = nil; chosenFormID = nil; manualEntry = false
            clearAutomaticText()
        }
    }
    public private(set) var selectedEntry: LexicalEntry?
    public private(set) var text: [UUID: String] = [:]
    public private(set) var selectedChoices: [UUID: String] = [:]
    public private(set) var manualFields: Set<UUID> = []
    public private(set) var isLoading = true
    public private(set) var isSaving = false
    public private(set) var isImporting = false
    public var errorMessage: String?
    public private(set) var successMessage: String?
    public private(set) var focusGeneration = 0
    public private(set) var manualEntry = false
    public let lookup: DictionaryLookupModel
    public let library: any LibraryRepository
    private let rootURL: URL
    private let configurationStore: any VocabularyDeckConfigurationStoring
    private let onSaved: @MainActor () async -> Void
    private var libraryID: UUID?
    private var draftID = UUID()
    private var chosenSenseID: String?
    private var chosenFormID: String?
    private var selectedRequestKey: String?
    private var requestGeneration = 0

    public init(library: any LibraryRepository, rootURL: URL,
                configurationStore: (any VocabularyDeckConfigurationStoring)? = nil,
                lookup: DictionaryLookupModel = DictionaryLookupModel(),
                onSaved: @escaping @MainActor () async -> Void = {}) {
        self.library = library; self.rootURL = rootURL; self.lookup = lookup
        self.configurationStore = configurationStore ?? FileVocabularyDeckConfigurationStore(
            rootURL: rootURL.appendingPathComponent(".word-capture", isDirectory: true))
        self.onSaved = onSaved
    }

    public var configuration: VocabularyDeckConfiguration? {
        preferences.configuration(dictionaryID: dictionaryID, deckID: deckID)
    }
    public var itemType: ItemType? { itemTypes.first { $0.id == configuration?.itemTypeID } }
    public var selectedPack: InstalledVocabularyPack? { packs.first { $0.id == dictionaryID } }
    public var destinationName: String { decks.first { $0.id == deckID }?.name ?? "Choose Deck" }
    public var configurationIssue: String? {
        guard let configuration else { return nil }
        return configuration.issue(itemTypes: itemTypes)
    }
    public var hasDraft: Bool { !query.isEmpty || text.values.contains { !$0.isEmpty } }
    public var hasManualEdits: Bool { manualFields.contains { !(text[$0] ?? "").isEmpty } }
    public var requestKey: String {
        // Reinstalling a missing pack keeps its ID but gives it a new local URL.
        // Include that location so the capture view resumes the retained query.
        let location = selectedPack?.packageURL.absoluteString ?? ""
        return "\(dictionaryID ?? "")|\(deckID?.uuidString ?? "")|\(location)|\(query)"
    }
    public var results: [LexicalEntry] { lookup.results }
    public var requiredFields: [FieldDef] {
        itemType?.fields.filter { $0.isRequired && binding(for: $0.id)?.source != .typedWord } ?? []
    }
    public var optionalFields: [FieldDef] {
        itemType?.fields.filter { !$0.isRequired || binding(for: $0.id)?.source == .typedWord } ?? []
    }

    public func start(deckID requestedDeckID: UUID? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            libraryID = try await library.libraryID()
            if let libraryID { preferences = try configurationStore.load(libraryID: libraryID) }
            try await reloadCatalog()
            deckID = requestedDeckID ?? preferences.lastDeckID
            if let id = deckID, !decks.contains(where: { $0.id == id }) { deckID = nil }
            dictionaryID = deckID.flatMap { preferences.lastDictionaryByDeck[$0] } ?? packs.first?.id
            rememberPair()
            await refreshAuthoringTypes()
        } catch { errorMessage = error.localizedDescription }
    }

    public func reloadCatalog() async throws {
        let catalog = try await library.loadItemTypeCatalog()
        itemTypes = catalog.allItemTypes
        decks = try await library.deckSummaries(asOf: .now)
        packs = try await InstalledVocabularyPackStore(rootURL: rootURL).installedPacks()
        await refreshAuthoringTypes()
    }

    public func selectDeck(_ id: UUID?) {
        guard !isSaving, id != deckID else { return }
        clearDerivedDraft()
        deckID = id
        Task { await refreshAuthoringTypes() }
        if let id, let previous = preferences.lastDictionaryByDeck[id] { dictionaryID = previous }
        rememberPair()
    }

    public func refreshAuthoringTypes() async {
        let requested = deckID
        do {
            let choices = try await library.authoringItemTypes(for: requested)
            guard requested == deckID else { return }
            authoringTypes = choices.itemTypes
        } catch { errorMessage = error.localizedDescription }
    }
    public func attachAuthoringType(_ type: ItemType) async throws {
        guard let deckID else { return }
        try await library.attachItemType(id: type.id, to: deckID)
        try await reloadCatalog()
    }

    public func selectDictionary(_ id: String?) {
        guard !isSaving, id != dictionaryID else { return }
        clearDerivedDraft()
        dictionaryID = id
        rememberPair()
    }

    private func rememberPair() {
        guard let dictionaryID, let deckID else { return }
        preferences.remember(dictionaryID: dictionaryID, deckID: deckID)
        persistPreferences()
    }
    private func persistPreferences() {
        guard let libraryID else { return }
        do { try configurationStore.save(preferences, libraryID: libraryID) }
        catch { errorMessage = "Could not save this pair’s setup: \(error.localizedDescription)" }
    }

    public func saveConfiguration(_ configuration: VocabularyDeckConfiguration) -> Bool {
        guard !isSaving, configuration.dictionaryID == dictionaryID, configuration.deckID == deckID else { return false }
        if let issue = configuration.issue(itemTypes: itemTypes) { errorMessage = issue; return false }
        var updated = preferences
        updated.set(configuration)
        do {
            guard let libraryID else { return false }
            try configurationStore.save(updated, libraryID: libraryID)
            preferences = updated
            chosenSenseID = nil; chosenFormID = nil
            selectedChoices = [:]
            clearAutomaticText()
            // An explicit setup change may only replace content still owned by lookup.
            applyChoices()
            return true
        } catch { errorMessage = "Could not save this pair’s setup: \(error.localizedDescription)"; return false }
    }

    public func search() async {
        guard !isSaving else { return }
        if selectedEntry != nil && selectedRequestKey == requestKey { return }
        requestGeneration += 1
        let generation = requestGeneration
        selectedEntry = nil; selectedChoices = [:]; chosenSenseID = nil; chosenFormID = nil
        manualEntry = false
        if !query.isEmpty { successMessage = nil }
        clearAutomaticText()
        await lookup.lookup(query: query, packURL: selectedPack?.packageURL)
        guard !Task.isCancelled, generation == requestGeneration else { return }
        if lookup.automaticText != nil, let entry = lookup.results.first { selectEntry(entry) }
        else { applyChoices() }
    }

    public func selectEntry(_ entry: LexicalEntry) {
        guard !isSaving else { return }
        // Selecting a prefix result completes the displayed headword. Keep an
        // exact surface-form query, including its original case and diacritics.
        let forms = [entry.canonicalForm] + entry.forms
        if !forms.contains(where: { Self.searchKey($0.text.value) == Self.searchKey(query) }) {
            query = entry.canonicalForm.text.value
        }
        selectedRequestKey = requestKey
        selectedEntry = entry; selectedChoices = [:]; chosenSenseID = nil; chosenFormID = nil
        manualEntry = false
        clearAutomaticText()
        applyChoices()
    }

    public func enterManually() {
        selectedEntry = nil; selectedChoices = [:]; manualEntry = true
        clearAutomaticText(); applyChoices()
    }

    public func setText(_ value: String, fieldID: UUID) {
        guard !isSaving else { return }
        text[fieldID] = value; manualFields.insert(fieldID)
    }

    public func choose(_ choice: VocabularyContentChoice, for fieldID: UUID) {
        guard !isSaving else { return }
        selectedChoices[fieldID] = choice.id
        manualFields.remove(fieldID)
        if let senseID = choice.senseID, chosenSenseID != senseID {
            chosenSenseID = senseID
            // Pronunciations/examples scoped to the previous meaning must be reconsidered.
            for binding in configuration?.bindings ?? [] where binding.fieldID != fieldID
                && [.pronunciationText, .pronunciationAudio, .example].contains(binding.source) {
                selectedChoices[binding.fieldID] = nil
            }
        }
        if let formID = choice.formID { chosenFormID = formID }
        applyChoices()
    }

    public func choices(for binding: VocabularyFieldBinding, entry: LexicalEntry? = nil) -> [VocabularyContentChoice] {
        guard let entry = entry ?? selectedEntry else { return [] }
        func allowsLanguage(_ language: String?) -> Bool { binding.language == nil || language == binding.language }
        switch binding.source {
        case .manual: return []
        case .typedWord: return [.init(id: "typed", text: query)]
        case .headword: return [.init(id: "headword", text: entry.canonicalForm.text.value, formID: entry.canonicalForm.id)]
        case .form:
            return entry.forms.enumerated().compactMap { index, form in
                guard (binding.variant == nil || form.kind == binding.variant), allowsLanguage(form.text.language) else { return nil }
                return .init(id: "form-\(index)", text: form.text.value, detail: form.kind, formID: form.id)
            }
        case .pronunciationText, .pronunciationAudio:
            return entry.pronunciations.enumerated().flatMap { index, pronunciation -> [VocabularyContentChoice] in
                guard binding.variant == nil || pronunciation.scheme == binding.variant,
                      chosenSenseID == nil || pronunciation.senseIDs.isEmpty || pronunciation.senseIDs.contains(chosenSenseID!),
                      pronunciation.formIDs.isEmpty || pronunciation.formIDs.contains(chosenFormID ?? entry.canonicalForm.id ?? "") else { return [] }
                return pronunciation.representations.enumerated().compactMap { representationIndex, representation in
                    let id = "pronunciation-\(index)-\(representationIndex)"
                    let detail = pronunciation.label ?? pronunciation.scheme
                    let senseID = pronunciation.senseIDs.count == 1 ? pronunciation.senseIDs[0] : nil
                    switch representation {
                    case let .text(value) where binding.source == .pronunciationText && allowsLanguage(value.language):
                        return .init(id: id, text: value.value, detail: detail, senseID: senseID)
                    case let .audio(reference) where binding.source == .pronunciationAudio:
                        return .init(id: id, text: pronunciation.label ?? entry.canonicalForm.text.value,
                                     detail: detail, audio: reference, senseID: senseID)
                    default: return nil
                    }
                }
            }
        case .meaning:
            return entry.senses.flatMap { sense in
                sense.definitions.enumerated().compactMap { index, definition in
                    guard allowsLanguage(definition.text.language) else { return nil }
                    return .init(id: "meaning-\(sense.id)-\(index)", text: definition.text.value,
                                 detail: definition.text.language, senseID: sense.id)
                }
            }
        case .example:
            return entry.senses.filter { chosenSenseID == nil || $0.id == chosenSenseID }.flatMap { sense in
                sense.examples.enumerated().compactMap { index, example in
                    guard allowsLanguage(example.text.language) else { return nil }
                    return .init(id: "example-\(sense.id)-\(index)", text: example.text.value,
                                 detail: example.text.language, senseID: sense.id)
                }
            }
        }
    }

    public func selectedChoice(for binding: VocabularyFieldBinding) -> VocabularyContentChoice? {
        let candidates = choices(for: binding).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.audio != nil }
        if let id = selectedChoices[binding.fieldID], let selected = candidates.first(where: { $0.id == id }) { return selected }
        if binding.source == .meaning, let chosenSenseID {
            let relevant = candidates.filter { $0.senseID == chosenSenseID }
            if relevant.count == 1 { return relevant[0] }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func clearAutomaticText() {
        for id in text.keys where !manualFields.contains(id) { text[id] = nil }
    }

    private func applyChoices() {
        guard configurationIssue == nil else { return }
        // Resolve meaning/form before dependent pronunciation and example bindings.
        let bindings = configuration?.bindings ?? []
        if let entry = selectedEntry {
            chosenFormID = entry.canonicalForm.id
            if bindings.contains(where: { $0.source == .typedWord }),
               let form = ([entry.canonicalForm] + entry.forms).first(where: { Self.searchKey($0.text.value) == Self.searchKey(query) }) {
                chosenFormID = form.id
            }
        }
        for binding in bindings where binding.source == .meaning || binding.source == .form {
            if let choice = selectedChoice(for: binding) {
                if binding.source == .meaning { chosenSenseID = choice.senseID }
                if binding.source == .form { chosenFormID = choice.formID }
            }
        }
        for binding in bindings where !manualFields.contains(binding.fieldID) {
            if binding.source == .typedWord { text[binding.fieldID] = query }
            else if binding.source != .manual { text[binding.fieldID] = selectedChoice(for: binding)?.text ?? "" }
        }
    }

    public func binding(for fieldID: UUID) -> VocabularyFieldBinding? {
        configuration?.bindings.first { $0.fieldID == fieldID }
    }
    public func needsChoice(_ field: FieldDef) -> Bool {
        guard !manualFields.contains(field.id), let binding = binding(for: field.id), binding.source != .manual else { return false }
        return choices(for: binding).count > 1 && selectedChoice(for: binding) == nil
    }
    public func fieldIssue(_ field: FieldDef) -> String? {
        if field.isRequired && needsChoice(field) { return "Choose \(field.name.lowercased())." }
        if field.type == .audio {
            if field.isRequired, binding(for: field.id).flatMap({ selectedChoice(for: $0)?.audio }) == nil { return "Choose audio from the dictionary." }
        } else if field.isRequired && text[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(field.name) is required."
        } else if field.type == .number, !text[field.id, default: ""].isEmpty,
                  NumberFormatter().number(from: text[field.id, default: ""]) == nil {
            return "Enter a valid number."
        }
        return nil
    }
    public var canSave: Bool {
        !isLoading && !isSaving && !isImporting && !lookup.isSearching
            && deckID != nil && selectedPack != nil && configuration != nil && configurationIssue == nil
            && (selectedEntry != nil || manualEntry)
            && itemType.map { type in type.fields.allSatisfy { fieldIssue($0) == nil } } == true
    }

    public func save() async {
        guard canSave, let deckID else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            // Recheck live schema and destination before committing a draft created earlier.
            let catalog = try await library.loadItemTypeCatalog()
            itemTypes = catalog.allItemTypes
            guard configuration?.issue(itemTypes: itemTypes) == nil else {
                throw CaptureError.message("The card setup changed. Review its field mappings before adding.")
            }
            guard let type = itemType else { throw CaptureError.message("Choose a card setup.") }
            if let issue = type.fields.compactMap({ fieldIssue($0) }).first { throw CaptureError.message(issue) }
            _ = try await library.deck(id: deckID)
            var values: [FieldValue] = []
            for field in type.fields {
                let value: ContentValue
                let raw = text[field.id, default: ""]
                switch field.type {
                case .text: value = .text(raw)
                case .richText: value = .rich(raw.isEmpty ? [] : [Span(raw)])
                case .number:
                    if raw.isEmpty { value = .empty }
                    else if let number = NumberFormatter().number(from: raw) { value = .number(number.doubleValue) }
                    else { throw CaptureError.message("Enter a valid number for \(field.name).") }
                case .audio:
                    if let binding = binding(for: field.id), let reference = selectedChoice(for: binding)?.audio,
                       let packURL = selectedPack?.packageURL {
                        let pack = try await VocabularyPack.open(at: packURL)
                        let url = try await pack.mediaURL(for: reference)
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= MediaValidation.maxBytes(for: .audio) else {
                            throw MediaError.fileTooLarge(.audio, maxBytes: MediaValidation.maxBytes(for: .audio))
                        }
                        let data = try Data(contentsOf: url)
                        let media = try await library.reserveMedia(data: data, kind: .audio,
                            altText: selectedEntry?.canonicalForm.text.value ?? query, asOf: .now)
                        value = .media(media.reference)
                    } else { value = .empty }
                default: value = .empty
                }
                values.append(FieldValue(fieldID: field.id, value: value))
            }
            // The draft owns one identity across retries; refresh failures cannot repeat the insertion.
            if try await library.item(id: draftID) == nil {
                _ = try await library.createItem(Item(id: draftID, itemTypeID: type.id, fields: values, deckID: deckID), asOf: .now)
            }
            let addedWord = query
            let destination = destinationName
            query = ""; text = [:]; manualFields = []; selectedChoices = [:]
            selectedEntry = nil; chosenSenseID = nil; chosenFormID = nil; manualEntry = false
            lookup.invalidate(); draftID = UUID()
            successMessage = "Added \(addedWord) to \(destination)."
            await onSaved()
            isSaving = false
            focusGeneration += 1
        } catch { errorMessage = error.localizedDescription }
    }

    public func importDictionary(from source: URL) async {
        guard !isSaving, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            let installed = try await VocabularyPackSyncModel(rootURL: rootURL).installLocal(from: source)
            try await reloadCatalog()
            selectDictionary(installed.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func clearDerivedDraft() {
        requestGeneration += 1; lookup.invalidate(); selectedEntry = nil; selectedRequestKey = nil
        text = [:]; manualFields = []; selectedChoices = [:]
        chosenSenseID = nil; chosenFormID = nil; manualEntry = false; successMessage = nil
    }
    private static func searchKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
    }
}
