import Foundation

/// Turns a note into its cards by applying the templates of its note type.
/// A template that is gated by `generateWhen` is skipped when the condition
/// isn't met for the note (e.g. no listening card without audio).
public enum CardGenerator {
    public static func cards(
        for note: Note,
        type: NoteType,
        now: Date = .now
    ) -> [Card] {
        type.templates.compactMap { template in
            guard shouldGenerate(template, for: note) else { return nil }
            return Card(
                noteID: note.id,
                templateID: template.id,
                skill: template.skill,
                memory: .new(due: now),
                deckID: note.deckID
            )
        }
    }

    public static func shouldGenerate(_ template: CardTemplate, for note: Note) -> Bool {
        guard let condition = template.generateWhen else { return true }
        return evaluate(condition, for: note)
    }

    private static func evaluate(_ condition: SlotCondition, for note: Note) -> Bool {
        switch condition {
        case let .fieldNotEmpty(fieldID):
            return !note.isFieldEmpty(fieldID)
        case let .fieldEmpty(fieldID):
            return note.isFieldEmpty(fieldID)
        case let .all(conditions):
            return conditions.allSatisfy { evaluate($0, for: note) }
        case let .any(conditions):
            return conditions.contains { evaluate($0, for: note) }
        }
    }
}
