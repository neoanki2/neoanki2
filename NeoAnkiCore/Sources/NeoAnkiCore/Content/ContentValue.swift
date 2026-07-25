import Foundation

/// A single piece of card content, rendered natively (no HTML/CSS).
///
/// Everything a user can put in a field is one of these cases. Presentation
/// (autoplay, blur, hide-until-answer) is decided by templates, not here, so
/// the same value can appear differently on a prompt vs. an answer.
public enum ContentValue: Codable, Equatable, Sendable {
    /// Plain text. `lang` is an optional BCP-47 tag (e.g. "es", "ja") kept only
    /// as metadata for rendering/TTS hints; the core stays domain-neutral.
    case text(String, lang: String? = nil)
    /// Text with lightweight, semantic styling spans.
    case rich([Span])
    /// A reference to a stored media asset (audio, image, gif, video).
    case media(MediaRef)
    /// Text containing one or more fill-in blanks.
    case cloze(String, blanks: [ClozeSpan])
    /// A numeric value (measurements, dates-as-numbers, quantities).
    case number(Double)
    /// No content.
    case empty

    /// Whether this value carries no meaningful content, used by card
    /// generation to decide whether optional templates should produce a card.
    public var isEmpty: Bool {
        switch self {
        case .empty:
            return true
        case let .text(string, _):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .rich(spans):
            return spans.allSatisfy {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case let .cloze(string, _):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number, .media:
            return false
        }
    }
}

/// A run of text with semantic (not visual) styling. Rendering maps these to
/// native styles so there is no markup to store or sanitize.
public struct Span: Codable, Equatable, Sendable {
    public var text: String
    public var styles: Set<Style>

    public init(_ text: String, styles: Set<Style> = []) {
        self.text = text
        self.styles = styles
    }

    public enum Style: String, Codable, Sendable {
        case bold
        case italic
        case underline
        case strikethrough
        case highlight
        case code
    }
}

/// A single fill-in blank within a `.cloze` string.
///
/// `group` lets several blanks be tested together (all blanks sharing a group
/// are hidden at once); `start`/`length` are character offsets into the text.
public struct ClozeSpan: Codable, Equatable, Sendable {
    public var group: Int
    public var start: Int
    public var length: Int
    public var hint: String?

    public init(group: Int, start: Int, length: Int, hint: String? = nil) {
        self.group = group
        self.start = start
        self.length = length
        self.hint = hint
    }

    private enum CodingKeys: String, CodingKey {
        case group, start, length, hint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decode(Int.self, forKey: .group)
        start = try container.decode(Int.self, forKey: .start)
        length = try container.decode(Int.self, forKey: .length)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)

        guard start >= 0, length >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: start < 0 ? .start : .length,
                in: container,
                debugDescription: "Cloze span offsets cannot be negative."
            )
        }
    }
}
