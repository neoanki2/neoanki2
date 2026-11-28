import AVFoundation
import Combine
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

package enum CardAudioSession {
    package static func preparePlayback() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // The study recorder already configures a playback-capable route.
        if session.category != .playAndRecord && session.category != .playback {
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        }
        try session.setActive(true)
        #endif
    }
}

package struct AudioPlaybackLabel: View {
    package enum ActiveAction {
        case pause, stop
    }

    let isPlaying: Bool
    let activeAction: ActiveAction
    let playTitle: String
    let activeTitle: String

    package init(isPlaying: Bool, activeAction: ActiveAction, playTitle: String = "Play Audio",
                 activeTitle: String? = nil) {
        self.isPlaying = isPlaying
        self.activeAction = activeAction
        self.playTitle = playTitle
        self.activeTitle = activeTitle ?? (activeAction == .pause ? "Pause Audio" : "Stop Playback")
    }

    package var body: some View {
        Label(isPlaying ? activeTitle : playTitle,
              systemImage: isPlaying ? (activeAction == .pause ? "pause.fill" : "stop.fill") : "play.fill")
    }
}

package struct CardAudioButton: View {
    private let description: String
    private let pause: (() -> Void)?
    private let play: () throws -> Void
    @State private var playbackFailed = false

    package init(description: String, pause: (() -> Void)? = nil, play: @escaping () throws -> Void) {
        self.description = description
        self.pause = pause
        self.play = play
    }

    package var body: some View {
        let action = pause == nil ? "Play audio" : "Pause audio"
        VStack(spacing: 4) {
            Button {
                do {
                    if let pause {
                        pause()
                    } else {
                        try play()
                    }
                    playbackFailed = false
                } catch {
                    playbackFailed = true
                }
            } label: {
                AudioPlaybackLabel(isPlaying: pause != nil, activeAction: .pause)
                    #if os(iOS)
                    .neoAnkiTouchTarget()
                    #endif
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(description == "Audio" ? action : "\(action), \(description)")
            if playbackFailed {
                Text("Couldn't play audio. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shared audio surface for card media, previews, and lesson attachments.
package struct AudioClipView: View {
    let url: URL
    let behavior: MediaBehavior
    let description: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.academyCardAudioReplay) private var academyReplay

    package init(url: URL, behavior: MediaBehavior, description: String) {
        self.url = url
        self.behavior = behavior
        self.description = description
    }

    package var body: some View {
        if let academyReplay, behavior != .loop {
            CardAudioButton(description: description) { try academyReplay(url) }
        } else {
            StandaloneAudioClipView(url: url, behavior: behavior, description: description, reduceMotion: reduceMotion)
        }
    }
}

private struct StandaloneAudioClipView: View {
    let url: URL
    let behavior: MediaBehavior
    let description: String
    let reduceMotion: Bool
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var reachedEnd = false
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var isScrubbing = false

    private struct Configuration: Equatable {
        let url: URL
        let behavior: MediaBehavior
        let reduceMotion: Bool
    }

    var body: some View {
        Group {
            if let player, let item = player.currentItem {
                HStack(spacing: 12) {
                    CardAudioButton(description: description, pause: isPlaying ? { player.pause() } : nil) {
                        try CardAudioSession.preparePlayback()
                        if reachedEnd {
                            player.seek(to: .zero)
                            reachedEnd = false
                        }
                        player.play()
                    }
                    if behavior != .playOnTap {
                        Slider(value: $position, in: 0...max(1, duration), onEditingChanged: { editing in
                            isScrubbing = editing
                            if !editing {
                                reachedEnd = false
                                player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                            }
                        })
                        .disabled(duration <= 0)
                        .accessibilityLabel("Playback position")
                    }
                }
                .onReceive(player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)) { status in
                    isPlaying = status != .paused
                }
                .onReceive(item.publisher(for: \.status).receive(on: RunLoop.main)) { _ in
                    let length = item.duration.seconds
                    if length.isFinite, length > 0 { duration = length }
                }
                .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                    .receive(on: RunLoop.main)) { _ in
                    if behavior == .loop {
                        player.seek(to: .zero)
                        player.play()
                    } else {
                        reachedEnd = true
                    }
                }
            } else {
                ProgressView().accessibilityLabel("Loading audio")
            }
        }
        .trackingLearningTimePlayback(player)
        .task(id: Configuration(url: url, behavior: behavior, reduceMotion: reduceMotion)) {
            reset()
            let next = AVPlayer(url: url)
            player = next
            timeObserver = next.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { time in
                MainActor.assumeIsolated {
                    guard player === next, !isScrubbing, time.seconds.isFinite else { return }
                    position = min(time.seconds, duration)
                }
            }
            if !reduceMotion, behavior == .autoplay || behavior == .loop {
                if (try? CardAudioSession.preparePlayback()) != nil { next.play() }
            }
        }
        .onDisappear { reset() }
    }

    private func reset() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        reachedEnd = false
        isScrubbing = false
        position = 0
        duration = 0
    }
}

package enum AcademyCardAudio {
    package static func clips(for card: DueCard, answerRevealed: Bool) -> [MediaRef] {
        guard CourseStudyPath.isAcademyVocabulary(card) else { return [] }
        let components = card.studyComponents
        let descriptor = CardWireframeDescriptor.descriptor(for: card.template.layout)
        let visible = descriptor.renderedComponents(from: components, answerRevealed: answerRevealed)
        let collapsedExplanationIDs: Set<UUID> = if [.type, .choose, .arrange].contains(card.template.interaction) {
            Set(StudyAnswerReviewProjection(components: components).explanation.map(\.id))
        } else {
            []
        }
        var hashes: Set<String> = []
        return visible.compactMap { rendered in
            let component = rendered.component
            guard case let .media(ref) = component.value, ref.kind == .audio,
                  component.presentation.media == .default || component.presentation.media == .autoplay,
                  !collapsedExplanationIDs.contains(component.id),
                  ContentVisibilityPolicy.decision(
                      for: component.value,
                      revealMode: component.presentation.reveal,
                      isAnswerRevealed: answerRevealed
                  ).shouldResolveMedia,
                  hashes.insert(ref.assetHash).inserted
            else { return nil }
            return ref
        }
    }
}

private struct AcademyCardAudioReplayKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (URL) throws -> Void)? = nil
}

