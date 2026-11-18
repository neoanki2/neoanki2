import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

private struct OpenLearnInContextKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID?) -> Void = { _ in }
}
public extension EnvironmentValues {
    var openLearnInContext: @MainActor (UUID?) -> Void {
        get { self[OpenLearnInContextKey.self] }
        set { self[OpenLearnInContextKey.self] = newValue }
    }
}

/// Uses the editor's live field content without changing or saving that item.
public struct ContextAuthoringEntry: View {
    @Environment(\.vocabularyPackRootURL) private var rootURL
    private let makeModel: (URL) -> LearnInContextModel
    let deckID: UUID?
    let fields: [FieldDef]
    let text: (UUID) -> String
    @State private var showing = false
    public init(library: any LibraryRepository, deckID: UUID?, fields: [FieldDef],
                text: @escaping (UUID) -> String, onSaved: @escaping @MainActor () async -> Void = {}) {
        self.makeModel = { LearnInContextModel(library: library, rootURL: $0, onSaved: onSaved) }; self.deckID = deckID
        self.fields = fields.filter { [.text, .richText, .cloze].contains($0.type) }
        self.text = text
    }
    public init(features: LibraryFeatureFactory, deckID: UUID?, fields: [FieldDef],
                text: @escaping (UUID) -> String, onSaved: @escaping @MainActor () async -> Void = {}) {
        makeModel = { features.makeLearnInContext(rootURL: $0, onSaved: onSaved) }
        self.deckID = deckID; self.fields = fields.filter { [.text, .richText, .cloze].contains($0.type) }
        self.text = text
    }
    private var seedExpression: String {
        let preferred = fields.filter { ["target", "word", "phrase", "expression"].contains($0.name.lowercased()) }
        return (preferred + fields).map { text($0.id).trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }
    public var body: some View {
        if let rootURL, !fields.isEmpty {
            Section {
                Button("Learn in Context…") { showing = true }
                    .disabled(seedExpression.isEmpty)
            }
            .sheet(isPresented: $showing) {
                LearnInContextView(model: makeModel(rootURL), deckID: deckID, expression: seedExpression)
            }
        }
    }
}
