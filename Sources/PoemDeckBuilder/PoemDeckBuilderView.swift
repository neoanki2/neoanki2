import NeoAnkiCore
import NeoAnkiDeckBuilderKit
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
    @State private var input = PoemDeckInput()
    @State private var errorMessage: String?
    @State private var isGenerating = false
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
                } else {
                Section {
                    Picker("Root Deck", selection: $input.destinationDeckID) {
                        Text("Choose a deck").tag(UUID?.none)
                        ForEach(rootDecks) { deck in
                            Text(deck.name).tag(Optional(deck.id))
                        }
                    }
                    .accessibilityIdentifier("poemBuilderRootDeck")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Author").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Author", text: $input.author)
                        .accessibilityIdentifier("poemBuilderAuthor")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Title", text: $input.title)
                        .accessibilityIdentifier("poemBuilderTitle")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Poem text").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $input.text)
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
                            .accessibilityIdentifier("poemBuilderError")
                    }
                }
            }
            .formStyle(.grouped)

            #if os(macOS)
            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
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
        .interactiveDismissDisabled(isGenerating)
    }

    private var lineSummary: String {
        let poem = PoemDeckGenerator.parse(input.text)
        let count = poem.lines.count
        let cards = plannedCards.count
        let stanzaCount = poem.stanzas.count
        return "\(count) lines · \(stanzaCount) \(stanzaCount == 1 ? "stanza" : "stanzas") · \(cards) cards"
    }

    private var plannedCards: [PlannedPoemCard] {
        PoemCardPlanner.cards(for: PoemDeckGenerator.parse(input.text), title: input.title)
    }

    private var openingSummary: String {
        plannedCards.first?.isOpening == true
            ? "Opening-line card included."
            : "Opening-line card omitted: the title already gives the first line."
    }

    private func preview() {
        guard PoemDeckGenerator.parse(input.text).lines.count >= 2 else {
            errorMessage = PoemDeckBuilderError.tooFewLines.localizedDescription
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
