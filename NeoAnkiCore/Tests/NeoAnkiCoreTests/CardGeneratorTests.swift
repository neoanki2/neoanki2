import Foundation
import Testing
@testable import NeoAnkiCore

private func makeNoteType() -> (NoteType, front: FieldDef, back: FieldDef, audio: FieldDef) {
    let front = FieldDef(name: "Front", type: .text)
    let back = FieldDef(name: "Back", type: .text)
    let audio = FieldDef(name: "Audio", type: .audio)

    let recall = CardTemplate(
        name: "Recall",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall)
    )
    let listening = CardTemplate(
        name: "Listening",
        prompt: Side(slots: [
            Slot(source: .field(audio.id), presentation: Presentation(media: .autoplay)),
        ]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .audio, output: .freeResponse, operation: .recognize),
        generateWhen: .fieldNotEmpty(audio.id)
    )

    let type = NoteType(
        name: "Basic",
        fields: [front, back, audio],
        templates: [recall, listening]
    )
    return (type, front, back, audio)
}

@Test func gatedTemplateIsSkippedWhenFieldEmpty() {
    let (type, front, back, _) = makeNoteType()
    let note = Note(noteTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .text("A")),
    ])

    let cards = CardGenerator.cards(for: note, type: type)

    #expect(cards.count == 1)
    #expect(cards.first?.skill.operation == .recall)
}

@Test func gatedTemplateGeneratesWhenFieldPresent() {
    let (type, front, back, audio) = makeNoteType()
    let note = Note(noteTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .text("A")),
        FieldValue(
            fieldID: audio.id,
            value: .media(MediaRef(kind: .audio, url: URL(string: "file:///clip.m4a")!))
        ),
    ])

    let cards = CardGenerator.cards(for: note, type: type)

    #expect(cards.count == 2)
    #expect(cards.allSatisfy { $0.memory.phase == .new })
}

@Test func notePreservesMediaThroughCoding() throws {
    let (type, front, back, audio) = makeNoteType()
    let note = Note(noteTypeID: type.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Q")),
        FieldValue(fieldID: back.id, value: .rich([Span("A", styles: [.bold])])),
        FieldValue(
            fieldID: audio.id,
            value: .media(MediaRef(kind: .audio, url: URL(string: "file:///clip.m4a")!))
        ),
    ])

    let data = try JSONEncoder().encode(note)
    let decoded = try JSONDecoder().decode(Note.self, from: data)

    #expect(decoded == note)
}
