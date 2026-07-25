import NeoAnkiCore
import Testing

@testable import NeoAnki2

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
