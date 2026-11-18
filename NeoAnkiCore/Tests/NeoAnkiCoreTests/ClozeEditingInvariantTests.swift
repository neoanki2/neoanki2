import Foundation
import Testing
@testable import NeoAnkiCore

/// Exhaustive small-input edits use Unicode grapheme coordinates. The oracle is
/// the selected text and preserved identity, not another implementation of diff.
@Suite struct ClozeEditingInvariantTests {
    @Test(arguments: ["ABCDEF", "АБВГДЕ", "A🧠e\u{301}中БZ"])
    func insertingOutsideEveryPossibleBlankPreservesItsTextAndIsReversible(text: String) throws {
        let characters = Array(text)
        for start in 0..<characters.count {
            for end in (start + 1)...characters.count {
                let blank = ClozeSpan(group: 7, start: start, length: end - start, hint: "Keep identity")
                let expectedText = String(characters[start..<end])
                for position in 0...characters.count where position <= start || position >= end {
                    var changed = characters
                    changed.insert(contentsOf: Array("§¶"), at: position)
                    let edited = String(changed)
                    let result = ClozeSpanRebaser.rebase(spans: [blank], from: text, to: edited)
                    #expect(result.invalidated.isEmpty)
                    let kept = try #require(result.spans.first)
                    #expect(kept.group == blank.group && kept.hint == blank.hint)
                    #expect(String(changed[kept.start..<(kept.start + kept.length)]) == expectedText)
                    #expect(ClozeSpanRebaser.rebase(spans: result.spans, from: edited, to: text).spans == [blank])
                }
            }
        }
    }

    @Test(arguments: ["ABCDEF", "АБВГДЕ", "A🧠e\u{301}中БZ"])
    func replacingEveryRangeInsideABlankPreservesTheWholeRemainingAnswer(text: String) throws {
        let original = Array(text)
        let blank = ClozeSpan(group: 9, start: 0, length: original.count, hint: "Answer")
        for start in 0..<original.count {
            for end in (start + 1)...original.count {
                for replacement in ["", "§", "§¶"] {
                    var edited = original
                    edited.replaceSubrange(start..<end, with: Array(replacement))
                    let result = ClozeSpanRebaser.rebase(spans: [blank], from: text, to: String(edited))
                    if edited.isEmpty {
                        #expect(result.spans.isEmpty)
                        #expect(result.invalidated == [blank])
                    } else {
                        #expect(result.invalidated.isEmpty)
                        #expect(result.spans == [.init(group: 9, start: 0, length: edited.count, hint: "Answer")])
                        try ClozeValidation.validate(text: String(edited), blanks: result.spans)
                    }
                }
            }
        }
    }

    @Test(arguments: ["ABCDEF", "АБВГДЕ", "A🧠e\u{301}中БZ"])
    func deletingAcrossOnlyOneBoundaryNeverSilentlySelectsADifferentAnswer(text: String) {
        let original = Array(text)
        let blank = ClozeSpan(group: 2, start: 2, length: 2)
        for range in [0..<3, 1..<3, 3..<5, 3..<6, 1..<5] {
            var edited = original
            edited.replaceSubrange(range, with: Array("§"))
            let result = ClozeSpanRebaser.rebase(spans: [blank], from: text, to: String(edited))
            #expect(result.spans.isEmpty)
            #expect(result.invalidated == [blank])
        }
    }

    @Test func editingOneGroupDoesNotCorruptTheOtherGroupsOrHints() {
        let original = "Alpha Beta Gamma"
        let blanks: [ClozeSpan] = [
            .init(group: 1, start: 0, length: 5, hint: "First"),
            .init(group: 2, start: 6, length: 4, hint: "Second"),
            .init(group: 3, start: 11, length: 5, hint: "Third"),
        ]
        let result = ClozeSpanRebaser.rebase(spans: blanks, from: original, to: "Alpha NEW Gamma")
        #expect(result.spans == [blanks[0], .init(group: 2, start: 6, length: 3, hint: "Second"), .init(group: 3, start: 10, length: 5, hint: "Third")])
        #expect(result.invalidated.isEmpty)
        #expect(ClozeValidation.displayText(from: "Alpha NEW Gamma", blanks: result.spans, revealed: false, group: 2) == "Alpha [Second] Gamma")
    }
}
