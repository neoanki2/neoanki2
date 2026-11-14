import NeoAnkiApplication
import NeoAnkiCore
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
    let library: any LibraryRepository
    let deckID: UUID?
    let fields: [FieldDef]
    let text: (UUID) -> String
    let onSaved: @MainActor () async -> Void
    @State private var showing = false
    public init(library: any LibraryRepository, deckID: UUID?, fields: [FieldDef],
                text: @escaping (UUID) -> String, onSaved: @escaping @MainActor () async -> Void = {}) {
        self.library = library; self.deckID = deckID
        self.fields = fields.filter { [.text, .richText, .cloze].contains($0.type) }
        self.text = text; self.onSaved = onSaved
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
                LearnInContextView(library: library, rootURL: rootURL, deckID: deckID,
                                   expression: seedExpression, onSaved: onSaved)
            }
        }
    }
}
