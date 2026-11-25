import AVFoundation
import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2
@testable import NeoAnkiSharedUI

@Test func academyAudioFollowsRevealAndKeepsWordBeforeSentence() {
    let word = FieldDef(name: "Word audio", type: .audio)
    let sentence = FieldDef(name: "Sentence audio", type: .audio)
    let wordAudio = MediaRef(kind: .audio, assetHash: String(repeating: "a", count: 64), fileExtension: "m4a")
    let sentenceAudio = MediaRef(kind: .audio, assetHash: String(repeating: "b", count: 64), fileExtension: "m4a")
    let type = ItemType(name: "Japanese Academy Vocabulary", fields: [word, sentence], templates: [])
    let item = Item(itemTypeID: type.id, fields: [
        .init(fieldID: word.id, value: .media(wordAudio)),
        .init(fieldID: sentence.id, value: .media(sentenceAudio)),
    ], tags: ["migaku:vocabulary-fixture"])
    let template = Template(name: "Word and sentence", layout: .focus, components: [
        .init(region: .supporting, purpose: .supporting, source: .field(word.id),
              presentation: .init(reveal: .hiddenUntilAnswer)),
        .init(region: .supporting, purpose: .supporting, source: .field(sentence.id),
              presentation: .init(reveal: .hiddenUntilAnswer)),
    ], interaction: .reveal, skill: Skill(input: .text, output: .text, operation: .recall))
    var due = DueCard(card: Card(itemID: item.id, templateID: template.id, skill: template.skill),
                      item: item, itemType: type, template: template)

    #expect(AcademyCardAudio.clips(for: due, answerRevealed: false).isEmpty)
    #expect(AcademyCardAudio.clips(for: due, answerRevealed: true) == [wordAudio, sentenceAudio])

    due.template.components[0].presentation.reveal = .always
    #expect(AcademyCardAudio.clips(for: due, answerRevealed: false) == [wordAudio])
    due.template.components[1].presentation.media = .playOnTap
    #expect(AcademyCardAudio.clips(for: due, answerRevealed: true) == [wordAudio])

    due.itemType.name = "Other Vocabulary"
    #expect(AcademyCardAudio.clips(for: due, answerRevealed: true).isEmpty)
}

@Test @MainActor func academyAudioQueuesEachClipOncePerAttemptAndStopsOnCardExit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("academy-audio-\(UUID())")
    let store = try MediaStore(rootDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let playback = AcademyCardAudioQueue(autoplay: false)
    playback.player.isMuted = true
    defer { playback.reset() }

    func silence(name: String, frames: AVAudioFrameCount) throws -> URL {
        let url = root.appendingPathComponent(name + ".caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    let word = try await store.ingest(url: silence(name: "word", frames: 80_000), kind: .audio)
    let sentence = try await store.ingest(url: silence(name: "sentence", frames: 88_000), kind: .audio)
    let wordURL = try await store.resolve(word)
    let sentenceURL = try await store.resolve(sentence)

    playback.updateReveal(true)
    await playback.enqueue([word, sentence], from: store)
    await playback.enqueue([word, sentence], from: store)
    #expect(playback.player.items().compactMap { ($0.asset as? AVURLAsset)?.url } == [wordURL, sentenceURL])

    try playback.replay(sentenceURL, replacing: [word, sentence])
    #expect(playback.player.items().compactMap { ($0.asset as? AVURLAsset)?.url } == [sentenceURL])

    playback.updateReveal(false)
    #expect(playback.player.items().isEmpty)
    playback.updateReveal(true)
    await playback.enqueue([word, sentence], from: store)
    #expect(playback.player.items().compactMap { ($0.asset as? AVURLAsset)?.url } == [wordURL, sentenceURL])

    playback.reset()
    #expect(playback.player.items().isEmpty)
    #expect(playback.player.rate == 0)
}

@Test func reduceMotionSuppressesTimeBasedMediaAutoplay() {
    #expect(
        MediaPlaybackPolicy.shouldAutoplay(
            kind: .audio,
            behavior: .autoplay,
            reduceMotion: false
        )
    )
    #expect(
        !MediaPlaybackPolicy.shouldAutoplay(
            kind: .audio,
            behavior: .autoplay,
            reduceMotion: true
        )
    )
    #expect(
        !MediaPlaybackPolicy.shouldAutoplay(
            kind: .video,
            behavior: .autoplay,
            reduceMotion: true
        )
    )
    #expect(
        !MediaPlaybackPolicy.shouldAutoplay(
            kind: .video,
            behavior: .playOnTap,
            reduceMotion: false
        )
    )
}

@Test func authoredMediaBehaviorHasExplicitPlaybackSemantics() {
    #expect(MediaPlaybackPolicy.shouldLoop(kind: .video, behavior: .loop))
    #expect(MediaPlaybackPolicy.shouldLoop(kind: .audio, behavior: .loop))
    #expect(!MediaPlaybackPolicy.shouldLoop(kind: .image, behavior: .loop))

    #expect(
        MediaPlaybackPolicy.gifAnimates(
            behavior: .autoplay,
            reduceMotion: false,
            playOnTapActive: false
        )
    )
    #expect(
        !MediaPlaybackPolicy.gifAnimates(
            behavior: .autoplay,
            reduceMotion: true,
            playOnTapActive: false
        )
    )
    #expect(
        MediaPlaybackPolicy.gifAnimates(
            behavior: .playOnTap,
            reduceMotion: false,
            playOnTapActive: true
        )
    )
    #expect(
        !MediaPlaybackPolicy.gifAnimates(
            behavior: .default,
            reduceMotion: false,
            playOnTapActive: true
        )
    )
}

@Test func mediaBehaviorChoicesExcludeMeaninglessStaticOptions() {
    #expect(MediaBehavior.supported(for: nil) == [.default])
    #expect(MediaBehavior.supported(for: .image) == [.default])
    #expect(MediaBehavior.supported(for: .audio) == MediaBehavior.allCases)
    #expect(MediaBehavior.supported(for: .gif) == MediaBehavior.allCases)
    #expect(MediaBehavior.supported(for: .video) == MediaBehavior.allCases)
}

@Test func itemTypeValidationRejectsMeaninglessMediaBehavior() {
    let front = FieldDef(name: "Front", type: .text)
    let back = FieldDef(name: "Back", type: .text)
    let template = Template(
        name: "Invalid playback",
        prompt: Side(slots: [
            Slot(
                source: .field(front.id),
                presentation: Presentation(media: .autoplay)
            ),
        ]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recall)
    )
    let itemType = ItemType(
        name: "Invalid",
        fields: [front, back],
        templates: [template]
    )

    #expect(throws: DatabaseError.self) {
        try ItemTypeValidation.validate(itemType)
    }
}
