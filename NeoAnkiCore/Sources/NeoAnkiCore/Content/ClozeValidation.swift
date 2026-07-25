import Foundation

public enum ClozeValidationError: Error, Sendable, Equatable, LocalizedError {
    case emptyText
    case noBlanks
    case blankOutOfBounds
    case overlappingBlanks
    case emptyBlank

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cloze text is required."
        case .noBlanks:
            return "Mark at least one blank in the cloze field."
        case .blankOutOfBounds:
            return "A cloze blank extends beyond the text."
        case .overlappingBlanks:
            return "Cloze blanks cannot overlap."
        case .emptyBlank:
            return "Each cloze blank must contain at least one character."
        }
    }
}

public enum ClozeValidation {
    public static func validate(text: String, blanks: [ClozeSpan]) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClozeValidationError.emptyText
        }
        guard !blanks.isEmpty else {
            throw ClozeValidationError.noBlanks
        }

        let count = text.count
        var ranges: [Range<Int>] = []

        for blank in blanks {
            guard blank.length >= 1 else {
                throw ClozeValidationError.emptyBlank
            }
            let start = blank.start
            let end = start + blank.length
            guard start >= 0, end <= count else {
                throw ClozeValidationError.blankOutOfBounds
            }

            let range = start ..< end
            for existing in ranges where existing.overlaps(range) {
                throw ClozeValidationError.overlappingBlanks
            }
            ranges.append(range)
        }
    }

    public static func displayText(from text: String, blanks: [ClozeSpan], revealed: Bool) -> String {
        guard !text.isEmpty else { return "" }
        if revealed || blanks.isEmpty {
            return text
        }

        let sorted = blanks.sorted { $0.start > $1.start }
        var result = text
        for blank in sorted {
            let start = result.index(result.startIndex, offsetBy: blank.start)
            let end = result.index(start, offsetBy: blank.length)
            let replacement = blank.hint.map { "[\($0)]" } ?? "[…]"
            result.replaceSubrange(start ..< end, with: replacement)
        }
        return result
    }
}
