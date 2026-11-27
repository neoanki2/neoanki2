import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

private struct OpenVocabularySetKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID?) -> Void = { _ in }
}

public extension EnvironmentValues {
    var openVocabularySet: @MainActor (UUID?) -> Void {
        get { self[OpenVocabularySetKey.self] }
        set { self[OpenVocabularySetKey.self] = newValue }
    }
}

/// Uses the editor's live field content without changing or saving that item.
public struct VocabularyAuthoringEntry: View {
    @Environment(\.vocabularyPackRootURL) private var rootURL
    @AppStorage("vocabularyLearningLanguage") private var language = ""
    private let features: LibraryFeatureFactory
    private let deckID: UUID?
    private let fields: [FieldDef]
    private let text: (UUID) -> String
    private let onSaved: @MainActor () async -> Void
    @State private var showing = false

    public init(features: LibraryFeatureFactory, deckID: UUID?, fields: [FieldDef],
                text: @escaping (UUID) -> String, onSaved: @escaping @MainActor () async -> Void = {}) {
        self.features = features
        self.deckID = deckID
        self.fields = fields.filter { [.text, .richText, .cloze].contains($0.type) }
        self.text = text
        self.onSaved = onSaved
    }

    private var seedExpression: String {
        let preferred = fields.filter { ["target", "word", "phrase", "expression"].contains($0.name.lowercased()) }
        return (preferred + fields).lazy.map { text($0.id).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    public var body: some View {
        if let vocabulary = features.personalVocabulary, !fields.isEmpty {
            Section {
                Button("Create Vocabulary Set…") { showing = true }.disabled(seedExpression.isEmpty)
            }
            .sheet(isPresented: $showing) {
                let draft = VocabularySetDraft(term: .init(language: language, expression: seedExpression),
                                               meaning: "", meaningLanguage: "", sentence: "", deckID: deckID)
                VocabularyComposerView(vocabulary: vocabulary, decks: features.vocabularyDecks, preset: draft,
                                       packRoot: rootURL, restoreEditorDraft: true, onSaved: onSaved)
            }
        }
    }
}
