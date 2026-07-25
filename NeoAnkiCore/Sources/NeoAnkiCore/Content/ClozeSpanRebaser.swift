import Foundation

/// Rebases cloze spans across one contiguous text edit using Swift `Character`
/// offsets. Spans are removed when an edit crosses only one of their boundaries,
/// because retaining them would silently point at unrelated text.
public enum ClozeSpanRebaser {
    public struct Result: Equatable, Sendable {
        public var spans: [ClozeSpan]
        public var invalidated: [ClozeSpan]

        public init(spans: [ClozeSpan], invalidated: [ClozeSpan]) {
            self.spans = spans
            self.invalidated = invalidated
        }
    }

    public static func rebase(
        spans: [ClozeSpan],
        from oldText: String,
        to newText: String
    ) -> Result {
        guard oldText != newText, !spans.isEmpty else {
            return Result(spans: spans, invalidated: [])
        }

        let old = Array(oldText)
        let new = Array(newText)
        let sharedPrefix = commonPrefixCount(old, new)
        let sharedSuffix = commonSuffixCount(old, new, excludingPrefix: sharedPrefix)
        let oldEditEnd = old.count - sharedSuffix
        let newEditEnd = new.count - sharedSuffix
        let replacementLength = newEditEnd - sharedPrefix
        let delta = replacementLength - (oldEditEnd - sharedPrefix)

        var rebased: [ClozeSpan] = []
        var invalidated: [ClozeSpan] = []
        rebased.reserveCapacity(spans.count)

        for span in spans {
            let spanEnd = span.start + span.length
            guard span.start >= 0, span.length > 0, spanEnd <= old.count else {
                invalidated.append(span)
                continue
            }

            var updated = span
            if sharedPrefix == oldEditEnd {
                // Insertion: content inserted strictly inside a blank belongs to it.
                if sharedPrefix <= span.start {
                    updated.start += delta
                } else if sharedPrefix < spanEnd {
                    updated.length += delta
                }
            } else if oldEditEnd <= span.start {
                updated.start += delta
            } else if sharedPrefix >= spanEnd {
                // Edit is after the span.
            } else if sharedPrefix >= span.start, oldEditEnd <= spanEnd {
                // Replacement is wholly inside the span, including replacing all
                // of it. Preserve its group and hint around the replacement.
                updated.length += delta
            } else {
                // The edit consumed exactly one boundary or surrounded the span.
                invalidated.append(span)
                continue
            }

            if updated.length > 0, updated.start >= 0,
               updated.start + updated.length <= new.count {
                rebased.append(updated)
            } else {
                invalidated.append(span)
            }
        }

        return Result(spans: rebased, invalidated: invalidated)
    }

    private static func commonPrefixCount(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func commonSuffixCount(
        _ lhs: [Character],
        _ rhs: [Character],
        excludingPrefix prefix: Int
    ) -> Int {
        var count = 0
        while lhs.count - count > prefix,
              rhs.count - count > prefix,
              lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1] {
            count += 1
        }
        return count
    }
}
