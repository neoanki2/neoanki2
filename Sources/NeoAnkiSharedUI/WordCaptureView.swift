import Accessibility
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiVocabularyKit
import SwiftUI
import UniformTypeIdentifiers

// THESIS: One word, a visible answer, and one Add action; setup belongs to the pair.
// OWN-WORLD: Semantic native surfaces, system type, restrained primary tint.
// STORY: Look up, resolve only relevant ambiguity, add, and continue typing.
// FIRST VIEWPORT: Stable pair controls and input above scrollable content; fixed Add footer.
// FORM: A focused capture sheet using the approved native interaction, shared across Apple shells.
public struct WordCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
#if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif
    @State private var model: WordCaptureModel
    @State private var showsSetup = false
    @State private var showsImporter = false
    @State private var confirmsDiscard = false
    @State private var pendingChange: (() -> Void)?
    @State private var highlightedIndex = 0
    private enum CaptureFocus: Hashable { case query, field(UUID) }
    @FocusState private var focus: CaptureFocus?
    private let initialDeckID: UUID?

    public init(library: any LibraryRepository, rootURL: URL, deckID: UUID? = nil,
                onSaved: @escaping @MainActor () async -> Void = {}) {
        _model = State(initialValue: WordCaptureModel(library: library, rootURL: rootURL, onSaved: onSaved))
        initialDeckID = deckID
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !scrollsHeader { header }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        if scrollsHeader { header; Divider() }
                        VStack(alignment: .leading, spacing: 16) { captureContent }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("word-capture-content")
                .clipped()
                footer
            }
            .navigationTitle("Add Word")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { setupButton }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { requestClose() }
                        .disabled(model.isSaving)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("word-capture-done")
                }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide Keyboard") { focus = nil }
                }
#endif
            }
            .task {
                await model.start(deckID: initialDeckID)
                focus = .query
            }
            .task(id: model.requestKey) {
                highlightedIndex = 0
                await model.search()
            }
            .onChange(of: model.focusGeneration) { _, _ in focus = .query }
            .onChange(of: model.successMessage) { _, message in
                if let message { AccessibilityNotification.Announcement(message).post() }
            }
            .onChange(of: model.errorMessage) { _, message in
                if let message { AccessibilityNotification.Announcement(message).post() }
            }
            .sheet(isPresented: $showsSetup) {
                WordCaptureSetupView(model: model)
                    .dynamicTypeSize(dynamicTypeSize)
#if os(iOS)
                    .tint(SharedDesignSystem.mobileTint(for: colorScheme))
#endif
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(url): Task { await model.importDictionary(from: url) }
                case let .failure(error): model.errorMessage = error.localizedDescription
                }
            }
            .interactiveDismissDisabled(model.hasDraft || model.isSaving)
            .confirmationDialog("Discard this word’s changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) {
                    if let change = pendingChange { pendingChange = nil; change() } else { dismiss() }
                }
                Button("Keep Editing", role: .cancel) { pendingChange = nil }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 400, idealHeight: 560)
#else
        .tint(SharedDesignSystem.mobileTint(for: colorScheme))
