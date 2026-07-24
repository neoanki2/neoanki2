import Foundation

/// A user-declared slot of content on a note type. Names and types are data,
/// so no field ("Front", "Audio", "Meaning", ...) is privileged by the core.
public struct FieldDef: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var type: FieldType
    public var isRequired: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: FieldType,
        isRequired: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isRequired = isRequired
    }
}

public enum FieldType: String, Codable, Sendable {
    case text
    case richText
    case audio
    case image
    case gif
    case video
    case number
}
