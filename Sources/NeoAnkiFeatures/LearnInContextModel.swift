import Foundation
import CryptoKit
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Observation
import NaturalLanguage

public struct ContextMeaningChoice: Identifiable, Sendable {
    public var id: String
    public var target: ContextTarget
    public var examples: [ContextExample]
}

public struct ContextAuthoringDraft: Codable, Equatable, Sendable {
    public var target = ContextTarget(expression: "", language: "en")
    public var sourceSentence = ""
    public var deckID: UUID?
    public var examples: [ContextExample] = []
    public var groupID = UUID()
    public var cloze = false
    public var listening = false
    public var speech = true
}

private struct ContextAuthoringPreferences: Codable {
    var deckID: UUID?
    var language: String
}

@MainActor @Observable public final class LearnInContextModel {
    public var draft = ContextAuthoringDraft()
    public private(set) var decks: [DeckSummary] = []
    public private(set) var meanings: [ContextMeaningChoice] = []
    public private(set) var sources: [ContextSource] = []
    public private(set) var status: String?
    public private(set) var generationCapability = ContextCapability.unavailable("Checking Apple Intelligence…")
    public private(set) var speechCapability = ContextCapability.unavailable("Checking installed voices…")
    public private(set) var errorMessage: String?
    public private(set) var successMessage: String?
    public private(set) var isSaving = false
    public private(set) var isLoading = true
    public var hasUnappliedEdits = false
    public private(set) var isWorking = false
    public private(set) var focusGeneration = 0
    public private(set) var lastSavedIDs: [UUID] = []
    public private(set) var lastSavedItems: [Item] = []
    public private(set) var sourceLibrary: ContextSourceLibrary?
    public let library: any LibraryRepository
    private let rootURL: URL
    private let generator: any ContextGenerating
    private let speech: any ContextSpeechSynthesizing
    private let onSaved: @MainActor () async -> Void
    private var draftURL: URL?
    private var packs: [InstalledVocabularyPack] = []
    private var work: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var speechCache: [String: ContextSpeechAsset] = [:]
    private var speechPreparation: Task<ContextSpeechAsset, any Error>?
    private var speechCapabilities: [String: ContextCapability] = [:]
    private var activeItemType = ContextExamplePreset.itemType

