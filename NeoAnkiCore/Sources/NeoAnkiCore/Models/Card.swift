import Foundation

/// A single reviewable probe: one note viewed through one template, plus its
/// own memory state. Content is not copied here — it is resolved from the note
/// and template at study time — so a card stays small and always in sync.
public struct Card: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var noteID: UUID
    public var templateID: UUID
    /// Cached from the template so cards can be queried/filtered by skill
    /// without loading the note type.
    public var skill: Skill
    public var memory: MemoryState
    public var isSuspended: Bool
    public var deckID: UUID?

    public init(
        id: UUID = UUID(),
        noteID: UUID,
        templateID: UUID,
        skill: Skill,
        memory: MemoryState = .new(),
        isSuspended: Bool = false,
        deckID: UUID? = nil
    ) {
        self.id = id
        self.noteID = noteID
        self.templateID = templateID
        self.skill = skill
        self.memory = memory
        self.isSuspended = isSuspended
        self.deckID = deckID
    }

    public func isDue(asOf now: Date = .now) -> Bool {
        !isSuspended && memory.isDue(asOf: now)
    }
}
