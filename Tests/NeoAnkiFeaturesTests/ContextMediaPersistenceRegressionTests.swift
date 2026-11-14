import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
@testable import NeoAnkiFeatures

@Suite struct ContextMediaPersistenceRegressionTests {
    private func item(voiceID: String? = nil) throws -> Item {
        let sentence = "Please take off your coat."
        let metadata = SavedContextMetadata(groupID: UUID(), target: .init(expression: "take off", language: "en", meaning: "remove"),
            spans: [.init(start: 7, length: 8)], provenance: .init(origin: .localMedia, sourceName: "Lesson"),
            clipStart: 2, clipEnd: 4, voiceID: voiceID, speechText: voiceID == nil ? nil : sentence)
        return Item(itemTypeID: ContextExamplePreset.typeID, fields: [
            .init(fieldID: ContextExamplePreset.context.id, value: .rich([Span(sentence)])),
            .init(fieldID: ContextExamplePreset.audio.id, value: .media(.init(kind: .audio, assetHash: String(repeating: "a", count: 64), fileExtension: "caf", altText: sentence))),
            .init(fieldID: ContextExamplePreset.video.id, value: .media(.init(kind: .video, assetHash: String(repeating: "b", count: 64), fileExtension: "mp4", altText: sentence))),
            .init(fieldID: ContextExamplePreset.metadata.id, value: .text(String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)))
        ])
    }
    private func rewrite(_ item: Item) -> Item {
        var edited = item
        edited.fields[0].value = .rich([Span("Please take off your shoes.")])
        return edited
    }

    @Test(arguments: [false, true])
    func rewritingDetachesOriginalAndGeneratedRecordings(generated: Bool) throws {
        let original = try item(voiceID: generated ? "installed-voice" : nil)
        let edited = rewrite(original)
        let result = ContextDerivedContent.invalidatingSpeech(in: edited, original: original, type: ContextExamplePreset.itemType)
        #expect(result.isFieldEmpty(ContextExamplePreset.audio.id))
        #expect(result.isFieldEmpty(ContextExamplePreset.video.id))
        let json = try #require(result.value(for: ContextExamplePreset.metadata.id))
        guard case let .text(value, _) = json else { Issue.record("Missing context metadata"); return }
        let metadata = try JSONDecoder().decode(SavedContextMetadata.self, from: Data(value.utf8))
        #expect(metadata.voiceID == nil && metadata.speechText == nil)
        #expect(metadata.clipStart == nil && metadata.clipEnd == nil)
        #expect(metadata.provenance.originalText == "Please take off your coat.")
    }

    @Test func descriptionOrReferenceIdentityChangesDoNotPretendToReplaceRecording() throws {
        let original = try item(voiceID: "installed-voice")
        var edited = rewrite(original)
        edited.fields[1].value = .media(.init(kind: .audio, assetHash: String(repeating: "a", count: 64), fileExtension: "caf", altText: "A corrected description"))
        let result = ContextDerivedContent.invalidatingSpeech(in: edited, original: original, type: ContextExamplePreset.itemType)
        #expect(result.isFieldEmpty(ContextExamplePreset.audio.id))
    }

    @Test func explicitNewBytesArePreservedAndFormattingEditsKeepRecordings() throws {
        let original = try item(voiceID: "installed-voice")
        var edited = rewrite(original)
        let replacement = MediaRef(kind: .audio, assetHash: String(repeating: "c", count: 64), fileExtension: "caf")
        edited.fields[1].value = .media(replacement)
        let result = ContextDerivedContent.invalidatingSpeech(in: edited, original: original, type: ContextExamplePreset.itemType)
        #expect(result.value(for: ContextExamplePreset.audio.id) == .media(replacement))
        #expect(result.isFieldEmpty(ContextExamplePreset.video.id))
        var formatted = original
        formatted.fields[0].value = .rich([Span("Please take off your coat.", styles: [.bold])])
        #expect(ContextDerivedContent.invalidatingSpeech(in: formatted, original: original, type: ContextExamplePreset.itemType) == formatted)
    }

    @Test(arguments: ["Finished！", "終わった？", "He said, ‘Finished.’", "「終わった。」"])
    func completeQuotedAndCJKSubtitleSentencesRemainSeparate(ending: String) {
        let cues: [ContextTranscriptSegment] = [
            .init(text: ending, start: 0, end: 1), .init(text: "Next sentence.", start: 1.1, end: 2)
        ]
        #expect(ContextSubtitles.joined(cues).count == 2)
    }
}
