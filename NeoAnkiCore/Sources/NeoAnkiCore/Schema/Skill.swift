import Foundation

/// The cognitive route a card trains, expressed as (input, output, operation).
///
/// This is deliberately domain-neutral: language listening, anatomy labeling,
/// music interval ID, and code recall are all just different combinations of
/// these primitives. The core ships knowing about none of those domains.
public struct Skill: Codable, Hashable, Sendable {
    public var input: Modality
    public var output: Modality
    public var operation: Operation

    public init(input: Modality, output: Modality, operation: Operation) {
        self.input = input
        self.output = output
        self.operation = operation
    }
}

/// How information is presented (as a cue) or produced (as a response).
public enum Modality: String, Codable, Sendable {
    case text
    case audio
    case image
    case video
    case diagram
    /// No stimulus / no explicit medium (e.g. bare recall).
    case none
    /// Open-ended production: typed, spoken, drawn, or arranged.
    case freeResponse
    /// Pick among options.
    case selection
    /// Point to / locate a position on an image or map.
    case spatial
    /// Put items into the correct order.
    case sequence
}

/// The cognitive act being practiced. Neutral across subjects.
public enum Operation: String, Codable, Sendable {
    case recognize
    case recall
    case discriminate
    case classify
    case locate
    case order
    case apply
    case explain
    /// Re-perform a stimulus (covers imitation/shadowing-style drills).
    case reproduce
}
