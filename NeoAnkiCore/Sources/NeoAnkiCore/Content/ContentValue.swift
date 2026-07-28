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
    public var styles: Set<Style> {
        didSet {
            styles = Self.normalized(styles)
        }
    }
    public var textColor: TextColor?
    public var textSize: TextSize?
    public var link: String?

    public init(
        _ text: String,
        styles: Set<Style> = [],
        textColor: TextColor? = nil,
        textSize: TextSize? = nil,
        link: String? = nil
    ) {
        self.text = text
        self.styles = Self.normalized(styles)
        self.textColor = textColor
        self.textSize = textSize
        self.link = link
    }

    private enum CodingKeys: String, CodingKey {
        case text, styles, textColor, textSize, link
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(String.self, forKey: .text),
            styles: try container.decodeIfPresent(Set<Style>.self, forKey: .styles) ?? [],
            textColor: try container.decodeIfPresent(TextColor.self, forKey: .textColor),
            textSize: try container.decodeIfPresent(TextSize.self, forKey: .textSize),
            link: try container.decodeIfPresent(String.self, forKey: .link)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(Self.normalized(styles), forKey: .styles)
        try container.encodeIfPresent(textColor, forKey: .textColor)
        try container.encodeIfPresent(textSize, forKey: .textSize)
        try container.encodeIfPresent(link, forKey: .link)
    }

    public var hasFormatting: Bool {
        !styles.isEmpty || textColor != nil || textSize != nil || link != nil
    }

    public func hasSameFormatting(as other: Span) -> Bool {
        styles == other.styles
            && textColor == other.textColor
            && textSize == other.textSize
            && link == other.link
    }

    /// Resolves unordered legacy style conflicts using the renderer's existing
    /// visible precedence. New writers therefore emit one unambiguous style
    /// from each mutually exclusive pair without rejecting older content.
    private static func normalized(_ styles: Set<Style>) -> Set<Style> {
        var result = styles
        if result.contains(.highlight) {
            result.remove(.code)
        }
        if result.contains(.superscript) {
            result.remove(.subscriptText)
        }
        return result
    }

    public enum Style: String, Codable, Sendable {
        case bold
        case italic
        case underline
        case strikethrough
        case highlight
        case code
        case superscript
        case subscriptText = "subscript"
    }

    /// Portable semantic colors that resolve through the platform's adaptive
    /// system palette rather than storing display-specific RGB values.
    public enum TextColor: String, Codable, CaseIterable, Sendable {
        case red
        case orange
        case yellow
        case green
        case mint
        case teal
        case cyan
        case blue
        case indigo
        case purple
        case pink
        case brown
        case gray
    }

    /// Relative sizes preserve the host surface's typography and accessibility
    /// scaling instead of freezing authored text to a point size.
    public enum TextSize: String, Codable, CaseIterable, Sendable {
        case small
        case large
    }
}

public enum RichTextValidation {
    public static let maximumLinkBytes = 2_048

    public static func isValidLink(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumLinkBytes,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased()
        else {
            return false
        }

        switch scheme {
        case "http", "https":
            return components.host?.isEmpty == false
        case "mailto":
            return !components.path.isEmpty
        default:
            return false
        }
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
