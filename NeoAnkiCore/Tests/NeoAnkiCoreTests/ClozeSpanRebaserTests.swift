import Testing
@testable import NeoAnkiCore

@Test func clozeRebaserShiftsBlankAfterInsertion() {
    let span = ClozeSpan(group: 3, start: 6, length: 4, hint: "keep")
    let result = ClozeSpanRebaser.rebase(
        spans: [span],
        from: "Alpha beta",
        to: "New Alpha beta"
    )

    #expect(result.spans == [ClozeSpan(group: 3, start: 10, length: 4, hint: "keep")])
    #expect(result.invalidated.isEmpty)
}

@Test func clozeRebaserExpandsForInsertionInsideBlank() {
    let result = ClozeSpanRebaser.rebase(
        spans: [ClozeSpan(group: 1, start: 6, length: 4)],
        from: "Alpha beta",
        to: "Alpha beXta"
    )

    #expect(result.spans == [ClozeSpan(group: 1, start: 6, length: 5)])
}

@Test func clozeRebaserShrinksForDeletionInsideBlank() {
    let result = ClozeSpanRebaser.rebase(
        spans: [ClozeSpan(group: 2, start: 6, length: 5)],
        from: "Alpha brave",
        to: "Alpha bave"
    )

    #expect(result.spans == [ClozeSpan(group: 2, start: 6, length: 4)])
}

@Test func clozeRebaserPreservesReplacementAndGroup() {
    let result = ClozeSpanRebaser.rebase(
        spans: [ClozeSpan(group: 7, start: 6, length: 4, hint: "word")],
        from: "Alpha beta",
        to: "Alpha gamma"
    )

    #expect(result.spans == [ClozeSpan(group: 7, start: 6, length: 5, hint: "word")])
}

@Test func clozeRebaserUsesUnicodeCharacterOffsets() {
    let result = ClozeSpanRebaser.rebase(
        spans: [ClozeSpan(group: 4, start: 2, length: 1)],
        from: "A 🧠 B",
        to: "🙂 A 🧠 B"
    )

    #expect(result.spans == [ClozeSpan(group: 4, start: 4, length: 1)])
}

@Test func clozeRebaserInvalidatesAmbiguousBoundaryEdit() {
    let span = ClozeSpan(group: 1, start: 6, length: 4)
    let result = ClozeSpanRebaser.rebase(
        spans: [span],
        from: "Alpha beta",
        to: "Alphata"
    )

    #expect(result.spans.isEmpty)
    #expect(result.invalidated == [span])
}
