import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

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

public struct KnownWordsView: View {
    private let vocabulary: any PersonalVocabulary
    private let decks: any LibraryDeckManaging
    private let onCreated: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("vocabularyLearningLanguage") private var language = ""
    @State private var rows: [VocabularyStatus] = []
    @State private var query = ""
    @State private var isAdding = false
    @State private var error: String?
    @State private var undo: (term: VocabularyTerm, judgment: VocabularyJudgment)?

    public init(vocabulary: any PersonalVocabulary, decks: any LibraryDeckManaging,
                onCreated: @escaping @MainActor () async -> Void = {}) {
        self.vocabulary = vocabulary; self.decks = decks; self.onCreated = onCreated
    }

    private var visible: [VocabularyStatus] {
        rows.filter {
            $0.term.language == language && $0.isKnown
                && (query.isEmpty || $0.term.expression.localizedStandardContains(query)
                    || ($0.term.sense?.localizedStandardContains(query) ?? false))
        }.sorted { $0.term.expression.localizedStandardCompare($1.term.expression) == .orderedAscending }
    }

    public var body: some View {
        List {
            Section {
                VocabularyLanguagePicker(title: "Learning language", selection: $language,
                                         available: Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + rows.map(\.term.language))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                Button("Retry") { Task { await refresh() } }
            }
            if let undo {
                Button("Undo") { Task { await change(undo.judgment, term: undo.term, previous: nil) } }
            }
            if visible.isEmpty, error == nil {
                ContentUnavailableView(
                    language.isEmpty ? "Choose a Learning Language" : query.isEmpty ? "No Known Words Yet" : "No Matching Words",
                    systemImage: query.isEmpty ? "text.book.closed" : "magnifyingglass",
                    description: Text(language.isEmpty ? "Known words are kept by language." :
                        query.isEmpty ? "Mark words you understand, or learn them by reviewing vocabulary cards." : "")
                )
            }
            ForEach(visible) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.term.expression)
                        if let sense = row.term.sense, !sense.isEmpty {
                            Text(sense).foregroundStyle(.secondary)
                        }
                        Text(row.judgment == .known ? "Marked by you" : "From reviews")
                            .font(.caption).foregroundStyle(.secondary)
                        if row.clozeMature {
                            Label("Cloze recall", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button("Remove from Known") {
                            Task { await change(.unfamiliar, term: row.term, previous: row.judgment ?? .reviewHistory) }
                        }
                        if row.judgment == .known {
                            Button("Use Review History") {
                                Task { await change(.reviewHistory, term: row.term, previous: .known) }
                            }
                        }
                    } label: {
                        Label("Actions for \(row.term.expression)", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("Known Words")
        .searchable(text: $query, prompt: "Find a known word")
        .toolbar {
            Button("Add Word", systemImage: "plus") { isAdding = true }
                .accessibilityIdentifier("known-words-add")
        }
        .sheet(isPresented: $isAdding, onDismiss: { Task { await refresh() } }) {
            VocabularyComposerView(vocabulary: vocabulary, decks: decks, language: language) {
                await onCreated()
            }
        }
        .refreshable { await refresh() }
        .task {
            await refresh()
            if let source = vocabulary as? any LibraryChangePersisting {
                for await _ in await source.changeNotifications() {
                    guard !Task.isCancelled else { break }
                    await refresh()
                }
            }
        }
        .task {
            for await _ in await vocabulary.vocabularyNotifications() {
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }

    private func refresh() async {
        do {
            rows = try await vocabulary.vocabularyStatuses(language: nil)
            if language.isEmpty, let first = Set(rows.map(\.term.language)).sorted().first { language = first }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func change(_ judgment: VocabularyJudgment, term: VocabularyTerm, previous: VocabularyJudgment?) async {
        do {
            _ = try await vocabulary.setVocabularyJudgment(judgment, for: term, changeID: UUID())
            undo = previous.map { (term, $0) }
            await refresh()
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
                _ = try await vocabulary.setVocabularyJudgment(.known, for: term, changeID: saveID)
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
                        _ = try await vocabulary.setVocabularyJudgment(prior, for: currentTerm, changeID: UUID())
                        self.prior = nil
                        await refresh()
                    } catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderless)
        }
        Button("Create Card Set…") { isComposing = true }.buttonStyle(.borderless)
    }

    private func refresh() async {
        let key = currentTerm
        guard !key.language.isEmpty else { isKnown = false; return }
        do {
            let status = try await vocabulary.vocabularyStatuses(language: key.language).first { $0.term.id == key.id }
            guard !Task.isCancelled, key == currentTerm else { return }
            isKnown = status?.isKnown == true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func mark() async {
        let key = currentTerm
        busy = true
        defer { busy = false }
        do {
            let previous = try await vocabulary.vocabularyStatuses(language: key.language).first { $0.term.id == key.id }
            _ = try await vocabulary.setVocabularyJudgment(.known, for: key, changeID: UUID())
            guard key == currentTerm else { return }
            prior = previous?.judgment ?? .reviewHistory
            learningLanguage = key.language
            isKnown = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
