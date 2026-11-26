import Foundation

/// Reads and writes word lists for bulk Known Words import and export.
///
/// A plain list has one word or phrase per line and marks each as known. A CSV or TSV file with a
/// header row may add `judgment`, `sense`, and `lemma` columns. Empty lines and lines that start
/// with `#` are skipped.
public enum VocabularyListFormat {
    public struct ParseResult: Equatable, Sendable {
        public var entries: [VocabularyJudgmentEntry] = []
        /// Lines that repeated an earlier term and were skipped.
        public var duplicates = 0
        /// One-based line numbers that could not be read.
        public var rejectedLines: [Int] = []
    }

    public static func parse(_ text: String, language: String,
                             defaultJudgment: VocabularyJudgment = .known) throws -> ParseResult {
        var result = ParseResult()
        var seen: Set<String> = []
        var columns: [String: Int]?
        var separator: Character = ","
        var sawContent = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            var line = String(raw)
            if index == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if !sawContent {
                sawContent = true
                separator = trimmed.contains("\t") ? "\t" : ","
                let header = fields(trimmed, separator: separator).map { $0.lowercased() }
                if let expression = header.firstIndex(where: { ["expression", "word", "term", "phrase"].contains($0) }) {
                    var map = ["expression": expression]
                    for (name, aliases) in [("judgment", ["judgment", "status"]), ("sense", ["sense", "meaning"]),
                                            ("lemma", ["lemma", "dictionary form"])] {
                        if let column = header.firstIndex(where: aliases.contains) { map[name] = column }
                    }
                    columns = map
                    continue
                }
            }
            let values: [String]
            if let columns {
                let row = fields(trimmed, separator: separator)
                values = ["expression", "judgment", "sense", "lemma"].map { name in
                    columns[name].flatMap { $0 < row.count ? row[$0] : nil } ?? ""
                }
            } else if separator == "\t" {
                let row = fields(trimmed, separator: "\t")
                values = [row[0], row.count > 1 ? row[1] : "", "", ""]
            } else {
                values = [trimmed, "", "", ""]
            }
            guard let judgment = judgment(values[1], default: defaultJudgment),
                  let term = try? VocabularyTerm(language: language, expression: values[0],
                                                 sense: values[2].isEmpty ? nil : values[2],
                                                 lemma: values[3]).validated() else {
                result.rejectedLines.append(index + 1)
                continue
            }
            guard seen.insert(term.id).inserted else { result.duplicates += 1; continue }
            result.entries.append(.init(term: term, judgment: judgment))
            guard result.entries.count <= maximumVocabularyBatchSize else { throw VocabularySetError.batchTooLarge }
        }
        return result
    }

    /// CSV with a header row, readable by `parse`. Words known only from reviews export as `known`;
    /// words without a judgment export as `reviewHistory`, which leaves them unchanged on import.
    public static func csv(_ statuses: [VocabularyStatus]) -> String {
        var lines = ["expression,judgment,sense,lemma"]
        for status in statuses {
            let judgment = status.explicitJudgment ?? (status.isKnown ? .known : .reviewHistory)
            lines.append([status.term.expression, judgment.rawValue, status.term.sense ?? "", status.term.lemma ?? ""]
                .map(quoted).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func judgment(_ text: String, default fallback: VocabularyJudgment) -> VocabularyJudgment? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        switch key {
        case "": return fallback
        case "known", "yes", "1": return .known
        case "unfamiliar", "notknown", "unknown", "no", "0": return .unfamiliar
        case "ignored", "ignore": return .ignored
        case "reviewhistory", "fromreviews": return .reviewHistory
        default: return nil
        }
    }

    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\t" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Split one CSV or TSV line, honoring double-quoted fields.
    static func fields(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = Array(line).makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { current.append(character) }
            } else if character == "\"", current.trimmingCharacters(in: .whitespaces).isEmpty {
                current = ""
                quoted = true
            } else if character == separator {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else { current.append(character) }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}
