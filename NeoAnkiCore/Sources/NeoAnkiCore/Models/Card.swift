import Foundation

/// A single reviewable probe: one item viewed through one template, plus its
/// own memory state. Content is not copied here — it is resolved from the item
/// and template at study time — so a card stays small and always in sync.
public struct Card: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var itemID: UUID
    public var templateID: UUID
    /// Cached from the template so cards can be queried/filtered by skill
    /// without loading the item type.
    public var skill: Skill
    public var memory: MemoryState
    /// Numerical model used to derive `memory`. Nil identifies a legacy card
    /// that must be replayed before it is updated by a newer model.
    public var memoryModelVersion: String?
    /// Immutable parameter set used to derive `memory`, when known.
    public var memoryParameterSetID: UUID?
    /// Reviews before this instant are retained as immutable evidence but do
    /// not participate in replay or optimization after a scheduler reset.
    public var schedulingHistoryOrigin: Date?
    public var isSuspended: Bool
    public var deckID: UUID?
    /// For cloze interactions, identifies the one blank group this card tests.
    /// Nil for non-cloze cards.
    public var clozeGroup: Int?

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        templateID: UUID,
        skill: Skill,
        memory: MemoryState = .new(),
        memoryModelVersion: String? = nil,
        memoryParameterSetID: UUID? = nil,
        schedulingHistoryOrigin: Date? = nil,
        isSuspended: Bool = false,
        deckID: UUID? = nil,
        clozeGroup: Int? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.templateID = templateID
        self.skill = skill
        self.memory = memory
        self.memoryModelVersion = memoryModelVersion
        self.memoryParameterSetID = memoryParameterSetID
        self.schedulingHistoryOrigin = schedulingHistoryOrigin
        self.isSuspended = isSuspended
        self.deckID = deckID
        self.clozeGroup = clozeGroup
    }

    public func isDue(asOf now: Date = .now) -> Bool {
        !isSuspended && memory.isDue(asOf: now)
    }

    private enum CodingKeys: String, CodingKey {
        case id, itemID, templateID, skill, memory
        case memoryModelVersion, memoryParameterSetID, schedulingHistoryOrigin
        case isSuspended, deckID, clozeGroup
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            itemID: try values.decode(UUID.self, forKey: .itemID),
            templateID: try values.decode(UUID.self, forKey: .templateID),
            skill: try values.decode(Skill.self, forKey: .skill),
            memory: try values.decode(MemoryState.self, forKey: .memory),
            memoryModelVersion: try values.decodeIfPresent(String.self, forKey: .memoryModelVersion),
            memoryParameterSetID: try values.decodeIfPresent(UUID.self, forKey: .memoryParameterSetID),
            schedulingHistoryOrigin: try values.decodeIfPresent(Date.self, forKey: .schedulingHistoryOrigin),
            isSuspended: try values.decode(Bool.self, forKey: .isSuspended),
            deckID: try values.decodeIfPresent(UUID.self, forKey: .deckID),
            clozeGroup: try values.decodeIfPresent(Int.self, forKey: .clozeGroup)
        )
    }
}
