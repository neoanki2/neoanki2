import Foundation

/// A declarative recipe for producing one card from a note. Pure data (no
/// markup), so a visual builder and a text/DSL form can share one source of
/// truth. Each note type owns a list of these.
public struct CardTemplate: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// What the learner sees before answering.
    public var prompt: Side
    /// What is revealed / checked against after answering.
    public var answer: Side
    public var interaction: Interaction
    public var skill: Skill
    /// Optional gate: if set and unsatisfied, this template produces no card
    /// for a given note (e.g. only make a listening card when audio exists).
    public var generateWhen: SlotCondition?

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: Side,
        answer: Side,
        interaction: Interaction,
        skill: Skill,
        generateWhen: SlotCondition? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.answer = answer
        self.interaction = interaction
        self.skill = skill
        self.generateWhen = generateWhen
    }
}

/// One face of a card: an ordered list of slots to lay out natively.
public struct Side: Codable, Equatable, Sendable {
    public var slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }
}

/// A single rendered element on a side: a content source plus presentation.
public struct Slot: Codable, Equatable, Sendable {
    public var source: SlotSource
    public var presentation: Presentation

    public init(source: SlotSource, presentation: Presentation = Presentation()) {
        self.source = source
        self.presentation = presentation
    }
}

/// Where a slot's content comes from.
public enum SlotSource: Codable, Equatable, Sendable {
    /// Content of a note field, referenced by `FieldDef.id`.
    case field(UUID)
    /// Static template text (labels like "Translate:", "Define:").
    case literal(String)
}

/// How a slot is displayed. Decoupled from content so any value can be shown
/// in any way (e.g. an image blurred on the prompt, shown plainly on the answer).
public struct Presentation: Codable, Equatable, Sendable {
    public var reveal: RevealMode
    public var media: MediaBehavior

    public init(reveal: RevealMode = .always, media: MediaBehavior = .default) {
        self.reveal = reveal
        self.media = media
    }
}

public enum RevealMode: String, Codable, Sendable {
    case always
    case hiddenUntilAnswer
    case blurred
}

public enum MediaBehavior: String, Codable, Sendable {
    case `default`
    case autoplay
    case playOnTap
    case loop
}

/// How the learner responds — this is where desirable difficulty is encoded.
public enum Interaction: String, Codable, Sendable {
    /// Flip to reveal the answer, then self-grade.
    case reveal
    /// Type the answer; can be auto-checked against the answer side.
    case type
    /// Choose among options.
    case choose
    /// Record audio/video and self-compare against a reference.
    case record
    /// Fill in cloze blanks.
    case cloze
    /// Arrange items into the correct order.
    case arrange
}

/// A boolean condition over a note's fields, used to gate card generation.
public indirect enum SlotCondition: Codable, Equatable, Sendable {
    case fieldNotEmpty(UUID)
    case fieldEmpty(UUID)
    case all([SlotCondition])
    case any([SlotCondition])
}
