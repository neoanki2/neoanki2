import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import PoemDeckBuilder
import ProseDeckBuilder
import SwiftUI

/// Presentation routing for the two built-in source editors. Ordinary or
/// unassigned items continue through their platform's normal item editor.
public struct GeneratedDeckEditorContext: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case poem, prose }
    public let kind: Kind
    public let deckID: UUID
    public let itemTypeID: UUID
    public let deckName: String

    public init?(item: Item, itemType: ItemType, deckName: String? = nil) {
        guard let deckID = item.deckID else { return nil }
        switch itemType.name {
        case "Poem Line": kind = .poem
        case "Prose Unit": kind = .prose
        default: return nil
        }
        self.deckID = deckID
        itemTypeID = itemType.id
        self.deckName = deckName ?? (kind == .poem ? "Poem" : "Prose")
    }
}

/// Both native shells supply their local dismissal/refresh actions. The editor
/// choice, application operation and source-specific view composition are shared.
public struct GeneratedDeckEditorView: View {
    private let editing: GeneratedDeckEditing
    private let context: GeneratedDeckEditorContext
    private let onSaved: () -> Void
    private let onCancel: () -> Void

    public init(editing: GeneratedDeckEditing, context: GeneratedDeckEditorContext,
                onSaved: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.editing = editing; self.context = context
        self.onSaved = onSaved; self.onCancel = onCancel
    }
    public var body: some View {
        switch context.kind {
        case .poem:
            PoemDeckEditorView(editing: editing, deckID: context.deckID,
                itemTypeID: context.itemTypeID, deckName: context.deckName,
                onSaved: onSaved, onCancel: onCancel)
        case .prose:
            ProseDeckEditorView(editing: editing, deckID: context.deckID,
                itemTypeID: context.itemTypeID, deckName: context.deckName,
                onSaved: onSaved, onCancel: onCancel)
        }
    }
}
