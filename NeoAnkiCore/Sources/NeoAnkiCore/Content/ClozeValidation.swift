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
            let (end, overflowed) = start.addingReportingOverflow(blank.length)
            guard start >= 0, !overflowed, end <= count else {
                throw ClozeValidationError.blankOutOfBounds
            }

            let range = start ..< end
            for existing in ranges where existing.overlaps(range) {
                throw ClozeValidationError.overlappingBlanks
            }
            ranges.append(range)
        }
    }

    /// Drops malformed spans so values from damaged or older persistence can
    /// still be displayed without allowing invalid offsets into String.
    public static func sanitize(text: String, blanks: [ClozeSpan]) -> [ClozeSpan] {
        let count = text.count
        var accepted: [ClozeSpan] = []
        var ranges: [Range<Int>] = []

        for blank in blanks.sorted(by: spanOrder) {
            let (end, overflowed) = blank.start.addingReportingOverflow(blank.length)
            guard blank.start >= 0, blank.length > 0, !overflowed, end <= count else {
                continue
            }

            let range = blank.start ..< end
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                continue
            }
            accepted.append(blank)
            ranges.append(range)
        }

        return accepted
    }

    public static func displayText(
        from text: String,
        blanks: [ClozeSpan],
        revealed: Bool,
        group: Int? = nil
    ) -> String {
        guard !text.isEmpty else { return "" }
        if revealed || blanks.isEmpty {
            return text
        }

        let hiddenBlanks = group.map { selectedGroup in
            blanks.filter { $0.group == selectedGroup }
        } ?? blanks
        let sorted = sanitize(text: text, blanks: hiddenBlanks).sorted { $0.start > $1.start }
        var result = text
        for blank in sorted {
            guard
                let start = result.index(
                    result.startIndex,
                    offsetBy: blank.start,
                    limitedBy: result.endIndex
                ),
                let end = result.index(start, offsetBy: blank.length, limitedBy: result.endIndex)
            else {
                continue
            }
            let replacement = blank.hint.map { "[\($0)]" } ?? "[…]"
            result.replaceSubrange(start ..< end, with: replacement)
        }
        return result
    }

    private static func spanOrder(_ lhs: ClozeSpan, _ rhs: ClozeSpan) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.length < rhs.length
    }
}
