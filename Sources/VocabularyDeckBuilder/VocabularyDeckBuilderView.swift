import AppKit
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import NeoAnkiVocabularyKit
import SwiftUI

public struct VocabularyPackOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let packageURL: URL

    public init(id: String, title: String, summary: String, packageURL: URL) {
        self.id = id
        self.title = title
        self.summary = summary
        self.packageURL = packageURL
    }
}

public enum VocabularyDeckBuilderFeature {
    public static let descriptor = DeckBuilderDescriptor(
        id: "vocabulary",
        title: "Vocabulary Deck",
        subtitle: "Build cards from a local offline vocabulary pack.",
        systemImage: "character.book.closed"
    )

    @MainActor
    public static func makeFeature(
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default
    ) -> AnyDeckBuilderFeature {
        AnyDeckBuilderFeature(descriptor: descriptor) { context, onGenerated, onCancel in
            VocabularyDeckBuilderView(
                rootDecks: context.rootDecks,
                workspaceProvider: workspaceProvider,
                limits: limits,
                onGenerated: onGenerated,
                onCancel: onCancel
            )
        }
    }
}

public struct VocabularyDeckBuilderView: View {
    @State private var input = VocabularyDeckInput()
    @State private var pack: VocabularyPack?
    @State private var packURL: URL?
    @State private var hasSecurityScopedAccess = false
    @State private var query = ""
    @State private var searchResults: [LexicalEntry] = []
    @State private var selectedEntryID: String?
    @State private var previewCards: [VocabularyCardPreview] = []
    @State private var errorMessage: String?
    @State private var previewErrorMessage: String?
    @State private var isOpeningPack = false
    @State private var isSearching = false
    @State private var isPreparingEntry = false
    @State private var isGenerating = false
    @State private var selectedPackID: VocabularyPackOption.ID?
    @State private var successMessage: String?
    @FocusState private var searchFocused: Bool

    private let rootDecks: [DeckBuilderDeckOption]
    private let installedPacks: [VocabularyPackOption]?
    private let fixedDestination: DeckBuilderDeckOption?
    private let workspaceProvider: any DeckBuildWorkspaceProviding
    private let limits: AuthoredDeckLimits
    private let importGenerated: @MainActor (GeneratedDeckBundle) async throws -> Int?
    private let onCancel: @MainActor () -> Void

    public init(
        rootDecks: [DeckBuilderDeckOption],
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.rootDecks = rootDecks
        installedPacks = nil
        fixedDestination = nil
        self.workspaceProvider = workspaceProvider
        self.limits = limits
        importGenerated = { generated in
            onGenerated(generated)
            return nil
        }
        self.onCancel = onCancel
    }