package extension EnvironmentValues {
    var academyCardAudioReplay: (@MainActor @Sendable (URL) throws -> Void)? {
        get { self[AcademyCardAudioReplayKey.self] }
        set { self[AcademyCardAudioReplayKey.self] = newValue }
    }
}

package extension View {
    @ViewBuilder
    func playingAcademyCardAudio(
        _ card: DueCard,
        answerRevealed: Bool,
        store: MediaStore?,
        allowsAutoplay: Bool
    ) -> some View {
        if CourseStudyPath.isAcademyVocabulary(card) {
            modifier(AcademyCardAudioModifier(
                clips: AcademyCardAudio.clips(for: card, answerRevealed: answerRevealed),
                store: store,
                answerRevealed: answerRevealed,
                allowsAutoplay: allowsAutoplay
            ))
        } else {
            self
        }
    }
}

private struct AcademyCardAudioModifier: ViewModifier {
    let clips: [MediaRef]
    let store: MediaStore?
    let answerRevealed: Bool
    let allowsAutoplay: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.neoAnkiAccessibilityReduceMotionOverride) private var reduceMotionOverride
    @State private var playback = AcademyCardAudioQueue()

    func body(content: Content) -> some View {
        let autoplay = allowsAutoplay && !(reduceMotionOverride ?? systemReduceMotion)
        content
            .environment(\.academyCardAudioReplay) { url in
                try playback.replay(url, replacing: clips)
            }
            .trackingLearningTimePlayback(playback.player)
            .task(id: PlaybackRequest(clips: autoplay ? clips : nil, answerRevealed: answerRevealed)) {
                guard !Task.isCancelled else { return }
                playback.updateReveal(answerRevealed)
                if autoplay, let store {
                    await playback.enqueue(clips, from: store)
                } else {
                    playback.stop()
                }
            }
            .onDisappear { playback.reset() }
    }

    private struct PlaybackRequest: Equatable {
        let clips: [MediaRef]?
        let answerRevealed: Bool
    }
}

/// One queue per study card keeps clips in order and survives card layout changes.
@MainActor final class AcademyCardAudioQueue {
    let player = AVQueuePlayer()
    private let autoplay: Bool
    private var alreadyQueued: Set<String> = []
    private var answerWasRevealed = false

    init(autoplay: Bool = true) {
        self.autoplay = autoplay
    }

    func updateReveal(_ answerRevealed: Bool) {
        // A failed card can immediately return with the same card ID.
        if answerWasRevealed && !answerRevealed { reset() }
        answerWasRevealed = answerRevealed
    }

    func enqueue(_ references: [MediaRef], from store: MediaStore) async {
        var missing: [MediaRef] = []
        for ref in references where !alreadyQueued.contains(ref.assetHash) {
            guard !Task.isCancelled else { return }
            if let url = try? await store.resolve(ref) {
                append(url, for: ref)
            } else {
                missing.append(ref)
            }
        }
        // Play locally available clips while waiting for any other attachments
        // to sync. A late clip is appended as soon as it can be played.
        await withTaskGroup(of: (MediaRef, URL)?.self) { group in
            for ref in missing {
                group.addTask {
                    guard let url = try? await store.resolveSynchronized(ref, onWaiting: {}) else { return nil }
                    return (ref, url)
                }
            }
            for await result in group {
                guard let (ref, url) = result else { continue }
                append(url, for: ref)
            }
        }
    }

    private func append(_ url: URL, for ref: MediaRef) {
        guard !Task.isCancelled, !alreadyQueued.contains(ref.assetHash) else { return }
        let startsPlayback = player.currentItem == nil
        if startsPlayback && autoplay {
            do { try CardAudioSession.preparePlayback() }
            catch { return }
        }
        player.insert(AVPlayerItem(url: url), after: nil)
        alreadyQueued.insert(ref.assetHash)
        if startsPlayback && autoplay { player.play() }
    }

    func replay(_ url: URL, replacing references: [MediaRef]) throws {
        if autoplay { try CardAudioSession.preparePlayback() }
        alreadyQueued.formUnion(references.map(\.assetHash))
        stop()
        player.insert(AVPlayerItem(url: url), after: nil)
        if autoplay { player.play() }
    }

    func stop() {
        player.pause()
        player.removeAllItems()
    }

    func reset() {
        stop()
        alreadyQueued.removeAll()
        answerWasRevealed = false
    }
}
