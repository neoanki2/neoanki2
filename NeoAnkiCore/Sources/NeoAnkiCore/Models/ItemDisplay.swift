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
        case .empty, .media, .cloze:
            return ""
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
        case .text, .richText, .number:
            return true
        case .audio, .image, .gif, .video:
            return false
        }
    }

    func contentValue(from text: String) -> ContentValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .text:
            return .text(trimmed)
        case .richText:
            return trimmed.isEmpty ? .empty : .rich([Span(trimmed)])
        case .number:
            guard let number = Double(trimmed) else { return .empty }
            return .number(number)
        case .audio, .image, .gif, .video:
            return .empty
        }
    }
}