    /// Creates the incremental authoring flow: an installed pack is searched
    /// and the generated items are appended to one existing deck.
    public init(
        installedPacks: [VocabularyPackOption],
        destinationDeck: DeckBuilderDeckOption,
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default,
        onImported: @escaping @MainActor (GeneratedDeckBundle) async throws -> Int,
        onCancel: @escaping @MainActor () -> Void
    ) {
        rootDecks = [destinationDeck]
        self.installedPacks = installedPacks
        fixedDestination = destinationDeck
        self.workspaceProvider = workspaceProvider
        self.limits = limits
        importGenerated = { generated in try await onImported(generated) }
        self.onCancel = onCancel
        _input = State(initialValue: VocabularyDeckInput(
            destinationDeckID: destinationDeck.id,
            deckName: destinationDeck.name
        ))
        _selectedPackID = State(initialValue: installedPacks.first?.id)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                packSection

                if let pack {
                    searchSection(pack: pack)
                }

                if selectedEntryID != nil {
                    reviewSection
                    paradigmSection
                    previewSection
                }

                if let attentionMessage = errorMessage ?? previewErrorMessage {
                    Section("Needs Attention") {
                        Label(attentionMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("vocabularyBuilderError")
                    }
                }


                if let successMessage {
                    Section("Added") {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("vocabularyBuilderSuccess")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("vocabularyBuilderCancel")

                Spacer()

                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Generating vocabulary deck")
                }
                Button(fixedDestination == nil ? "Add to Library" : "Add Cards") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGenerate || isGenerating)
                    .accessibilityIdentifier("vocabularyBuilderAdd")
            }
            .padding()
        }
        .navigationTitle(VocabularyDeckBuilderFeature.descriptor.title)
        .accessibilityIdentifier("vocabularyBuilderSheet")
        .interactiveDismissDisabled(isGenerating)
        .onDisappear { releasePackAccess() }
        .onChange(of: input, initial: true) { _, _ in refreshPreview() }
        .task {
            guard pack == nil,
                  let selectedPackID,
                  let option = installedPacks?.first(where: { $0.id == selectedPackID })
            else { return }
            openPack(at: option.packageURL)
        }
        .onChange(of: selectedPackID) { _, packID in
            guard let packID,
                  let option = installedPacks?.first(where: { $0.id == packID })
            else { return }
            openPack(at: option.packageURL)
        }
    }

    private var packSection: some View {
        Section {
            if let installedPacks {
                Picker("Vocabulary Pack", selection: $selectedPackID) {
                    ForEach(installedPacks) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                }
                .disabled(isOpeningPack || isGenerating)
                .accessibilityIdentifier("vocabularyBuilderPackPicker")

                if isOpeningPack {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Opening the installed pack…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if let option = installedPacks.first(where: { $0.id == selectedPackID }) {
                    Text(option.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pack?.manifest.title ?? "No pack selected")
                        if let manifest = pack?.manifest {
                            Text(packSummary(manifest))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose a downloaded .neovocab directory. Only local files are read.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isOpeningPack {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Opening vocabulary pack")
                    }
                    Button(pack == nil ? "Choose Pack…" : "Change Pack…") {
                        choosePack()
                    }
                    .disabled(isOpeningPack || isGenerating)
                    .accessibilityIdentifier("vocabularyBuilderChoosePack")
                }
            }
        } header: {
            Text("Offline Pack")
        } footer: {
            Text("NeoAnki does not download entries, examples, pronunciations, or media.")
        }
    }

    private func searchSection(pack: VocabularyPack) -> some View {
        Section {
            HStack {
                TextField("Search form", text: $query)
                    .focused($searchFocused)
                    .onSubmit { search(pack: pack) }
                    .accessibilityIdentifier("vocabularyBuilderSearchField")
                Button("Search") { search(pack: pack) }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    .accessibilityIdentifier("vocabularyBuilderSearch")
            }

            if isSearching {
                HStack {
                    ProgressView()
                    Text("Searching the local index…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if !query.isEmpty, searchResults.isEmpty {
                Text("No matching entries in this pack.")
                    .foregroundStyle(.secondary)
            }

            ForEach(searchResults, id: \.id) { entry in
                Button {
                    prepare(entry: entry, pack: pack)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.canonicalForm.text.value)
                            Text(entrySummary(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if isPreparingEntry, selectedEntryID == entry.id {
                            ProgressView()
                                .controlSize(.small)
                        } else if selectedEntryID == entry.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPreparingEntry)
                .accessibilityLabel("Select \(entry.canonicalForm.text.value). \(entrySummary(entry))")
                .accessibilityIdentifier("vocabularyBuilderEntry-\(entry.id)")
            }
        } header: {
            Text("Find Entry")
        } footer: {
            Text("Search runs against the pack’s local read-only index.")
        }
    }

    private var reviewSection: some View {
        Section {
            if let fixedDestination {
                LabeledContent("Deck", value: fixedDestination.name)
                    .accessibilityIdentifier("vocabularyBuilderDestinationDeck")
            } else {
                Picker("Root Deck", selection: $input.destinationDeckID) {
                    Text("Choose a deck").tag(UUID?.none)
                    ForEach(rootDecks) { deck in
                        Text(deck.name).tag(Optional(deck.id))
                    }
                }
                .accessibilityIdentifier("vocabularyBuilderRootDeck")

                TextField("Generated deck name", text: $input.deckName)
                    .accessibilityIdentifier("vocabularyBuilderDeckName")
            }
            TextField("Canonical form", text: $input.form)
                .accessibilityIdentifier("vocabularyBuilderForm")

            if !input.pronunciations.isEmpty {
                DisclosureGroup("Pronunciations (\(selectedPronunciationCount) selected)") {
                    ForEach($input.pronunciations) { $pronunciation in
                        Toggle(isOn: $pronunciation.isSelected) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pronunciation.displayLabel)
                                switch pronunciation.content {
                                case let .text(value):
                                    Text(value)
                                        .font(.body)
                                case let .audio(url):
                                    Label(url.lastPathComponent, systemImage: "waveform")
                                        .font(.caption)
                                }
                                Text(pronunciation.scheme)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let availabilityError = pronunciation.availabilityError {
                                    Label(availabilityError, systemImage: "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else if !pronunciation.senseIDs.isEmpty {
                                    Text("Applies to: \(pronunciation.senseIDs.sorted().joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(pronunciation.availabilityError != nil)
                        .accessibilityHint("Include this representation in generated cards")
                    }
                }
            }

            DisclosureGroup("Meanings and examples (\(selectedSenseCount) selected)") {
                ForEach(input.senses.indices, id: \.self) { senseIndex in
                    senseEditor(index: senseIndex)
                }
            }
        } header: {
            Text("Review Entry")
        } footer: {
            if rootDecks.isEmpty {
                Text("Create a root deck before generating vocabulary cards.")
            } else {
                Text("Every selected meaning and example is stored as an independent schedulable item.")
            }
        }
    }

    private func senseEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Meaning \(index + 1)", isOn: $input.senses[index].isSelected)

            if input.senses[index].isSelected {
                Text("Definition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $input.senses[index].definition)
                    .frame(minHeight: 58)
                    .accessibilityLabel("Definition for meaning \(index + 1)")

                ForEach(input.senses[index].examples.indices, id: \.self) { exampleIndex in
                    exampleEditor(senseIndex: index, exampleIndex: exampleIndex)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func exampleEditor(senseIndex: Int, exampleIndex: Int) -> some View {
        let example = input.senses[senseIndex].examples[exampleIndex]
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Example \(exampleIndex + 1)",
                isOn: $input.senses[senseIndex].examples[exampleIndex].isSelected
            )
            if example.isSelected {
                TextField(
                    "Example sentence",
                    text: $input.senses[senseIndex].examples[exampleIndex].text,
                    axis: .vertical
                )
                .lineLimit(2 ... 5)
                .onChange(of: input.senses[senseIndex].examples[exampleIndex].text) { _, _ in
                    relocateTarget(senseIndex: senseIndex, exampleIndex: exampleIndex)
                }

                TextField(
                    "Cloze target",
                    text: $input.senses[senseIndex].examples[exampleIndex].targetText
                )
                .onChange(of: input.senses[senseIndex].examples[exampleIndex].targetText) { _, _ in
                    relocateTarget(senseIndex: senseIndex, exampleIndex: exampleIndex)
                }

                if let validation = exampleValidation(example) {
                    Label(validation, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Example error: \(validation)")
                } else {
                    Text("The cloze hides the selected surface form; the canonical form remains answer context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 16)
    }

    private var paradigmSection: some View {
        Section {
            ForEach(VocabularyCardParadigm.allCases) { paradigm in
                Toggle(paradigm.title, isOn: paradigmBinding(paradigm))
            }
        } header: {
            Text("Card Paradigms")
        } footer: {
            Text("Only paradigms with selected source content produce cards.")
        }
    }

    private var previewSection: some View {
        Section {
            if previewCards.isEmpty {
                Text("Select usable content and at least one matching paradigm to preview cards.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(previewCards.prefix(8)) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.paradigm.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(card.prompt)
                            .lineLimit(2)
                        Text(card.answer)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
                if previewCards.count > 8 {
                    Text("And \(previewCards.count - 8) more cards")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Preview · \(previewCards.count) Cards")
        }
    }

    private var canGenerate: Bool {
        input.destinationDeckID != nil && !previewCards.isEmpty && previewErrorMessage == nil
    }

    private var selectedPronunciationCount: Int {
        input.pronunciations.filter(\.isSelected).count
    }

    private var selectedSenseCount: Int {
        input.senses.filter(\.isSelected).count
    }

    private func packSummary(_ manifest: VocabularyPackManifest) -> String {
        let languages = manifest.languages.joined(separator: ", ")
        let count = manifest.entryCount.formatted()
        return "\(languages) · \(count) entries · \(manifest.capabilities.count) capabilities"
    }

    private func entrySummary(_ entry: LexicalEntry) -> String {
        if let definition = entry.senses.lazy.flatMap(\.definitions).first?.text.value {
            return definition
        }
        let parts = [
            entry.pronunciations.isEmpty ? nil : "\(entry.pronunciations.count) pronunciations",
            entry.senses.isEmpty ? nil : "\(entry.senses.count) meanings",
        ].compactMap { $0 }
        return parts.isEmpty ? "No meaning supplied" : parts.joined(separator: " · ")
    }

    private func paradigmBinding(_ paradigm: VocabularyCardParadigm) -> Binding<Bool> {
        Binding(
            get: { input.paradigms.contains(paradigm) },
            set: { enabled in
                if enabled { input.paradigms.insert(paradigm) }
                else { input.paradigms.remove(paradigm) }
            }
        )
    }

    private func choosePack() {
        let panel = NSOpenPanel()
        panel.title = "Choose Offline Vocabulary Pack"
        panel.prompt = "Choose Pack"
        panel.message = "Select a local .neovocab directory."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "neovocab" else {
            errorMessage = "Choose a directory whose name ends in .neovocab."
            return
        }
        openPack(at: url)
    }

    private func openPack(at url: URL) {
        guard !isOpeningPack else { return }
        isOpeningPack = true
        errorMessage = nil
        successMessage = nil
        Task {
            do {
                releasePackAccess()
                pack = nil
                let access = url.startAccessingSecurityScopedResource()
                do {
                    let opened = try await VocabularyPack.open(at: url)
                    packURL = url
                    hasSecurityScopedAccess = access
                    pack = opened
                } catch {
                    if access { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                query = ""
                searchResults = []
                selectedEntryID = nil
                input = VocabularyDeckInput(
                    destinationDeckID: input.destinationDeckID,
                    deckName: input.deckName,
                    paradigms: input.paradigms
                )
                searchFocused = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isOpeningPack = false
        }
    }

    private func search(pack: VocabularyPack) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        successMessage = nil
        Task {
            do {
                searchResults = try await pack.search(query: query, mode: .prefix, limit: 50)
            } catch {
                searchResults = []
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func prepare(entry: LexicalEntry, pack: VocabularyPack) {
        guard !isPreparingEntry else { return }
        selectedEntryID = entry.id
        isPreparingEntry = true
        errorMessage = nil
        let destinationDeckID = input.destinationDeckID
        let deckName = input.deckName
        let paradigms = input.paradigms
        Task {
            do {
                var prepared = try await LexicalEntryDraftFactory.makeInput(
                    entry: entry,
                    pack: pack,
                    destinationDeckID: destinationDeckID,
                    deckName: deckName
                )
                prepared.paradigms = paradigms
                input = prepared
            } catch {
                selectedEntryID = nil
                errorMessage = error.localizedDescription
            }
            isPreparingEntry = false
        }
    }

    private func relocateTarget(senseIndex: Int, exampleIndex: Int) {
        let text = input.senses[senseIndex].examples[exampleIndex].text
        let target = input.senses[senseIndex].examples[exampleIndex].targetText
        let matches = targetRanges(of: target, in: text)
        guard matches.count == 1, let range = matches.first else {
            input.senses[senseIndex].examples[exampleIndex].targetStart = 0
            input.senses[senseIndex].examples[exampleIndex].targetLength = 0
            return
        }
        input.senses[senseIndex].examples[exampleIndex].targetStart = text[..<range.lowerBound].count
        input.senses[senseIndex].examples[exampleIndex].targetLength = text[range].count
    }

    private func exampleValidation(_ example: VocabularyExampleSelection) -> String? {
        let occurrences = targetRanges(of: example.targetText, in: example.text).count
        if occurrences > 1 {
            return "The cloze target occurs more than once. Edit the target or sentence so one occurrence remains."
        }
        do {
            _ = try VocabularyDeckGenerator.clozeMarkup(for: example)
            return nil
        } catch {
            return "The cloze target must occur as a complete character sequence in the sentence."
        }
    }

    private func targetRanges(of target: String, in text: String) -> [Range<String.Index>] {
        guard !target.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: target, range: start ..< text.endIndex) {
            ranges.append(range)
            start = text.index(after: range.lowerBound)
        }
        return ranges
    }

    private func refreshPreview() {
        guard selectedEntryID != nil else {
            previewCards = []
            previewErrorMessage = nil
            return
        }
        do {
            previewCards = try VocabularyDeckGenerator.preview(input: input)
            previewErrorMessage = nil
        } catch VocabularyDeckBuilderError.noCards {
            previewCards = []
            previewErrorMessage = nil
        } catch {
            previewCards = []
            previewErrorMessage = error.localizedDescription
        }
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        let input = input
        let workspaceProvider = workspaceProvider
        let limits = limits
        Task {
            do {
                let generated = try await Task.detached {
                    try VocabularyDeckGenerator.generate(
                        input: input,
                        workspaceProvider: workspaceProvider,
                        limits: limits
                    )
                }.value
                if let importedCount = try await importGenerated(generated) {
                    resetAfterImport(importedCount)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func resetAfterImport(_ importedCount: Int) {
        let paradigms = input.paradigms
        let destinationDeckID = input.destinationDeckID
        let deckName = input.deckName
        input = VocabularyDeckInput(
            destinationDeckID: destinationDeckID,
            deckName: deckName,
            paradigms: paradigms
        )
        query = ""
        searchResults = []
        selectedEntryID = nil
        previewCards = []
        previewErrorMessage = nil
        errorMessage = nil
        let noun = importedCount == 1 ? "item" : "items"
        successMessage = "\(importedCount) \(noun) added to \(fixedDestination?.name ?? deckName)."
        searchFocused = true
    }

    private func releasePackAccess() {
        if hasSecurityScopedAccess {
            packURL?.stopAccessingSecurityScopedResource()
        }
        hasSecurityScopedAccess = false
        packURL = nil
    }
}
