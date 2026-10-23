import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import NeoAnkiTextEditing
import SwiftUI

public enum PoemDeckBuilderFeature {
    public static let descriptor = DeckBuilderDescriptor(
        id: "poem",
        title: "Poem Deck",
        subtitle: "Practice each line from the preceding context.",
        systemImage: "text.quote"
    )

    @MainActor
    public static func makeFeature(
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default
    ) -> AnyDeckBuilderFeature {
        AnyDeckBuilderFeature(descriptor: descriptor) { context, onGenerated, onCancel in
            PoemDeckBuilderView(
                rootDecks: context.rootDecks,
                workspaceProvider: workspaceProvider,
                limits: limits,
                onGenerated: onGenerated,
                onCancel: onCancel
            )
        }
    }
}

public struct PoemDeckBuilderView: View {
    private enum Field: Hashable { case destination, author, title }
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var errorFocused: Bool
    @State private var input = PoemDeckInput()
    @State private var errorMessage: String?
    @State private var parsedPoem = ParsedPoem(stanzas: [])
    @State private var plannedCards: [PlannedPoemCard] = []
    @State private var isGenerating = false
    @State private var textSession = PlainTextEditorSession()
    @State private var dismissal = DraftDismissal()
    @State private var isPreviewing = false

    private let rootDecks: [DeckBuilderDeckOption]
    private let workspaceProvider: any DeckBuildWorkspaceProviding
    private let limits: AuthoredDeckLimits
    private let onGenerated: @MainActor (GeneratedDeckBundle) -> Void
    private let onCancel: @MainActor () -> Void

    public init(
        rootDecks: [DeckBuilderDeckOption],
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.rootDecks = rootDecks
        self.workspaceProvider = workspaceProvider
        self.limits = limits
        self.onGenerated = onGenerated
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                if isPreviewing {
                    Section("Preview") {
                        Text(lineSummary).font(.subheadline).foregroundStyle(.secondary)
                        Text(openingSummary).font(.caption).foregroundStyle(.secondary)
                        LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(plannedCards.enumerated()), id: \.offset) { index, card in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.isOpening ? "Card \(index + 1) · Opening line" : "Card \(index + 1)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(input.title.trimmingCharacters(in: .whitespacesAndNewlines)) · \(input.author.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(card.prompt).foregroundStyle(.secondary)
                                Text(card.answer)
                            }
                        }
                        }
                    }
                } else {
                Section {
                    Picker("Root Deck", selection: $input.destinationDeckID) {
                        Text("Choose a deck").tag(UUID?.none)
                        ForEach(rootDecks) { deck in
                            Text(deck.name).tag(Optional(deck.id))
                        }
                    }
                    .focused($focusedField, equals: .destination)
                    .accessibilityIdentifier("poemBuilderRootDeck")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Author").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Author", text: $input.author)
                        .focused($focusedField, equals: .author)
                        .accessibilityIdentifier("poemBuilderAuthor")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Title", text: $input.title)
                        .focused($focusedField, equals: .title)
                        .accessibilityIdentifier("poemBuilderTitle")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Poem text").font(.subheadline).foregroundStyle(.secondary)
                    PlainTextEditor(text: $input.text, session: textSession, label: "Poem text", identifier: "poemBuilderText")
                        .font(.body)
                        .frame(minHeight: 220)
                        .accessibilityLabel("Poem text")
                        .accessibilityIdentifier("poemBuilderText")
                    }
                    Text(lineSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Poem")
                } footer: {
                    if rootDecks.isEmpty {
                        Text("Create a root deck before building a poem deck.")
                    } else {
                        Text("The poem becomes a child of the selected deck. An opening card is included when the title differs from the first line.")
                    }
                }

                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityFocused($errorFocused)
                            .accessibilityIdentifier("poemBuilderError")
                    }
                }
            }
            .formStyle(.grouped)

            #if os(macOS)
            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    requestCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isPreviewing {
                    Button("Edit Text") { isPreviewing = false }
                    Button("Add to Library", action: generate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isGenerating)
                        .accessibilityIdentifier("poemBuilderAdd")
                } else {
                    Button("Review Cards", action: preview)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("poemBuilderPreview")
                }
            }
            .padding()
            #endif
        }
        .navigationTitle(PoemDeckBuilderFeature.descriptor.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isPreviewing {
                    Button("Import", action: generate).disabled(isGenerating).accessibilityIdentifier("poemBuilderAdd")
                } else {
                    Button("Preview", action: preview).accessibilityIdentifier("poemBuilderPreview")
                }
            }
            if isPreviewing { ToolbarItem(placement: .topBarLeading) { Button("Edit Text") { isPreviewing = false } } }
        }
        #endif
        .protectDraft(isDirty: hasDraft, isBusy: isGenerating, dismissal: dismissal)
        .onChange(of: input) { _, _ in errorMessage = nil }
        .onChange(of: input.text, initial: true) { _, text in
            parsedPoem = PoemDeckGenerator.parse(text)
            refreshPlan()
        }
        .onChange(of: input.title) { _, _ in refreshPlan() }
    }

    private var lineSummary: String {
        let count = parsedPoem.lines.count
        let cards = plannedCards.count
        let stanzaCount = parsedPoem.stanzas.count
        return "\(count) lines · \(stanzaCount) \(stanzaCount == 1 ? "stanza" : "stanzas") · \(cards) cards"
    }

    private func refreshPlan() {
        plannedCards = PoemCardPlanner.cards(for: parsedPoem, title: input.title)
    }

    private var openingSummary: String {
        plannedCards.first?.isOpening == true
            ? "Opening-line card included."
            : "Opening-line card omitted: the title already gives the first line."
    }

    private var hasDraft: Bool {
        !input.title.isEmpty || !input.author.isEmpty || !input.text.isEmpty
    }

    private func requestCancel() {
        dismissal.request(isDirty: hasDraft, isBusy: isGenerating, action: onCancel)
    }

    private func preview() {
        guard input.destinationDeckID != nil else {
            errorMessage = PoemDeckBuilderError.missingDestinationDeck.localizedDescription
            focusedField = .destination
            errorFocused = true
            return
        }
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = PoemDeckBuilderError.missingTitle.localizedDescription
            focusedField = .title
            errorFocused = true
            return
        }
        guard !input.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = PoemDeckBuilderError.missingAuthor.localizedDescription
            focusedField = .author
            errorFocused = true
            return
        }
        guard parsedPoem.lines.count >= 2 else {
            errorMessage = PoemDeckBuilderError.tooFewLines.localizedDescription
            textSession.focus()
            errorFocused = true
            return
        }
        errorMessage = nil
        isPreviewing = true
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let generated = try PoemDeckGenerator.generate(
                input: input,
                workspaceProvider: workspaceProvider,
                limits: limits
            )
            onGenerated(generated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
