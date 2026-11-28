import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
@testable import NeoAnki2

@Suite @MainActor struct ItemEditingRoundTripTests {
    @Test(arguments: ["none", "clear-optional"] + FieldType.allCases.map(\.rawValue))
    func editingAnyFieldPreservesEveryOtherContentKind(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("all-fields-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
        let media = try #require(await store.media)
        let fields = FieldType.allCases.map { FieldDef(name: $0.rawValue, type: $0, isRequired: $0 == .text) }
        let text = try #require(fields.first { $0.type == .text })
        let rich = try #require(fields.first { $0.type == .richText })
        let type = ItemType(name: "Every editable field", fields: fields, templates: [
            .init(name: "Recall", prompt: .init(slots: [.init(source: .field(text.id))]),
                  answer: .init(slots: [.init(source: .field(rich.id))]), interaction: .reveal,
                  skill: .init(input: .text, output: .text, operation: .recall)),
        ])
        _ = try await store.createItemType(type)
        var references: [MediaKind: MediaRef] = [:]
        let fixtures: [(MediaKind, String, Data)] = [
            (.image, "png", Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + Array(repeating: 0, count: 12))),
            (.audio, "caf", Data("caff-test-audio".utf8)),
            (.gif, "gif", Data("GIF89a-test-gif".utf8)),
            (.video, "mp4", Data([0, 0, 0, 20]) + Data("ftypisom".utf8)),
        ]
        for (kind, ext, bytes) in fixtures {
            var ref = try await media.ingest(data: bytes, kind: kind, fileExtension: ext)
            ref.altText = "Original description"
            references[kind] = ref
        }
        let imageRef = try #require(references[.image])
        var values: [FieldValue] = []
        for field in fields {
            let value: ContentValue
            switch field.type {
            case .text: value = .text("Який міст?", lang: "uk")
            case .richText: value = .rich([Span("міст Метро", styles: [.bold], textSize: .small), Span(" Source", link: "https://example.com")])
            case .number: value = .number(42.5)
            case .checkbox: value = .checkbox(true)
            case .cloze: value = .cloze("Alpha Beta", blanks: [.init(group: 4, start: 6, length: 4, hint: "Answer")])
            case .imageOcclusion: value = .imageOcclusion(.init(image: imageRef, masks: [.init(group: 1, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), answerText: "Bridge")], nextGroup: 2))
            case .studyExercise:
                value = .studyExercise(.init(mode: .rewrite, prompt: "Write in the past tense.", answers: [["I walked."]]))
            case .image, .audio, .gif, .video:
                let kind = try #require(field.type.mediaKind)
                value = .media(try #require(references[kind]))
            }
            values.append(.init(fieldID: field.id, value: value))
        }
        let deck = try await store.createDeck(Deck(name: "Keep this deck"))
        let item = Item(itemTypeID: type.id, fields: values, tags: ["Keep", "Україна"], deckID: deck.id)
        _ = try await store.createItem(item)
        let initialCards = try await store.cards()
        var snapshot = ItemEditorState.hydrated(from: item, itemType: type)
        var expected = item
        if change == "clear-optional" {
            snapshot = ItemEditorState.empty(for: type)
            snapshot.fieldSpans[text.id] = [Span("Який міст?")]
            expected.fields.removeAll { $0.fieldID != text.id }
        } else if let field = fields.first(where: { $0.type.rawValue == change }),
                  let index = expected.fields.firstIndex(where: { $0.fieldID == field.id }) {
            switch field.type {
            case .text:
                snapshot.fieldSpans[field.id] = [Span("Виправлено")]
                expected.fields[index].value = .text("Виправлено", lang: "uk")
            case .richText:
                let spans = [Span("Corrected", styles: [.italic], textColor: .blue)]
                snapshot.fieldSpans[field.id] = spans
                expected.fields[index].value = .rich(spans)
            case .checkbox:
                snapshot.fieldText[field.id] = "false"
                expected.fields[index].value = .checkbox(false)
            case .number:
                snapshot.fieldText[field.id] = "-7.5"
                expected.fields[index].value = .number(-7.5)
            case .cloze:
                snapshot.fieldText[field.id] = "Alpha Gamma"
                let blanks = [ClozeSpan(group: 4, start: 6, length: 5, hint: "Corrected")]
                snapshot.fieldClozeBlanks[field.id] = blanks
                expected.fields[index].value = .cloze("Alpha Gamma", blanks: blanks)
            case .imageOcclusion:
                var content = try #require(snapshot.fieldOcclusions[field.id])
                content.mode = .hideOneRevealOne
                content.masks[0].answerText = "Corrected"
                snapshot.fieldOcclusions[field.id] = content
                expected.fields[index].value = .imageOcclusion(content)
            case .studyExercise:
                let exercise = StudyExercise(mode: .rewrite, prompt: "Write in the future tense.", answers: [["I will walk."]])
                snapshot.fieldText[field.id] = exercise.editorText
                expected.fields[index].value = .studyExercise(exercise)
            case .image, .audio, .gif, .video:
                snapshot.fieldMediaAltText[field.id] = "Corrected description"
                var ref = try #require(snapshot.fieldMedia[field.id])
                ref.altText = "Corrected description"
                expected.fields[index].value = .media(ref)
            }
        }
        let model = ItemsModel(store: store, mediaStore: media)
        await model.load()
        #expect(await model.updateItem(id: item.id, fieldSpans: snapshot.fieldSpans,
            fieldText: snapshot.fieldText, fieldMedia: snapshot.fieldMedia,
            fieldMediaAltText: snapshot.fieldMediaAltText, fieldClozeBlanks: snapshot.fieldClozeBlanks,
            fieldOcclusions: snapshot.fieldOcclusions))
        #expect(model.errorMessage == nil)
        let reopened = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.fetchItem(id: item.id)?.item == expected)
        #expect(try await reopened.cards() == initialCards)
        #expect(model.items.first?.id == item.id)
    }
}
