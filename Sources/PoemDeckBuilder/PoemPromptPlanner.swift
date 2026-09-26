import Foundation

/// Plans the visible context for each answer, in poem order.
public enum PoemPromptPlanner {
    public static func prompts(for poem: ParsedPoem) -> [String] {
        let lines = poem.lines
        guard lines.count > 1 else { return [] }
        var lengths = (1 ..< lines.count).map { min(2, $0) }

        while true {
            let prompts = lengths.enumerated().map { offset, length in
                context(lines, answerIndex: offset + 1, length: length)
            }
            let groups = Dictionary(grouping: prompts.indices, by: { prompts[$0] })
            var extended = false
            for indices in groups.values where indices.count > 1 {
                for offset in indices where lengths[offset] < offset + 1 {
                    lengths[offset] += 1
                    extended = true
                }
            }
            if !extended { return prompts }
        }
    }

    private static func context(
        _ lines: [ParsedPoemLine],
        answerIndex: Int,
        length: Int
    ) -> String {
        let start = answerIndex - length
        var parts = [lines[start].text]
        for index in (start + 1) ..< answerIndex {
            if lines[index].startsStanza { parts.append("") }
            parts.append(lines[index].text)
        }
        return parts.joined(separator: "\n")
    }
}
