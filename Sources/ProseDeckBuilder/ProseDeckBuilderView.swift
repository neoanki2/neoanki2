import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import NeoAnkiTextEditing
import SwiftUI

public enum ProseDeckBuilderFeature {
    public static let descriptor = DeckBuilderDescriptor(
        id: "prose",
        title: "Prose Deck",
        subtitle: "Recall a long passage one continuation at a time.",
        systemImage: "text.book.closed"
    )

    @MainActor
    public static func makeFeature(
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default
    ) -> AnyDeckBuilderFeature {
        AnyDeckBuilderFeature(descriptor: descriptor) { context, onGenerated, onCancel in
            ProseDeckBuilderView(
                rootDecks: context.rootDecks,
                workspaceProvider: workspaceProvider,
                limits: limits,
                onGenerated: onGenerated,
                onCancel: onCancel
            )
        }
    }
}

public struct ProseDeckBuilderView: View {
    private enum Field: Hashable { case destination, author, title }
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var errorFocused: Bool
    @State private var input = ProseDeckInput()
    @State private var units: [ProseUnit] = []
    @State private var previewedUnits: [ProseUnit] = []
    @State private var textSession = PlainTextEditorSession()
    @State private var dismissal = DraftDismissal()
    @State private var isPreviewing = false
    @State private var isGenerating = false
    @State private var errorMessage: String?

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
            if isPreviewing {
                ProseUnitReviewView(units: $units)
                    .accessibilityIdentifier("proseBuilderPreview")
            } else {
                Form {
                    Section {
                        Picker("Root Deck", selection: $input.destinationDeckID) {
                            Text("Choose a deck").tag(UUID?.none)
                            ForEach(rootDecks) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                        .focused($focusedField, equals: .destination)
                    .accessibilityIdentifier("proseBuilderRootDeck")
                        VStack(alignment: .leading, spacing: 8) {
                        Text("Title").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Title", text: $input.title)
                        .focused($focusedField, equals: .title)
                            .accessibilityIdentifier("proseBuilderTitle")
                    }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Author (optional)").font(.subheadline).foregroundStyle(.secondary)
                            TextField("Author", text: $input.author)
                        .focused($focusedField, equals: .author)
                                .accessibilityIdentifier("proseBuilderAuthor")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                        Text("Passage").font(.subheadline).foregroundStyle(.secondary)
                        PlainTextEditor(text: $input.text, session: textSession, label: "Prose text", identifier: "proseBuilderText")
                            .font(.body)
                            .frame(minHeight: 260)
                            .accessibilityLabel("Prose text")
                            .accessibilityIdentifier("proseBuilderText")
                    }
                    } header: {
                        Text("Passage")
                    } footer: {
                        Text(
                            rootDecks.isEmpty
                                ? "Create a root deck before building a prose deck."
                                : "Blank lines mark paragraphs. The new deck inherits its parent’s daily card limit."
                        )
                    }
                }
                .formStyle(.grouped)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding()
                    .accessibilityFocused($errorFocused)
                            .accessibilityIdentifier("proseBuilderError")
            }
            #if os(macOS)
            Divider()
            HStack {
                Button("Cancel", role: .cancel, action: requestCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isPreviewing {
                    Button("Edit Text") {
                        input.text = ProseText.sourceAfterReview(originalSource: input.text, originalUnits: previewedUnits, reviewedUnits: units)
                        isPreviewing = false
                        errorMessage = nil
                    }
                    Button("Add to Library", action: generate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isGenerating)
                        .accessibilityIdentifier("proseBuilderAdd")
                } else {
                    Button("Review Cards", action: preview)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("proseBuilderReview")
                }
            }
            .padding()
            #endif
        }
        #if os(iOS)
        .navigationTitle(isPreviewing ? "Preview" : "Prose Deck")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isPreviewing {
                    Button("Import", action: generate).disabled(isGenerating).accessibilityIdentifier("proseBuilderAdd")
                } else {
                    Button("Preview", action: preview).accessibilityIdentifier("proseBuilderReview")
                }
            }
            if isPreviewing { ToolbarItem(placement: .topBarLeading) { Button("Edit Text") { input.text = ProseText.sourceAfterReview(originalSource: input.text, originalUnits: previewedUnits, reviewedUnits: units); isPreviewing = false; errorMessage = nil } } }
        }
        #else
        .navigationTitle(isPreviewing ? "Review Prose Cards" : "Prose Deck")
        #endif
        .protectDraft(isDirty: hasDraft, isBusy: isGenerating, dismissal: dismissal)
        .onChange(of: input) { _, _ in errorMessage = nil }
    }

    private var hasDraft: Bool {
        !input.title.isEmpty || !input.author.isEmpty || !input.text.isEmpty
    }

    private func requestCancel() {
        dismissal.request(isDirty: hasDraft, isBusy: isGenerating, action: onCancel)
    }

    private func preview() {
        guard input.destinationDeckID != nil else {
            errorMessage = ProseDeckBuilderError.missingDestinationDeck.localizedDescription
            focusedField = .destination
            errorFocused = true
            return
        }
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = ProseDeckBuilderError.missingTitle.localizedDescription
            focusedField = .title
            errorFocused = true
            return
        }
        errorMessage = nil
        units = ProseText.parse(input.text, preserving: units)
        guard !units.isEmpty else {
            errorMessage = ProseDeckBuilderError.emptyText.localizedDescription
            textSession.focus()
            errorFocused = true
            return
        }
        previewedUnits = units
        isPreviewing = true
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let generated = try ProseDeckGenerator.generate(
                input: input,
                reviewedUnits: units,
                workspaceProvider: workspaceProvider,
                limits: limits
            )
            onGenerated(generated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
