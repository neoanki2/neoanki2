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
        AnyDeckBuilderFeature(descriptor: descriptor) { onGenerated, onCancel in
            PoemDeckBuilderView(
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

    private let workspaceProvider: any DeckBuildWorkspaceProviding
    private let limits: AuthoredDeckLimits
    private let onGenerated: @MainActor (GeneratedDeckBundle) -> Void
    private let onCancel: @MainActor () -> Void

    public init(
        workspaceProvider: any DeckBuildWorkspaceProviding = SystemDeckBuildWorkspaceProvider(),
        limits: AuthoredDeckLimits = .default,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.workspaceProvider = workspaceProvider
        self.limits = limits
        self.onGenerated = onGenerated
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Author", text: $input.author)
                        .accessibilityIdentifier("poemBuilderAuthor")
                    TextField("Title", text: $input.title)
                        .accessibilityIdentifier("poemBuilderTitle")
                    TextEditor(text: $input.text)
                        .font(.body)
                        .frame(minHeight: 220)
                        .accessibilityLabel("Poem text")
                        .accessibilityIdentifier("poemBuilderText")
                    Text(lineSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Poem")
                } footer: {
                    Text("Each line becomes an answer. The preceding one or two lines become its prompt.")
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

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add to Library") {
                    generate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isGenerating)
                .accessibilityIdentifier("poemBuilderAdd")
            }
            .padding()
        }
        .navigationTitle(PoemDeckBuilderFeature.descriptor.title)
        .interactiveDismissDisabled(isGenerating)
    }

    private var lineSummary: String {
        let count = PoemDeckGenerator.usableLines(in: input.text).count
        let cards = max(0, count - 1)
        return "\(count) lines · \(cards) cards"
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