#endif
    }

    // Large text and short landscape screens need a scrollable header so content
    // remains reachable. Normal capture keeps the query and pair controls fixed.
    private var scrollsHeader: Bool {
#if os(iOS)
        dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact
#else
        dynamicTypeSize.isAccessibilitySize
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { deckPicker; Spacer(minLength: 12); dictionaryPicker }
                VStack(alignment: .leading, spacing: 8) { deckPicker; dictionaryPicker }
            }
            queryField
                .frame(minHeight: 44)
                .disabled(model.isLoading || model.isSaving)
                .accessibilityLabel("Word or phrase")
                .accessibilityIdentifier("word-capture-query")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .disabled(model.isImporting)
    }

    private var setupButton: some View {
        Button {
            focus = nil
            showsSetup = true
        } label: {
            Text(model.configuration == nil ? "Set Up" : "Card Setup")
                .lineLimit(1)
        }
        .disabled(model.deckID == nil || model.selectedPack == nil || model.isLoading || model.isSaving)
        .accessibilityLabel(model.configuration == nil ? "Set up this dictionary–deck pair" : "Edit card setup")
        .accessibilityValue(model.itemType?.name ?? "Not configured")
        .accessibilityIdentifier("word-capture-setup")
    }

    @ViewBuilder private var queryField: some View {
#if os(macOS)
        TextField("Type or paste a word", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($focus, equals: .query)
            .onSubmit { chooseHighlightedEntry() }
            .onMoveCommand { direction in
                guard !model.results.isEmpty, model.selectedEntry == nil else { return }
                if direction == .down { highlightedIndex = min(highlightedIndex + 1, model.results.count - 1) }
                else if direction == .up { highlightedIndex = max(0, highlightedIndex - 1) }
            }
#else
        TextField("Type or paste a word", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .query)
            .submitLabel(.search)
            .onSubmit { chooseHighlightedEntry() }
#endif
    }

    private var deckPicker: some View {
        Picker("Deck", selection: Binding(get: { model.deckID }, set: { id in
            guard id != model.deckID else { return }
            requestChange { model.selectDeck(id) }
        })) {
            Text("Choose Deck").tag(UUID?.none)
            ForEach(model.decks) { deck in Text(deck.name).tag(Optional(deck.id)) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minHeight: 44)
        .disabled(model.isSaving)
        .accessibilityValue(model.destinationName)
        .accessibilityIdentifier("word-capture-deck")
    }

    private var dictionaryPicker: some View {
        Menu {
            ForEach(model.packs) { pack in
                Button {
                    guard pack.id != model.dictionaryID else { return }
                    requestChange { model.selectDictionary(pack.id) }
                } label: {
                    if pack.id == model.dictionaryID { Label(pack.title, systemImage: "checkmark") }
                    else { Text(pack.title) }
                }
            }
            Divider()
            Button("Import Dictionary…") { showsImporter = true }
        } label: {
            Label(model.selectedPack?.title ?? (model.dictionaryID == nil ? "Choose Dictionary" : "Unavailable dictionary"),
                  systemImage: "character.book.closed")
                .lineLimit(1)
                .frame(minHeight: 44)
        }
        .disabled(model.isSaving)
        .accessibilityLabel("Dictionary")
        .accessibilityValue(model.selectedPack?.title ?? "Not installed")
        .accessibilityIdentifier("word-capture-dictionary")
    }

    @ViewBuilder private var captureContent: some View {
        if model.isLoading { ProgressView("Loading dictionaries…") }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                .accessibilityIdentifier("word-capture-error")
        }
        if let success = model.successMessage {
            Label(success, systemImage: "checkmark.circle")
                .accessibilityIdentifier("word-capture-success")
                .accessibilityAddTraits(.updatesFrequently)
        }
        if model.selectedPack == nil, !model.isLoading {
            Text(model.dictionaryID == nil ? "Choose or import a dictionary to look up words offline." : "This dictionary is not installed. Choose another or import it again; its saved setup is kept.")
                .foregroundStyle(.secondary)
            Button("Import Dictionary…") { showsImporter = true }
                .accessibilityIdentifier("word-capture-import")
        }
        if model.deckID == nil, !model.isLoading { Text("Choose a destination deck above.").foregroundStyle(.secondary) }
        if let issue = model.configurationIssue {
            Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            Button("Repair Card Setup") { focus = nil; showsSetup = true }
        }
        if model.lookup.isSearching { ProgressView("Looking up…") }
        if let error = model.lookup.errorMessage {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            Button("Try Again") { Task { await model.search() } }
        }
        if model.selectedEntry == nil, !model.manualEntry, !model.results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a match").font(.headline)
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                    Button { model.selectEntry(entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.canonicalForm.text.value)
                            if let definition = entry.senses.first?.definitions.first?.text.value {
                                Text(definition).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(highlightedIndex == index ? Color.accentColor.opacity(0.12) : Color.clear)
                    .accessibilityIdentifier("word-capture-entry-\(entry.id)")
                }
            }
        }
        if !model.query.isEmpty, !model.lookup.isSearching, model.selectedEntry == nil, !model.manualEntry {
            Button("Enter Manually") {
                model.enterManually()
                if let field = model.requiredFields.first(where: {
                    [.text, .richText, .number].contains($0.type)
                        && model.text[$0.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) { focus = .field(field.id) }
            }
                .frame(minHeight: 44)
                .accessibilityIdentifier("word-capture-manual")
        }
        if model.lookup.hasSearched, model.results.isEmpty, !model.manualEntry {
            Text("No matching entries. Try another word or enter your own content.")
                .foregroundStyle(.secondary).accessibilityIdentifier("word-capture-no-match")
        }
        if model.configuration == nil, model.selectedPack != nil, model.deckID != nil {
            Text("Set up this dictionary–deck pair once. The app will remember which content belongs in each field.")
                .foregroundStyle(.secondary)
            Button("Set Up This Pair") { focus = nil; showsSetup = true }
        }
        if model.configurationIssue == nil, model.selectedEntry != nil || model.manualEntry {
            ForEach(model.requiredFields) { field in fieldEditor(field) }
            if !model.optionalFields.isEmpty {
                DisclosureGroup("More details") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.optionalFields) { field in fieldEditor(field) }
                    }.padding(.top, 8)
                }
            }
        }
    }

    private func fieldEditor(_ field: FieldDef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.name).font(.subheadline.weight(.medium))
                if field.isRequired { Text("Required").font(.caption).foregroundStyle(.secondary) }
            }
            if let binding = model.binding(for: field.id), binding.source != .manual,
               model.choices(for: binding).count > 1 {
                Menu(model.selectedChoice(for: binding).map { "Change \($0.detail ?? binding.source.title)" } ?? "Choose \(binding.source.title.lowercased())") {
                    ForEach(model.choices(for: binding)) { choice in
                        Button([choice.text, choice.detail].compactMap { $0 }.joined(separator: " · ")) {
                            model.choose(choice, for: field.id)
                        }
                    }
                }
                .accessibilityIdentifier("word-capture-choice-\(field.id)")
            }
            if [.text, .richText, .number].contains(field.type) {
                TextField("Enter \(field.name.lowercased())", text: Binding(
                    get: { model.text[field.id, default: ""] },
                    set: { model.setText($0, fieldID: field.id) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($focus, equals: .field(field.id))
                    .accessibilityLabel(field.name)
                    .accessibilityHint(field.isRequired ? "Required" : "Optional")
                    .accessibilityIdentifier("word-capture-field-\(field.name)")
            } else if field.type == .audio {
                if let binding = model.binding(for: field.id), let choice = model.selectedChoice(for: binding), choice.audio != nil {
                    Label(choice.text, systemImage: "waveform").accessibilityLabel("Audio ready: \(choice.text)")
                } else { Text("No audio selected.").foregroundStyle(.secondary) }
            } else { Text("Use the full item editor to fill this field.").foregroundStyle(.secondary) }
            if let issue = model.fieldIssue(field) {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
#if os(macOS)
                Spacer()
#endif
                if model.isSaving || model.isImporting { ProgressView().accessibilityLabel(model.isSaving ? "Adding word" : "Importing dictionary") }
                Button { focus = nil; Task { await model.save() } } label: {
                    Text(model.deckID == nil ? "Add Word" : "Add to \(model.destinationName)")
#if os(macOS)
                        .lineLimit(1)
#else
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
#endif
                }
#if os(macOS)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
#else
                .buttonStyle(CaptureActionButtonStyle())
#endif
                .disabled(!model.canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("word-capture-add")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func chooseHighlightedEntry() {
        guard model.selectedEntry == nil, model.results.indices.contains(highlightedIndex) else { return }
        model.selectEntry(model.results[highlightedIndex])
    }
    private func requestChange(_ action: @escaping () -> Void) {
        guard model.hasManualEdits else { action(); return }
        pendingChange = action; confirmsDiscard = true
    }
    private func requestClose() {
        if model.hasDraft { pendingChange = nil; confirmsDiscard = true } else { dismiss() }
    }
}

private struct WordCaptureSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WordCaptureModel
    @State private var typeID: UUID?
    @State private var bindings: [VocabularyFieldBinding] = []
    @State private var errorMessage: String?
    @State private var didInitialize = false
    private var type: ItemType? { model.itemTypes.first { $0.id == typeID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(model.selectedPack?.title ?? "Dictionary") → \(model.destinationName)")
                    Text("Choose the content for each field. This setup is remembered for this pair; edits to individual words do not change it.")
                        .foregroundStyle(.secondary)
                }
                Section("Card setup") {
                    Picker("Item type", selection: $typeID) {
                        Text("Choose an item type").tag(UUID?.none)
                        ForEach(model.itemTypes) { type in Text(type.name).tag(Optional(type.id)) }
                    }.accessibilityIdentifier("word-capture-setup-type")
                }
                if let type {
                    ForEach(type.fields) { field in
                        Section(field.name) {
                            Picker("Content", selection: sourceBinding(field)) {
                                ForEach(VocabularyFieldSource.allCases.filter { $0.supports(field.type) }) { source in
                                    Text(source.title).tag(source)
                                }
                            }.accessibilityIdentifier("word-capture-source-\(field.name)")
                            if let binding = bindings.first(where: { $0.fieldID == field.id }) {
                                if [.pronunciationText, .pronunciationAudio, .form].contains(binding.source) {
                                    Picker(binding.source == .form ? "Form kind" : "Pronunciation", selection: variantBinding(field, language: false)) {
                                        Text("Any supplied variant").tag(String?.none)
                                        ForEach(variants(for: binding), id: \.self) { value in Text(value).tag(Optional(value)) }
                                    }.accessibilityIdentifier("word-capture-variant-\(field.name)")
                                }
                                if [.meaning, .example, .form, .pronunciationText].contains(binding.source) {
                                    Picker("Content language", selection: variantBinding(field, language: true)) {
                                        Text("Any supplied language").tag(String?.none)
                                        ForEach(languages(for: binding), id: \.self) { value in Text(Locale.current.localizedString(forIdentifier: value) ?? value).tag(Optional(value)) }
                                    }
                                }
                                if let entry = model.selectedEntry {
                                    let sample = model.choices(for: binding, entry: entry)
                                    if binding.source == .manual { Text("You enter this field yourself.").foregroundStyle(.secondary) }
                                    else if sample.isEmpty { Text("Not supplied for this word; enter it manually.").foregroundStyle(.secondary) }
                                    else {
                                        Text(sample.map(\.text).joined(separator: "\n")).textSelection(.enabled)
                                        if sample.count > 1 { Text("You’ll choose the relevant value when adding.").font(.footnote).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                }
                if model.selectedEntry == nil {
                    Text("Look up a word before opening setup to see real examples and the dictionary’s pronunciation variants.").foregroundStyle(.secondary)
                }
                if model.itemTypes.isEmpty { Text("Create an item type in Item Types before setting up this pair.") }
                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Up This Pair")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Setup") { save() }
                        .disabled(type == nil)
                        .accessibilityIdentifier("word-capture-save-setup")
                }
            }
            .onAppear {
                guard !didInitialize else { return }
                didInitialize = true
                typeID = model.configuration?.itemTypeID ?? (model.itemTypes.count == 1 ? model.itemTypes.first?.id : nil)
                resetBindings()
            }
            .onChange(of: typeID) { _, _ in resetBindings() }
        }
#if os(macOS)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 420, idealHeight: 600)
#endif
    }

    private func resetBindings() {
        bindings = type?.fields.enumerated().map { index, field in
            if let existing = model.configuration?.bindings.first(where: { $0.fieldID == field.id && $0.fieldType == field.type }) { return existing }
            let source: VocabularyFieldSource = [.text, .richText].contains(field.type)
                ? (index == 0 ? .typedWord : index == 1 ? .meaning : .manual) : (field.type == .audio ? .pronunciationAudio : .manual)
            return .init(fieldID: field.id, fieldType: field.type, source: source)
        } ?? []
    }
    private func sourceBinding(_ field: FieldDef) -> Binding<VocabularyFieldSource> {
        Binding(get: { bindings.first { $0.fieldID == field.id }?.source ?? .manual }, set: { value in
            guard let index = bindings.firstIndex(where: { $0.fieldID == field.id }) else { return }
            bindings[index].source = value; bindings[index].variant = nil; bindings[index].language = nil
        })
    }
    private func variantBinding(_ field: FieldDef, language: Bool) -> Binding<String?> {
        Binding(get: {
            guard let binding = bindings.first(where: { $0.fieldID == field.id }) else { return nil }
            return language ? binding.language : binding.variant
        }, set: { value in
            guard let index = bindings.firstIndex(where: { $0.fieldID == field.id }) else { return }
            if language { bindings[index].language = value } else { bindings[index].variant = value }
        })
    }
    private func variants(for binding: VocabularyFieldBinding) -> [String] {
        let supplied = binding.source == .form ? model.selectedEntry?.forms.compactMap(\.kind) ?? []
            : model.selectedEntry?.pronunciations.map(\.scheme) ?? []
        return Array(Set(supplied + [binding.variant].compactMap { $0 })).sorted()
    }
    private func languages(for binding: VocabularyFieldBinding) -> [String] {
        let entry = model.selectedEntry
        let supplied = (entry?.senses.flatMap { $0.definitions.compactMap { $0.text.language } + $0.examples.compactMap { $0.text.language } } ?? [])
            + (entry?.forms.compactMap { $0.text.language } ?? [])
            + (entry?.pronunciations.flatMap { $0.representations.compactMap { representation -> String? in
                if case let .text(value) = representation { return value.language }; return nil
            }} ?? [])
        return Array(Set(supplied + [binding.language].compactMap { $0 })).sorted()
    }
    private func save() {
        guard let dictionaryID = model.dictionaryID, let deckID = model.deckID, let typeID else { return }
        let configuration = VocabularyDeckConfiguration(dictionaryID: dictionaryID, deckID: deckID, itemTypeID: typeID, bindings: bindings)
        if model.saveConfiguration(configuration) { dismiss() }
        else { errorMessage = model.errorMessage }
    }
}

#if os(iOS)
/// Keep the disabled action readable too; the native prominent style dims its
/// foreground below contrast requirements in the capture sheet's Dark Mode.
private struct CaptureActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .foregroundStyle(isEnabled ? Color.white : Color.primary)
            .background(isEnabled ? SharedDesignSystem.mobileTint(for: .light) : Color.primary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed && isEnabled ? 0.85 : 1)
    }
}
#endif