    public init(library: any LibraryRepository, rootURL: URL,
                generator: any ContextGenerating = AppleContextGenerator(),
                speech: (any ContextSpeechSynthesizing)? = nil,
                onSaved: @escaping @MainActor () async -> Void = {}) {
        self.library = library; self.rootURL = rootURL; self.generator = generator
        self.speech = speech ?? AppleContextSpeech(); self.onSaved = onSaved
    }
    public var selectedExamples: [ContextExample] {
        draft.examples.filter {
            $0.isSelected && !$0.needsMeaningCheck
                && !($0.meaning ?? draft.target.meaning).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ContextOccurrences.validated($0.spans, in: $0.sentence)
        }
    }
    public var cardCount: Int {
        selectedExamples.reduce(0) { total, example in
            let hasAudio = example.mediaURL != nil || (draft.speech && speechAvailability(for: example) == .available)
            let preview = Item(itemTypeID: activeItemType.id, fields: [
                .init(fieldID: ContextExamplePreset.target.id, value: .text(draft.target.expression)),
                .init(fieldID: ContextExamplePreset.context.id, value: .rich([Span(example.sentence)])),
                .init(fieldID: ContextExamplePreset.meaning.id, value: .text(example.meaning ?? draft.target.meaning)),
                .init(fieldID: ContextExamplePreset.note.id, value: .text(example.usageNote)),
                .init(fieldID: ContextExamplePreset.audio.id, value: hasAudio ? .text("available") : .empty),
                .init(fieldID: ContextExamplePreset.video.id, value: example.mediaKind == .video ? .text("available") : .empty),
                .init(fieldID: ContextExamplePreset.cloze.id, value: draft.cloze ? .cloze(example.sentence, blanks: ContextOccurrences.clozeSpans(for: example, target: draft.target).map { .init(group: 1, start: $0.start, length: $0.length) }) : .empty),
                .init(fieldID: ContextExamplePreset.listening.id, value: draft.listening ? .text("enabled") : .empty)
            ])
            return total + CardGenerator.cards(for: preview, type: activeItemType).count
        }
    }
    public var canSave: Bool {
        !hasUnappliedEdits && !isLoading && !isSaving && !isWorking && cardCount > 0 && draft.deckID != nil && selectedExamples.allSatisfy { !($0.meaning ?? draft.target.meaning).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !draft.target.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedExamples.isEmpty
            && selectedExamples.allSatisfy { ContextOccurrences.validated($0.spans, in: $0.sentence) }
    }
    public func start(deckID: UUID? = nil, expression: String = "", language: String? = nil, meaning: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let libraryID = try await library.libraryID()
            let local = rootURL.appendingPathComponent(".learn-in-context/\(libraryID)", isDirectory: true)
            if let data = try? Data(contentsOf: local.appendingPathComponent("preferences.json")),
               let preferences = try? JSONDecoder().decode(ContextAuthoringPreferences.self, from: data) {
                draft.target.language = preferences.language; draft.deckID = preferences.deckID
            }
            let seed = expression.isEmpty ? "" : "-" + SHA256.hash(data: Data("\(expression)|\(language ?? "")|\(deckID?.uuidString ?? "")".utf8)).map { String(format: "%02x", $0) }.joined()
            draftURL = local.appendingPathComponent("draft\(seed).json")
            sourceLibrary = ContextSourceLibrary(rootURL: local.appendingPathComponent("sources", isDirectory: true))
            if let draftURL, FileManager.default.fileExists(atPath: draftURL.path) {
                draft = try JSONDecoder().decode(ContextAuthoringDraft.self, from: Data(contentsOf: draftURL))
            }
            // The capture flow has no practice or speech configuration, including in older drafts.
            draft.cloze = false; draft.listening = false; draft.speech = true
            draft.sourceSentence = ""
            decks = try await library.deckSummaries(asOf: .now)
            activeItemType = try await library.loadItemTypeCatalog().allItemTypes.first { $0.id == ContextExamplePreset.typeID } ?? ContextExamplePreset.itemType
            if let deckID, draft.examples.isEmpty && draft.target.expression.isEmpty { draft.deckID = deckID }
            if !decks.contains(where: { $0.id == draft.deckID }) { draft.deckID = decks.first?.id }
            if !expression.isEmpty, draft.target.expression.isEmpty {
                draft.target = .init(expression: expression, language: language ?? draft.target.language, meaning: meaning ?? "")
                draft.sourceSentence = ""; draft.examples = []; draft.groupID = UUID()
            }
            packs = try await InstalledVocabularyPackStore(rootURL: rootURL).installedPacks()
            await refreshSources(); await refreshCapabilities()
        } catch { errorMessage = error.localizedDescription }
    }
    public func refreshCapabilities() async {
        let language = draft.target.language
        let generated = await generator.availability(language: language)
        let languages = Set(draft.examples.map { $0.language ?? language } + [language])
        var spoken: [String: ContextCapability] = [:]
        for code in languages { spoken[code] = await speech.availability(language: code) }
        guard language == draft.target.language else { return }
        generationCapability = generated; speechCapabilities = spoken
        speechCapability = spoken[language] ?? .unavailable("No installed voice is available for this language. You can save text-only cards.")
    }
    public func speechAvailability(for example: ContextExample) -> ContextCapability {
        let language = example.language ?? draft.target.language
        return speechCapabilities[language] ?? .unavailable("No installed voice is available for this language. You can save text-only cards.")
    }
    public func checkpoint() {
        guard let draftURL else { return }
        do {
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic)
            let preferences = ContextAuthoringPreferences(deckID: draft.deckID, language: draft.target.language)
            try JSONEncoder().encode(preferences).write(to: draftURL.deletingLastPathComponent().appendingPathComponent("preferences.json"), options: .atomic)
        } catch { errorMessage = "Your draft could not be saved: \(error.localizedDescription)" }
    }
    @discardableResult public func cancel() -> Task<Void, Never>? {
        generation += 1
        let previous = work; previous?.cancel(); work = nil
        isWorking = false; status = nil; checkpoint()
        return previous
    }
    public func waitForWork() async { await work?.value }
    public func invalidateTarget() {
        cancel(); meanings = []; draft.examples = []; draft.groupID = UUID()
        draft.target.packID = nil; draft.target.entryID = nil; draft.target.senseID = nil; draft.target.forms = []
    }
    public func updateExpression(_ expression: String) {
        // TextField may commit the same text when focus changes. That is not a new target
        // and must not cancel the generation started by the Find Examples tap.
        guard expression != draft.target.expression else { return }
        invalidateTarget(); draft.target.expression = expression; draft.target.meaning = ""
        errorMessage = nil; successMessage = nil
    }
    public func findExamples() {
        cancel(); errorMessage = nil; successMessage = nil
        let expression = draft.target.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        // Short expressions can be ambiguous. Retain the language hint unless local detection is confident;
        // generated results identify their actual language before speech and persistence are prepared.
        let recognizer = NLLanguageRecognizer(); recognizer.processString(expression)
        if !Self.hasLimitedLanguageEvidence(expression), let detected = recognizer.dominantLanguage,
           (recognizer.languageHypotheses(withMaximum: 1)[detected] ?? 0) >= 0.8 {
            draft.target.language = detected.rawValue
        }
        let request = generation, target = draft.target
        isWorking = true; status = "Finding local examples…"
        work = Task { [weak self] in
            guard let self else { return }
            defer { if request == generation { isWorking = false; status = nil; checkpoint() } }
            do {
                let choices = try await meaningChoices(for: target)
                guard request == generation, target == draft.target else { return }
                meanings = choices
                if target.meaning.isEmpty, let first = meanings.first {
                    if meanings.count == 1 {
                        var resolved = first.target
                        if resolved.expression != target.expression { resolved.forms.append(resolved.expression) }
                        // Updating the field while it is losing focus can commit the old text and
                        // cancel this request. Lexical resolution must preserve the entered input.
                        resolved.expression = target.expression
                        draft.target = resolved
                    } else { draft.target.language = first.target.language }
                }
                await refreshCapabilities()
                guard request == generation, !Task.isCancelled else { return }
                if meanings.isEmpty, Self.hasLimitedLanguageEvidence(expression), generationCapability != .available,
                   await generator.availability(language: "en") == .available {
                    // A previous unsupported language must not block a short ambiguous expression.
                    // The generator still detects and validates the actual output language.
                    draft.target.language = "en"
                    await refreshCapabilities()
                    guard request == generation, !Task.isCancelled else { return }
                }
                try await appendExamples(request: request, count: max(0, 3 - selectedExamples.count))
            } catch { if request == generation, !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    public func chooseMeaning(_ choice: ContextMeaningChoice) {
        cancel(); draft.target = choice.target; draft.examples = []; draft.groupID = UUID()
        findExamples()
    }
    public func anotherMeaning() { cancel(); draft.examples = []; draft.target.meaning = ""; draft.target.senseID = nil; draft.groupID = UUID() }
    private func meaningChoices(for target: ContextTarget) async throws -> [ContextMeaningChoice] {
        var result: [ContextMeaningChoice] = []
        let preferred = packs.filter { $0.languages.contains(where: { Self.sameLanguage($0, target.language) }) }
        let fallback = packs.filter { !preferred.contains($0) }
        var resolvedLanguage: String?
        for installed in preferred + fallback {
            try Task.checkCancellation()
            let pack = try await VocabularyPack.open(at: installed.packageURL)
            for entry in try await pack.search(query: target.expression.trimmingCharacters(in: .whitespacesAndNewlines), mode: .exact, limit: 10) {
                if let resolvedLanguage, !Self.sameLanguage(entry.language, resolvedLanguage) { continue }
                for sense in entry.senses {
                    guard let definition = sense.definitions.first(where: { $0.text.language == entry.language }) ?? sense.definitions.first,
                          !definition.text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    resolvedLanguage = entry.language
                    let resolved = ContextTarget(expression: entry.canonicalForm.text.value, language: entry.language,
                        meaning: definition.text.value, forms: entry.forms.map { $0.text.value }, packID: installed.id, entryID: entry.id, senseID: sense.id)
                    var examples: [ContextExample] = []
                    for example in sense.examples where example.text.language == nil || Self.sameLanguage(example.text.language ?? "", entry.language) {
                        var spans = ContextOccurrences.fromPack(example.target, text: example.text.value)
                        let hasExplicitTarget = !spans.isEmpty
                        let match = ContextOccurrences.find(target: resolved, in: example.text.value)
                        if spans.isEmpty { spans = match.spans }
                        guard !spans.isEmpty else { continue }
                        let inherited = [sense.provenance, entry.provenance, pack.manifest.provenance].compactMap { $0 }
                        let source = example.provenance ?? inherited.first
                        let dictionaryGrounded = !(source?.sourceID.lowercased().contains("tatoeba") ?? false)
                        var provenance = ContextProvenance(origin: dictionaryGrounded ? .dictionary : .corpus,
                            sourceName: source?.sourceName ?? installed.title, sourceID: source?.sourceID, recordID: source?.recordID ?? example.id,
                            attribution: source?.attribution ?? inherited.compactMap(\.attribution).first,
                            license: source?.license ?? inherited.compactMap(\.license).first,
                            sourceURL: source?.sourceURL ?? inherited.compactMap(\.sourceURL).first)
                        provenance.inheritedSources = inherited.map {
                            .init(origin: .dictionary, sourceName: $0.sourceName ?? installed.title, sourceID: $0.sourceID, recordID: $0.recordID,
                                  attribution: $0.attribution, license: $0.license, sourceURL: $0.sourceURL)
                        }
                        examples.append(.init(sentence: example.text.value, spans: spans, provenance: provenance,
                                              needsMeaningCheck: !hasExplicitTarget && match.uncertain))
                        examples[examples.count - 1].meaning = resolved.meaning
                        examples[examples.count - 1].language = resolved.language
                    }
                    result.append(.init(id: "\(installed.id)/\(entry.id)/\(sense.id)", target: resolved, examples: examples))
                }
            }
        }
        return result
    }
    private func appendExamples(request: Int, count: Int, simpler: Bool = false) async throws {
        let draftTarget = draft.target
        var target = draftTarget
        target.expression = target.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let desired = selectedExamples.count + count
        // Each dictionary example retains its own sense. Capture never asks the learner to annotate it.
        let grounded = meanings.flatMap(\.examples).filter { !$0.needsMeaningCheck }
        let media = try await sourceLibrary?.examples(for: target, limit: 30) ?? []
        guard request == generation, draftTarget == draft.target else { return }
        var sourceExamples: [ContextExample] = []
        if !draft.sourceSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let match = ContextOccurrences.find(target: target, in: draft.sourceSentence)
            sourceExamples = [.init(sentence: draft.sourceSentence, spans: match.spans,
                provenance: .init(origin: .manual, sourceName: "Your source sentence"), needsMeaningCheck: true)]
        }
        let candidates = (sourceExamples + grounded + media).sorted {
            if $0.needsMeaningCheck != $1.needsMeaningCheck { return !$0.needsMeaningCheck }
            if abs($0.sentence.count - $1.sentence.count) < 15, ($0.mediaURL != nil) != ($1.mediaURL != nil) { return $0.mediaURL != nil }
            return $0.sentence.count < $1.sentence.count
        }
        if !simpler { appendUnique(candidates.filter { !$0.needsMeaningCheck }, limit: count) }
        let missing = simpler ? count : max(0, desired - selectedExamples.count)
        if missing > 0, generationCapability == .available {
            status = "Creating \(missing) more example\(missing == 1 ? "" : "s")…"
            let generated = try await generator.examples(for: target, count: missing,
                excluding: selectedExamples.map(\.sentence), simpler: simpler)
            guard request == generation, draftTarget == draft.target else { return }
            if let language = generated.first?.language {
                draft.target.language = language
            }
            appendUnique(generated.filter { !$0.needsMeaningCheck }, limit: missing)
        }
        await refreshCapabilities()
        guard request == generation, !Task.isCancelled else { return }
        if selectedExamples.isEmpty { status = nil; errorMessage = generationCapability.reason ?? "No suitable examples were found. Try another word or phrase." }
    }
    private func appendUnique(_ examples: [ContextExample], limit: Int) {
        var keys = Set(selectedExamples.map { ContextOccurrences.key($0.sentence) })
        var added = 0
        for example in examples where added < limit {
            let key = ContextOccurrences.key(example.sentence)
            guard !example.needsMeaningCheck,
                  !(example.meaning ?? draft.target.meaning).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ContextOccurrences.validated(example.spans, in: example.sentence), keys.insert(key).inserted else { continue }
            var accepted = example; accepted.isSelected = true
            if let index = draft.examples.firstIndex(where: { ContextOccurrences.key($0.sentence) == key && !$0.isEdited }) {
                draft.examples[index] = accepted
            } else { draft.examples.append(accepted) }
            added += 1
        }
    }
    public func moreExamples(simpler: Bool = false, replacing id: UUID? = nil) {
        cancel(); let request = generation
        isWorking = true; errorMessage = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { if request == generation { isWorking = false; status = nil; checkpoint() } }
            do {
                let oldIDs = Set(draft.examples.map(\.id))
                try await appendExamples(request: request, count: id == nil ? 3 : 1, simpler: simpler)
                if request == generation, let id, draft.examples.contains(where: { !oldIDs.contains($0.id) && $0.isSelected }) {
                    draft.examples.removeAll { $0.id == id }
                }
                if request == generation, !draft.examples.contains(where: { !oldIDs.contains($0.id) }) {
                    errorMessage = generationCapability.reason ?? "No additional suitable examples were found. Try another word or phrase."
                }
            } catch { if request == generation, !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    public func addManualExample() {
        var example = ContextExample(sentence: draft.sourceSentence, provenance: .init(origin: .manual, sourceName: "Your example"), needsMeaningCheck: true)
        example.spans = ContextOccurrences.find(target: draft.target, in: example.sentence).spans
        draft.examples.append(example); checkpoint()
    }
    public func editExample(_ id: UUID, sentence: String, note: String, spans: [ContextSpan]) {
        guard let index = draft.examples.firstIndex(where: { $0.id == id }) else { return }
        guard draft.examples[index].sentence != sentence || draft.examples[index].usageNote != note || draft.examples[index].spans != spans else { return }
        if !draft.examples[index].isEdited { draft.examples[index].provenance.originalText = draft.examples[index].sentence }
        if draft.examples[index].sentence != sentence {
            // A transcript correction may keep its recording; rewritten examples must explicitly detach it in the editor.
            draft.examples[index].spans = []
        }
        draft.examples[index].sentence = sentence; draft.examples[index].usageNote = note
        draft.examples[index].spans = spans; draft.examples[index].isEdited = true
        checkpoint()
    }
    public func confirmExample(_ id: UUID) {
        guard let index = draft.examples.firstIndex(where: { $0.id == id }),
              ContextOccurrences.validated(draft.examples[index].spans, in: draft.examples[index].sentence) else { return }
        draft.examples[index].needsMeaningCheck = false; draft.examples[index].isSelected = true; checkpoint()
    }
    public func preparedAudio(for example: ContextExample, language: String? = nil) async throws -> ContextSpeechAsset {
        let language = language ?? example.language ?? draft.target.language
        let key = language + "|" + example.sentence
        if let cached = speechCache[key] { return cached }
        let previous = speechPreparation
        let task = Task { @MainActor in
            // Preview and save share one synthesizer. A new request waits for the previous one
            // to finish or acknowledge cancellation before touching its writer.
            _ = await previous?.result
            try Task.checkCancellation()
            if let cached = speechCache[key] { return cached }
            let asset = try await speech.audio(text: example.sentence, language: language)
            try Task.checkCancellation()
            speechCache[key] = asset
            // Preview caching is bounded; accepted audio is stored permanently in the media store.
            if speechCache.count > 30 { speechCache = [key: asset] }
            return asset
        }
        speechPreparation = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    public func save() async {
        guard canSave, let deckID = draft.deckID else { return }
        isSaving = true; errorMessage = nil; successMessage = nil
        defer { isSaving = false; status = nil }
        var snapshot = draft
        snapshot.target.expression = snapshot.target.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedExamples
        do {
            _ = try await library.deck(id: deckID)
            let types = try await library.loadItemTypeCatalog().allItemTypes
            var preset = ContextExamplePreset.itemType
            if let existing = types.first(where: { $0.id == preset.id }) {
                let requiredIDs = Set(preset.fields.map(\.id))
                guard preset.fields.allSatisfy({ expected in existing.fields.contains { $0.id == expected.id && $0.type == expected.type } }),
                      existing.fields.allSatisfy({ !$0.isRequired || requiredIDs.contains($0.id) }) else {
                    throw ContextAuthoringError.message("The Context Example fields changed. Restore its original field types and remove extra required fields before adding context cards.")
                }
                preset = existing; activeItemType = existing
                try await library.attachItemType(id: preset.id, to: deckID)
            } else { _ = try await library.createItemType(preset, deckID: deckID, availableEverywhere: false) }
            var operations: [ItemBulkOperation] = [], savedItems: [Item] = []
            for example in selected {
                if let existing = try await library.item(id: example.id)?.item {
                    guard existing.deckID == deckID else {
                        throw ContextAuthoringError.message("These examples were already saved in another deck. Move the saved items in the library to use that deck.")
                    }
                    guard existing.itemTypeID == preset.id,
                          existing.value(for: ContextExamplePreset.group.id) == .text(snapshot.groupID.uuidString),
                          savedContentMatches(existing, example: example, snapshot: snapshot) else {
                        throw ContextAuthoringError.message("This example was already saved with different content. Your draft is preserved. Edit the saved item in the library, or enter another word or phrase.")
                    }
                    savedItems.append(existing)
                    continue
                }
                status = "Preparing \(operations.count + 1) of \(selected.count) examples…"
                var audio: MediaRef?, video: MediaRef?, voiceID: String?
                if let url = example.mediaURL, let kind = example.mediaKind {
                    let data: Data
                    if let start = example.clipStart, let end = example.clipEnd { data = try await ContextMediaPreparation.clip(url: url, kind: kind, start: start, end: end) }
                    else {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= MediaValidation.maxBytes(for: kind) else { throw MediaError.fileTooLarge(kind, maxBytes: MediaValidation.maxBytes(for: kind)) }
                        data = try Data(contentsOf: url)
                    }
                    let fileExtension = example.clipStart == nil ? url.pathExtension : (kind == .video ? "mp4" : "m4a")
                    let ref = try await storeMedia(data, kind: kind, fileExtension: fileExtension, sentence: example.sentence)
                    if kind == .video { video = ref } else { audio = ref }
                    if snapshot.listening, kind == .video, let start = example.clipStart, let end = example.clipEnd {
                        let data = try await ContextMediaPreparation.clip(url: url, kind: .audio, start: start, end: end)
                        audio = try await storeMedia(data, kind: .audio, fileExtension: "m4a", sentence: example.sentence)
                    }
                } else if snapshot.speech {
                    let language = example.language ?? snapshot.target.language
                    if await speech.availability(language: language) == .available {
                        let asset = try await preparedAudio(for: example, language: language); voiceID = asset.voiceID
                        audio = try await storeMedia(asset.data, kind: .audio, fileExtension: "caf", sentence: example.sentence)
                    }
                }
                var exampleTarget = snapshot.target
                exampleTarget.meaning = example.meaning ?? snapshot.target.meaning
                exampleTarget.language = example.language ?? snapshot.target.language
                let metadata = SavedContextMetadata(groupID: snapshot.groupID, target: exampleTarget, spans: example.spans, provenance: example.provenance,
                    clipStart: example.clipStart, clipEnd: example.clipEnd, voiceID: voiceID, speechText: voiceID == nil ? nil : example.sentence)
                let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
                let item = Item(id: example.id, itemTypeID: preset.id, fields: [
                    .init(fieldID: ContextExamplePreset.target.id, value: .text(snapshot.target.expression, lang: exampleTarget.language)),
                    .init(fieldID: ContextExamplePreset.context.id, value: .rich(ContextOccurrences.richText(example.sentence, spans: example.spans))),
                    .init(fieldID: ContextExamplePreset.meaning.id, value: .text(example.meaning ?? snapshot.target.meaning)),
                    .init(fieldID: ContextExamplePreset.note.id, value: .text(example.usageNote)),
                    .init(fieldID: ContextExamplePreset.audio.id, value: audio.map(ContentValue.media) ?? .empty),
                    .init(fieldID: ContextExamplePreset.video.id, value: video.map(ContentValue.media) ?? .empty),
                    .init(fieldID: ContextExamplePreset.cloze.id, value: snapshot.cloze ? .cloze(example.sentence, blanks: ContextOccurrences.clozeSpans(for: example, target: snapshot.target).map { .init(group: 1, start: $0.start, length: $0.length) }) : .empty),
                    .init(fieldID: ContextExamplePreset.listening.id, value: snapshot.listening ? .text("enabled") : .empty),
                    .init(fieldID: ContextExamplePreset.metadata.id, value: .text(json)),
                    .init(fieldID: ContextExamplePreset.group.id, value: .text(snapshot.groupID.uuidString))
                ], deckID: deckID)
                savedItems.append(item)
                if try await library.item(id: item.id) == nil { operations.append(.init(operationID: item.id.uuidString, action: .create(item))) }
            }
            if !operations.isEmpty { _ = try await library.performBulkItemOperations(operations, asOf: .now) }
            lastSavedItems = savedItems; lastSavedIDs = savedItems.map(\.id)
            let count = savedItems.reduce(0) { $0 + CardGenerator.cards(for: $1, type: preset).count }
            draft.examples = []; draft.target.expression = ""; draft.target.meaning = ""; draft.target.forms = []
            draft.target.packID = nil; draft.target.entryID = nil; draft.target.senseID = nil
            draft.sourceSentence = ""; draft.groupID = UUID(); meanings = []
            checkpoint(); focusGeneration += 1
            let message = "Added \(count) card\(count == 1 ? "" : "s") to \(decks.first { $0.id == deckID }?.name ?? "your deck")."
            isSaving = false; successMessage = message
            notifyCommittedChange()
        } catch { errorMessage = error.localizedDescription; checkpoint() }
    }
    public func undoSave() async {
        guard !isSaving, !lastSavedItems.isEmpty else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await library.deleteUnchangedUnreviewedItems(lastSavedItems, asOf: .now)
            lastSavedItems = []; lastSavedIDs = []; successMessage = "Undid the added cards."; notifyCommittedChange()
        } catch { errorMessage = error.localizedDescription }
    }
    public func refreshSources() async { do { sources = try await sourceLibrary?.sources() ?? [] } catch { errorMessage = error.localizedDescription } }
    public func report(_ error: any Error) { errorMessage = error.localizedDescription }

    private func notifyCommittedChange() {
        let previous = refreshTask, notify = onSaved
        // Device publication can await a system notification-permission dialog. It is not part
        // of the committed library transaction and must not keep authoring or Undo disabled.
        refreshTask = Task { await previous?.value; await notify() }
    }

    private func storeMedia(_ data: Data, kind: MediaKind, fileExtension: String, sentence: String) async throws -> MediaRef {
        guard let store = await library.mediaStore() else { throw ContextAuthoringError.message("Media storage is unavailable. Your draft is preserved.") }
        // The preparation pipeline knows the container. Validate that declared container rather than
        // guessing from compatible ISO brands, which can identify an M4A as both audio and video.
        return try await store.ingest(data: data, kind: kind, fileExtension: fileExtension, altText: sentence)
    }

    private func savedContentMatches(_ item: Item, example: ContextExample, snapshot: ContextAuthoringDraft) -> Bool {
        var exampleTarget = snapshot.target
        exampleTarget.meaning = example.meaning ?? snapshot.target.meaning
        exampleTarget.language = example.language ?? snapshot.target.language
        guard case let .text(json, _)? = item.value(for: ContextExamplePreset.metadata.id),
              let metadata = try? JSONDecoder().decode(SavedContextMetadata.self, from: Data(json.utf8)),
              metadata.target == exampleTarget, metadata.spans == example.spans, metadata.provenance == example.provenance,
              metadata.clipStart == example.clipStart, metadata.clipEnd == example.clipEnd,
              item.value(for: ContextExamplePreset.context.id) == .rich(ContextOccurrences.richText(example.sentence, spans: example.spans)),
              item.value(for: ContextExamplePreset.note.id) == .text(example.usageNote),
              item.value(for: ContextExamplePreset.meaning.id) == .text(exampleTarget.meaning),
              item.isFieldEmpty(ContextExamplePreset.cloze.id) == !snapshot.cloze,
              item.isFieldEmpty(ContextExamplePreset.listening.id) == !snapshot.listening else { return false }
        return metadata.voiceID == nil || (snapshot.speech && metadata.speechText == example.sentence)
    }
    private static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(separator: "-").first == rhs.split(separator: "-").first
    }
    private static func hasLimitedLanguageEvidence(_ expression: String) -> Bool {
        expression.split(whereSeparator: \.isWhitespace).count < 3 && expression.unicodeScalars.allSatisfy {
            !CharacterSet.letters.contains($0) || $0.value <= 0x024F
        }
    }
}
