import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test func clozeBlankBuilderUsesCurrentSelectionAndRequestedGroup() throws {
    let text = "Alpha beta gamma"
    let blank = try #require(ClozeBlankBuilder.blank(
        text: text,
        selectionStart: 6,
        selectionLength: 4,
        group: 7
    ))

    #expect(blank == ClozeSpan(group: 7, start: 6, length: 4))
    #expect(ClozeValidation.displayText(
        from: text,
        blanks: [blank],
        revealed: false,
        group: 7
    ) == "Alpha […] gamma")
}

@Test func clozeBlankBuilderRejectsExtremeOffsetsWithoutTrapping() {
    #expect(ClozeBlankBuilder.blank(
        text: "safe",
        selectionStart: Int.max,
        selectionLength: 1,
        group: 1
    ) == nil)
    #expect(ClozeBlankBuilder.blank(
        text: "safe",
        selectionStart: 1,
        selectionLength: Int.max,
        group: 1
    ) == nil)
}
