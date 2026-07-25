import Foundation

/// Domain-neutral display helpers for items in lists and browsers.
public enum ItemDisplay {
    public static func title(for item: Item, in itemType: ItemType) -> String {
        plainText(from: item, fieldAt: 0, in: itemType)
    }

    public static func subtitle(for item: Item, in itemType: ItemType) -> String {
        plainText(from: item, fieldAt: 1, in: itemType)
    }

    public static func plainText(from value: ContentValue) -> String {
        switch value {
        case let .text(string, _):
            return string
        case let .rich(spans):
            return spans.map(\.text).joined()
        case let .number(number):
            return String(number)
        case let .media(ref):
            return ref.altText ?? mediaKindLabel(ref.kind)
        case let .cloze(text, blanks):
            return ClozeValidation.displayText(from: text, blanks: blanks, revealed: false)
        case .empty:
            return ""
        }
    }

    private static func mediaKindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .audio: "Audio"
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        }
    }

    private static func plainText(from item: Item, fieldAt index: Int, in itemType: ItemType) -> String {
        guard itemType.fields.indices.contains(index) else { return "" }
        let field = itemType.fields[index]
        guard let value = item.value(for: field.id) else { return "" }
        return plainText(from: value)
    }
}

public extension FieldDef {
    var supportsTextInput: Bool {
        switch type {
        case .text, .richText, .number, .cloze:
            return true
        case .audio, .image, .gif, .video:
            return false
        }
    }

    var supportsMediaInput: Bool {
        type.mediaKind != nil
    }

    var isTextLike: Bool {
        switch type {
        case .text, .richText, .cloze:
            true
        default:
            false
        }
    }

    func contentValue(from text: String) -> ContentValue {
        contentValue(from: text.isEmpty ? [] : [Span(text)])
    }

    func contentValue(from spans: [Span]) -> ContentValue {
        let merged = Self.mergeAdjacent(spans)
        let plain = merged.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        switch type {
        case .text:
            if plain.isEmpty { return .empty }
            if merged.allSatisfy({ $0.styles.isEmpty }) {
                return .text(plain)
            }
            return .rich(merged)
        case .richText:
            return plain.isEmpty ? .empty : .rich(merged)
        case .number:
            guard let number = Double(plain) else { return .empty }
            return .number(number)
        case .cloze:
            return plain.isEmpty ? .empty : .cloze(plain, blanks: [])
        case .audio, .image, .gif, .video:
            return .empty
        }
    }

    func contentValue(from media: MediaRef?) -> ContentValue {
        guard let media else { return .empty }
        guard type.mediaKind == media.kind else { return .empty }
        return .media(media)
    }

    func contentValue(fromClozeText text: String, blanks: [ClozeSpan]) -> ContentValue {
        guard type == .cloze else { return .empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || blanks.isEmpty { return .empty }
        return .cloze(text, blanks: blanks)
    }

    private static func mergeAdjacent(_ spans: [Span]) -> [Span] {
        spans.reduce(into: [Span]()) { result, span in
            guard !span.text.isEmpty else { return }
            if let last = result.last, last.styles == span.styles {
                result[result.count - 1] = Span(last.text + span.text, styles: last.styles)
            } else {
                result.append(span)
            }
        }
    }
}
