import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI
import UniformTypeIdentifiers

private func languageName(_ code: String) -> String {
    Locale.current.localizedString(forIdentifier: code) ?? code
}

private struct VocabularyLanguagePicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    var available: [String] = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)

    var body: some View {
        Picker(title, selection: $selection) {
            if selection.isEmpty { Text("Choose Language").tag("") }
            ForEach(Array(Set(available + [selection]).subtracting([""])).sorted {
                languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
            }, id: \.self) { code in
                Text(languageName(code)).tag(code)
            }
        }
    }
}

private struct KnownWordsCSV: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private enum WordListFileError: LocalizedError {
    case tooLarge, unreadable
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Choose a word list smaller than 20 MB."
        case .unreadable: "Save the word list as UTF-8 text, then try again."
        }
    }
}

/// Reads a chosen word list. Not isolated to the main actor, so a large file can be read in the background.
private func readWordListFile(at url: URL) throws -> String {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 20_000_000 {
        throw WordListFileError.tooLarge
    }
    let data = try Data(contentsOf: url)
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
       let text = String(data: data, encoding: .utf16) { return text }
    guard let text = String(data: data, encoding: .utf8) else { throw WordListFileError.unreadable }
    return text
}

public struct KnownWordsView: View {
    private static let filters: [VocabularyReadingState] = [.known, .learning, .unfamiliar, .ignored]
    private struct Undo { let term: VocabularyTerm; let judgment: VocabularyJudgment; let message: String }
    private struct ImportRequest: Identifiable { let id = UUID(); let language: String; let text: String; let fromFile: Bool }

    private let vocabulary: any PersonalVocabulary
    private let decks: any LibraryDeckManaging
    private let onCreated: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("vocabularyLearningLanguage") private var language = ""
    @State private var rows: [VocabularyStatus] = []
    @State private var counts: [VocabularyReadingState: Int] = [:]
    @State private var savedLanguages: [String] = []
    @State private var filter = VocabularyReadingState.known
    @State private var query = ""
    @State private var isAdding = false
    @State private var error: String?
    @State private var undo: Undo?
    @State private var lastImport: VocabularyBatchReceipt?
    @State private var pendingRefresh: Task<Void, Never>?
    /// Identifies `pendingRefresh`, so a superseded debounce task cannot clear a newer one.
    @State private var pendingRefreshID: UUID?
    /// Incremented by every refresh; only the latest one may apply its results.
    @State private var refreshGeneration = 0
    @State private var isUndoingImport = false
    @State private var isChoosingFile = false
    @State private var importRequest: ImportRequest?
    @State private var exportDocument: KnownWordsCSV?
    @State private var isExporting = false

    public init(vocabulary: any PersonalVocabulary, decks: any LibraryDeckManaging,
                onCreated: @escaping @MainActor () async -> Void = {}) {
        self.vocabulary = vocabulary; self.decks = decks; self.onCreated = onCreated
    }

    /// Rows are loaded for the selected language and already sorted.
    private var visible: [VocabularyStatus] {
        rows.filter {
            $0.state == filter
                && (query.isEmpty || $0.term.expression.localizedStandardContains(query)
                    || ($0.term.sense?.localizedStandardContains(query) ?? false))
        }
    }

    public var body: some View {
        List {
            Section {
                VocabularyLanguagePicker(title: "Learning language", selection: $language,
                                         available: Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + savedLanguages)
                if !language.isEmpty { filterControl }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                Button("Retry") { Task { await refresh() } }
            }
            if let undo {
                HStack {
                    Text(undo.message).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { Task { await revert(undo) } }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("known-words-undo")
                }
            }
            if let lastImport {
                HStack {
                    if lastImport.recorded == 0 {
                        Label("Every word in the list was already recorded.", systemImage: "checkmark.circle")
                    } else {
                        Label("Imported \(lastImport.recorded.formatted()) \(lastImport.recorded == 1 ? "word" : "words")",
                              systemImage: "square.and.arrow.down")
                        Spacer()
                        Button("Undo") { Task { await undoImport(lastImport) } }
                            .buttonStyle(.borderless)
                            .disabled(isUndoingImport)
                            .accessibilityIdentifier("known-words-import-undo")
                    }
                }
            }
            let shown = visible
            if shown.isEmpty, error == nil {
                if !language.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    let empty = emptyMessage
                    ContentUnavailableView(empty.title, systemImage: empty.image, description: Text(empty.detail))
                }
            }
            ForEach(shown) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.term.expression)
                        if let sense = row.term.sense, !sense.isEmpty {
                            Text(sense).foregroundStyle(.secondary)
                        }
                        Text(caption(for: row)).font(.caption).foregroundStyle(.secondary)
                        if row.clozeMature {
                            Label("Cloze recall", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu { actions(for: row) } label: {
                        Label("Actions for \(row.term.expression)", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("Known Words")
        .searchable(text: $query, prompt: "Find a word")
        .toolbar {
            Button("Add Word", systemImage: "plus") { isAdding = true }
                .accessibilityIdentifier("known-words-add")
            Menu {
                Button("Import Word List…", systemImage: "doc") { isChoosingFile = true }
                    .accessibilityIdentifier("known-words-import")
                Button("Paste Word List…", systemImage: "doc.on.clipboard") {
                    importRequest = .init(language: language, text: "", fromFile: false)
                }
                .accessibilityIdentifier("known-words-paste")
                Button("Export Word List…", systemImage: "square.and.arrow.up") {
                    exportDocument = KnownWordsCSV(VocabularyListFormat.csv(rows))
                    isExporting = true
                }
                .disabled(rows.isEmpty)
                .accessibilityIdentifier("known-words-export")
            } label: {
                Label("Word List", systemImage: "list.bullet.rectangle")
            }
            .disabled(language.isEmpty)
            .accessibilityIdentifier("known-words-word-list")
        }
        .sheet(isPresented: $isAdding, onDismiss: { Task { await refresh() } }) {
            VocabularyComposerView(vocabulary: vocabulary, decks: decks, language: language) {
                await onCreated()
            }
        }
        .sheet(item: $importRequest) { request in
            KnownWordsImportView(vocabulary: vocabulary, language: request.language, text: request.text,
                                 reviewsImmediately: request.fromFile) { receipt in
                undo = nil
                lastImport = receipt
                Task { await refresh() }
            }
        }
        .fileImporter(isPresented: $isChoosingFile,
                      allowedContentTypes: [.plainText, .commaSeparatedText, .tabSeparatedText]) { result in
            switch result {
            case let .success(url): Task { await loadWordList(at: url) }
            case let .failure(failure): error = failure.localizedDescription
            }
        }
        // Kept on a separate view: an importer and an exporter on the same view can block each other.
        .background {
            Color.clear.fileExporter(isPresented: $isExporting, document: exportDocument,
                                     contentType: .commaSeparatedText,
                                     defaultFilename: "Known Words – \(languageName(language))") { result in
                if case let .failure(failure) = result { error = failure.localizedDescription }
            }
        }
        .refreshable { await refresh() }
        .task {
            // Languages with saved words, including regional codes the standard list lacks.
            guard let all = try? await vocabulary.vocabularyStatuses(language: nil) else { return }
            savedLanguages = Set(all.map(\.term.language)).sorted()
            if language.isEmpty, let first = savedLanguages.first { language = first }
        }
        .task(id: language) { await refresh() }
        .task {
            if let source = vocabulary as? any LibraryChangePersisting {
                for await _ in await source.changeNotifications() {
                    guard !Task.isCancelled else { break }
                    refreshSoon()
                }
            }
        }
        .task {
            for await _ in await vocabulary.vocabularyNotifications() {
                guard !Task.isCancelled else { break }
                refreshSoon()
            }
        }
        .onChange(of: language) { _, _ in
            rows = []; counts = [:]; undo = nil; lastImport = nil
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
        .onDisappear { pendingRefresh?.cancel(); pendingRefresh = nil; pendingRefreshID = nil }
    }

    @ViewBuilder private var filterControl: some View {
        if dynamicTypeSize.isAccessibilitySize {
            filterPicker(counted: true).pickerStyle(.menu)
        } else {
            ViewThatFits(in: .horizontal) {
                filterPicker(counted: true).pickerStyle(.segmented)
                filterPicker(counted: false).pickerStyle(.segmented)
            }
        }
    }

    private func filterPicker(counted: Bool) -> some View {
        Picker("Show", selection: $filter) {
            ForEach(Self.filters, id: \.self) { state in
                Text(counted ? "\(Self.title(of: state)) (\((counts[state] ?? 0).formatted()))" : Self.title(of: state))
                    .tag(state)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("known-words-filter")
    }

    private static func title(of state: VocabularyReadingState) -> String {
        switch state {
        case .known: "Known"
        case .learning: "Learning"
        case .unfamiliar: "Not known"
        case .ignored: "Ignored"
        case .unassessed: "Not assessed"
        }
    }

    private var emptyMessage: (title: LocalizedStringKey, image: String, detail: LocalizedStringKey) {
        if language.isEmpty { return ("Choose a Learning Language", "text.book.closed", "Known words are kept by language.") }
        switch filter {
        case .learning:
            return ("No Words in Progress", "text.book.closed", "Words you’re studying with vocabulary cards appear here.")
        case .unfamiliar:
            return ("No Words Marked Not Known", "text.book.closed", "Words you remove from Known appear here.")
        case .ignored:
            return ("No Ignored Words", "text.book.closed",
                    "Ignore names, brands, and loanwords to leave them out of reading highlights.")
        default:
            return ("No Known Words Yet", "text.book.closed",
                    "Mark words you understand, import a word list, or learn words by reviewing vocabulary cards.")
        }
    }

    private func caption(for row: VocabularyStatus) -> LocalizedStringKey {
        switch row.state {
        case .known:
            if row.origin == .archivedReviews { return "Kept from deleted cards" }
            return row.explicitJudgment == .known ? "Marked by you" : "From reviews"
        case .learning: return "Learning"
        case .unfamiliar: return "Not known"
        case .ignored: return "Ignored"
        case .unassessed: return "Not assessed"
        }
    }

    @ViewBuilder private func actions(for row: VocabularyStatus) -> some View {
        if row.state == .known {
            Button("Remove from Known") { Task { await change(.unfamiliar, for: row) } }
        } else {
            Button("I Know This") { Task { await change(.known, for: row) } }
        }
        if row.state != .ignored {
            Button("Ignore") { Task { await change(.ignored, for: row) } }
        }
        if row.explicitJudgment != nil {
            Button("Use Review History") { Task { await change(.reviewHistory, for: row) } }
        }
    }

    /// Bursts of changes, such as a study session or a sync, refresh the list once.
    private func refreshSoon() {
        guard pendingRefresh == nil else { return }
        let token = UUID()
        pendingRefreshID = token
        pendingRefresh = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            // Whoever cancelled this task already cleared it; a newer task may own the handle now.
            guard !Task.isCancelled, pendingRefreshID == token else { return }
            pendingRefresh = nil
            pendingRefreshID = nil
            await refresh()
        }
    }

    /// Loads the selected language. Results apply only if no newer refresh started meanwhile.
    /// Returns the rows this call loaded, whether or not they were applied, or `nil` if loading failed.
    @discardableResult
    private func refresh() async -> [VocabularyStatus]? {
        refreshGeneration += 1
        let generation = refreshGeneration
        let requested = language
        guard !requested.isEmpty else { rows = []; counts = [:]; return nil }
        do {
            let loaded = try await vocabulary.vocabularyStatuses(language: requested)
            let sorted = await Task.detached(priority: .userInitiated) {
                loaded.sorted { $0.term.expression.localizedStandardCompare($1.term.expression) == .orderedAscending }
            }.value
            guard generation == refreshGeneration, requested == language else { return sorted }
            rows = sorted
            counts = Dictionary(grouping: sorted, by: \.state).mapValues(\.count)
            error = nil
            return sorted
        } catch {
            if generation == refreshGeneration, requested == language { self.error = error.localizedDescription }
            return nil
        }
    }

    private func change(_ judgment: VocabularyJudgment, for row: VocabularyStatus) async {
        let term = row.term
        do {
            _ = try await vocabulary.setVocabularyJudgment(judgment, for: term, changeID: UUID())
            lastImport = nil
            // Use this call's own rows: a newer refresh may still be running and `rows` may be stale.
            let message: String
            if let loaded = await refresh() {
                message = loaded.first { $0.term.id == term.id }
                    .map { "Moved “\(term.expression)” to \(Self.title(of: $0.state))." }
                    ?? "Removed “\(term.expression)” from Known Words."
            } else {
                message = "Updated “\(term.expression)”."
            }
            undo = Undo(term: term, judgment: row.explicitJudgment ?? .reviewHistory, message: message)
        } catch { self.error = error.localizedDescription }
    }

    private func revert(_ undo: Undo) async {
        do {
            _ = try await vocabulary.setVocabularyJudgment(undo.judgment, for: undo.term, changeID: UUID())
            self.undo = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func undoImport(_ receipt: VocabularyBatchReceipt) async {
        // Set before the first suspension, so a second tap sees it and sends no second request.
        guard !isUndoingImport else { return }
        isUndoingImport = true
        defer { isUndoingImport = false }
        do {
            _ = try await vocabulary.undoVocabularyBatch(receipt.batchID, undoID: UUID())
            lastImport = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    /// Reads and decodes the file off the main actor, then shows its preview for the language it was chosen for.
    private func loadWordList(at url: URL) async {
        let code = language
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try readWordListFile(at: url)
            }.value
            importRequest = .init(language: code, text: text, fromFile: true)
        } catch { self.error = error.localizedDescription }
    }
}

/// Paste a list, or review one read from a file, then record every word in one undoable batch.
private struct KnownWordsImportView: View {
    let vocabulary: any PersonalVocabulary
    let language: String
    let reviewsImmediately: Bool
    let onImported: @MainActor (VocabularyBatchReceipt) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var preview: VocabularyListFormat.ParseResult?
    /// Stays the same while one preview is shown, so retrying an import cannot record it twice.
    @State private var batchID = UUID()
    @State private var busy = false
    @State private var error: String?

    init(vocabulary: any PersonalVocabulary, language: String, text: String, reviewsImmediately: Bool,
         onImported: @escaping @MainActor (VocabularyBatchReceipt) -> Void) {
        self.vocabulary = vocabulary; self.language = language
        self.reviewsImmediately = reviewsImmediately; self.onImported = onImported
        _text = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    summary(of: preview)
                } else if reviewsImmediately {
                    if error == nil { ProgressView("Reading word list…") }
                } else {
                    Section {
                        TextEditor(text: $text)
                            .frame(minHeight: 180)
                            .autocorrectionDisabled()
#if os(iOS)
                            .textInputAutocapitalization(.never)
#endif
                            .accessibilityIdentifier("known-words-paste-text")
                    } header: {
                        Text("Words in \(languageName(language))")
                    } footer: {
                        Text("Put one word or phrase on each line. A CSV or TSV list with a header row can also set judgment, sense, and lemma columns.")
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(preview == nil && !reviewsImmediately ? "Paste Word List" : "Import Word List")
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let preview {
                        let count = preview.entries.count
                        Button("Import \(count.formatted()) \(count == 1 ? "Word" : "Words")") {
                            Task { await save(preview) }
                        }
                        .disabled(busy || count == 0)
                        .accessibilityIdentifier("known-words-import-confirm")
                    } else if !reviewsImmediately {
                        Button("Review") { Task { await makePreview() } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("known-words-paste-review")
                    }
                }
            }
            .task { if reviewsImmediately, preview == nil { await makePreview() } }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 350)
#endif
    }

    @ViewBuilder private func summary(of preview: VocabularyListFormat.ParseResult) -> some View {
        let judgments = Dictionary(grouping: preview.entries, by: \.judgment).mapValues(\.count)
        Section {
            LabeledContent("Language", value: languageName(language))
            LabeledContent("Words", value: preview.entries.count.formatted())
            if judgments.keys.contains(where: { $0 != .known }) {
                ForEach(VocabularyJudgment.recordable, id: \.self) { judgment in
                    if let count = judgments[judgment] {
                        LabeledContent(Self.title(of: judgment), value: count.formatted())
                    }
                }
            }
            if preview.duplicates > 0 {
                LabeledContent("Duplicates skipped", value: preview.duplicates.formatted())
            }
            if !preview.rejectedLines.isEmpty {
                LabeledContent("Unreadable lines", value: preview.rejectedLines.count.formatted())
                Text(Self.lines(preview.rejectedLines)).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text(preview.entries.isEmpty ? "No words found. Put one word or phrase on each line."
                 : "Words are marked known unless the list sets another judgment. You can undo the import afterward.")
        }
        if !reviewsImmediately {
            Section { Button("Edit List") { self.preview = nil; error = nil } }
        }
    }

    private static func title(of judgment: VocabularyJudgment) -> LocalizedStringKey {
        switch judgment {
        case .known: "Known"
        case .unfamiliar: "Not known"
        case .ignored: "Ignored"
        default: "Use review history"
        }
    }

    private static func lines(_ numbers: [Int]) -> String {
        let shown = numbers.prefix(5).map { $0.formatted() }.joined(separator: ", ")
        let label = numbers.count == 1 ? "Line \(shown)" : "Lines \(shown)"
        return numbers.count > 5 ? "\(label) and \((numbers.count - 5).formatted()) more" : label
    }

    private func makePreview() async {
        let source = text, code = language
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try VocabularyListFormat.parse(source, language: code)
            }.value
            batchID = UUID()
            preview = result
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ preview: VocabularyListFormat.ParseResult) async {
        busy = true
        defer { busy = false }
        do {
            let receipt = try await vocabulary.setVocabularyJudgments(preview.entries, batchID: batchID)
            onImported(receipt)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

public struct VocabularyComposerView: View {
    private let vocabulary: any PersonalVocabulary
    private let deckManager: any LibraryDeckManaging
    private let onSaved: @MainActor () async -> Void
    private let selectingCard: Bool
    private let markOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum FocusedField { case word, sentence, meaning }
    @FocusState private var focusedField: FocusedField?
    @AppStorage("vocabularyLearningLanguage") private var activeLanguage = ""
    @AppStorage("vocabularyMeaningLanguage") private var preferredMeaningLanguage = ""
    @State private var draft: VocabularySetDraft
    @State private var word: String
    @State private var language: String
    @State private var deckOptions: [DeckSummary] = []
    @State private var makingCards: Bool
    @State private var useSecondSentence = true
    @State private var busy = false
    @State private var error: String?
    @State private var saveID = UUID()

    public init(vocabulary: any PersonalVocabulary, decks: any LibraryDeckManaging, language: String = "",
                preset: VocabularySetDraft? = nil, markOnly: Bool = false, onSaved: @escaping @MainActor () async -> Void = {}) {
        self.vocabulary = vocabulary; deckManager = decks; self.onSaved = onSaved
        let initial = preset ?? .init(term: .init(language: language, expression: ""), meaning: "",
                                      meaningLanguage: "", sentence: "")
        _draft = State(initialValue: initial)
        _word = State(initialValue: initial.term.expression)
        _language = State(initialValue: initial.term.language)
        _makingCards = State(initialValue: preset != nil && !markOnly)
        selectingCard = preset != nil && !markOnly
        self.markOnly = markOnly
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VocabularyLanguagePicker(title: "Learning language", selection: $language)
                    TextField("Word or phrase", text: $word).autocorrectionDisabled()
                        .focused($focusedField, equals: .word)
                        .accessibilityIdentifier("vocabulary-set-word")
                    if !selectingCard && !markOnly {
                        if dynamicTypeSize.isAccessibilitySize {
                            intentionPicker.pickerStyle(.menu)
                        } else {
                            intentionPicker.pickerStyle(.segmented)
                        }
                    }
                }
                if makingCards {
                    Section("Context") {
                        TextField("Example sentence", text: $draft.sentence, axis: .vertical)
                            .focused($focusedField, equals: .sentence)
                            .accessibilityIdentifier("vocabulary-set-sentence")
                        TextField("Meaning", text: $draft.meaning, axis: .vertical)
                            .focused($focusedField, equals: .meaning)
                            .accessibilityIdentifier("vocabulary-set-meaning")
                        VocabularyLanguagePicker(title: "Meaning language", selection: $draft.meaningLanguage)
                        Picker("Deck", selection: $draft.deckID) {
                            Text("Unassigned").tag(UUID?.none)
                            ForEach(deckOptions) { deck in Text(deck.name).tag(Optional(deck.id)) }
                        }
                        if draft.productionSentence != nil {
                            Toggle("Use second sentence for Cloze", isOn: $useSecondSentence)
                        }
                        if let preview {
                            LabeledContent("Cloze", value: preview)
                        } else if !draft.sentence.isEmpty {
                            Text("Use a sentence containing the target form once.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(makingCards ? "Create Vocabulary Set" : "Add Known Word")
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(makingCards ? "Create Card Set" : "I Know This") { Task { await save() } }
                        .accessibilityIdentifier("vocabulary-set-save")
                        .disabled(busy || word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || language.isEmpty || (makingCards && (preview == nil || draft.meaning.isEmpty || draft.sentence.isEmpty)))
                }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide Keyboard") { focusedField = nil }
                }
#endif
            }
            .task {
                if language.isEmpty { language = activeLanguage }
                if draft.meaningLanguage.isEmpty {
                    draft.meaningLanguage = preferredMeaningLanguage.isEmpty
                        ? Locale.current.language.languageCode?.identifier ?? "en" : preferredMeaningLanguage
                }
            }
            .task(id: makingCards) {
                guard makingCards else { return }
                do { deckOptions = try await deckManager.deckSummaries(asOf: .now) }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: word) { _, _ in
                saveID = UUID()
                if VocabularyTerm.normalized(word) != VocabularyTerm.normalized(draft.term.expression) {
                    useSecondSentence = false
                }
            }
            .onChange(of: useSecondSentence) { _, _ in saveID = UUID() }
            .onChange(of: draft) { _, _ in saveID = UUID() }
            .onChange(of: language) { _, _ in saveID = UUID() }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 350)
#endif
    }

    private var intentionPicker: some View {
        Picker("Add word", selection: $makingCards) {
            Text("Mark Known").tag(false)
            Text("Create Cards").tag(true)
        }
        .labelsHidden()
        .accessibilityIdentifier("vocabulary-set-mode")
    }

    private var term: VocabularyTerm {
        .init(language: language, expression: word,
              sense: VocabularyTerm.normalized(word) == VocabularyTerm.normalized(draft.term.expression)
                  && language == draft.term.language ? draft.term.sense : nil)
    }

    private var preview: String? {
        let sentence = (useSecondSentence ? draft.productionSentence : nil) ?? draft.sentence
        let form = (useSecondSentence ? draft.productionForm : nil) ?? word.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = VocabularySet.occurrences(of: form, in: sentence, language: language)
        guard matches.count == 1, let span = matches.first else { return nil }
        return ClozeValidation.displayText(from: sentence, blanks: [.init(group: 1,
            start: sentence.distance(from: sentence.startIndex, to: span.lowerBound),
            length: sentence.distance(from: span.lowerBound, to: span.upperBound))], revealed: false)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            if makingCards {
                var submitted = draft
                submitted.term = term
                if !useSecondSentence {
                    submitted.productionSentence = nil
                    submitted.productionForm = nil
                    submitted.productionOccurrence = nil
                }
                _ = try await vocabulary.createVocabularySet(submitted, id: saveID)
                preferredMeaningLanguage = draft.meaningLanguage
            } else {
                // A reading judgment applies to the word in every meaning.
                _ = try await vocabulary.setVocabularyJudgment(.known, for: term.withoutSense, changeID: saveID)
            }
            activeLanguage = language
            await onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

public struct VocabularyCaptureActions: View {
    let vocabulary: any PersonalVocabulary
    let decks: any LibraryDeckManaging
    let term: VocabularyTerm
    let preset: VocabularySetDraft
    var onCreated: @MainActor () async -> Void
    @AppStorage("vocabularyLearningLanguage") private var learningLanguage = ""
    @State private var error: String?
    @State private var isComposing = false
    @State private var isChoosingLanguage = false
    @State private var isKnown = false
    @State private var busy = false
    @State private var prior: VocabularyJudgment?

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { buttons }
                VStack(alignment: .leading) { buttons }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: currentTerm.id) {
            prior = nil
            await refresh()
        }
        .sheet(isPresented: $isComposing, onDismiss: { Task { await refresh() } }) {
            VocabularyComposerView(vocabulary: vocabulary, decks: decks, preset: preset, onSaved: onCreated)
        }
        .sheet(isPresented: $isChoosingLanguage, onDismiss: { Task { await refresh() } }) {
            VocabularyComposerView(vocabulary: vocabulary, decks: decks, preset: preset, markOnly: true)
        }
    }

    private var currentTerm: VocabularyTerm {
        term.language.isEmpty ? .init(language: learningLanguage, expression: term.expression, sense: term.sense) : term
    }

    @ViewBuilder private var buttons: some View {
        Button(isKnown ? "Known" : "I Know This", systemImage: isKnown ? "checkmark.circle.fill" : "checkmark.circle") {
            if currentTerm.language.isEmpty { isChoosingLanguage = true }
            else { Task { await mark() } }
        }
        .buttonStyle(.borderless)
        .disabled(busy || isKnown)
        if let prior {
            Button("Undo") {
                Task {
                    do {
                        _ = try await vocabulary.setVocabularyJudgment(prior, for: currentTerm.withoutSense, changeID: UUID())
                        self.prior = nil
                        await refresh()
                    } catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderless)
        }
        Button("Create Card Set…") { isComposing = true }.buttonStyle(.borderless)
    }

    /// The spelling is known when any of its meanings is, the same rule reading highlights use.
    private func refresh() async {
        let key = currentTerm
        guard !key.language.isEmpty else { isKnown = false; return }
        do {
            let statuses = try await vocabulary.vocabularyStatuses(language: key.language, expression: key.expression)
            guard !Task.isCancelled, key == currentTerm else { return }
            isKnown = statuses.contains { ($0.expressionState ?? $0.state) == .known }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Records the word without a meaning, so it is known in every sense; card sets keep the sense.
    private func mark() async {
        let key = currentTerm
        let word = key.withoutSense
        busy = true
        defer { busy = false }
        do {
            let previous = try await vocabulary.vocabularyStatuses(language: word.language, expression: word.expression)
                .first { $0.term.id == word.id }
            _ = try await vocabulary.setVocabularyJudgment(.known, for: word, changeID: UUID())
            guard key == currentTerm else { return }
            prior = previous?.explicitJudgment ?? .reviewHistory
            learningLanguage = key.language
            isKnown = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
