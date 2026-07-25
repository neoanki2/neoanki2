import AVKit
import AppKit
import NeoAnkiCore
import SwiftUI

enum MediaPlaybackPolicy {
    static func shouldAutoplay(
        kind: MediaKind,
        behavior: MediaBehavior,
        reduceMotion: Bool
    ) -> Bool {
        !reduceMotion
            && behavior == .autoplay
            && [.audio, .gif, .video].contains(kind)
    }

    static func shouldLoop(kind: MediaKind, behavior: MediaBehavior) -> Bool {
        behavior == .loop && [.audio, .gif, .video].contains(kind)
    }

    static func gifAnimates(
        behavior: MediaBehavior,
        reduceMotion: Bool,
        playOnTapActive: Bool
    ) -> Bool {
        guard !reduceMotion else { return false }
        switch behavior {
        case .autoplay, .loop:
            return true
        case .playOnTap:
            return playOnTapActive
        case .default:
            return false
        }
    }
}

struct AudioPlayerView: View {
    let url: URL
    let behavior: MediaBehavior
    let altText: String?
    let reduceMotion: Bool

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if let player {
                if behavior == .playOnTap {
                    Button {
                        player.play()
                    } label: {
                        Label("Play Audio", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(playButtonAccessibilityLabel)
                } else {
                    VideoPlayer(player: player)
                        .frame(height: 44)
                        .accessibilityLabel(altText ?? "Audio")
                }
            } else {
                ProgressView()
                    .frame(height: 44)
                    .accessibilityLabel("Loading audio")
            }

            if let altText, !altText.isEmpty {
                Text(altText)
                    .font(DesignSystem.Typography.uiCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            configurePlayer()
        }
        .onDisappear {
            player?.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
                self.loopObserver = nil
            }
        }
    }

    private var playButtonAccessibilityLabel: String {
        guard let altText, !altText.isEmpty else { return "Play audio" }
        return "Play audio, \(altText)"
    }

    private func configurePlayer() {
        let avPlayer = AVPlayer(url: url)
        if MediaPlaybackPolicy.shouldLoop(kind: .audio, behavior: behavior) {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }
        }
        player = avPlayer
        if MediaPlaybackPolicy.shouldAutoplay(
            kind: .audio,
            behavior: behavior,
            reduceMotion: reduceMotion
        ) {
            avPlayer.play()
        }
    }
}

struct ImageMediaView: View {
    let url: URL
    let kind: MediaKind
    let behavior: MediaBehavior
    let revealMode: RevealMode
    let isAnswerRevealed: Bool
    let altText: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playOnTapActive = false

    var body: some View {
        Group {
            if shouldHide {
                placeholder
            } else if let image = NSImage(contentsOf: url) {
                if kind == .gif {
                    gifView(image)
                } else {
                    imageView(image)
                }
            } else {
                placeholder
            }
        }
        .accessibilityLabel(accessibilityDescription)
    }

    private var shouldHide: Bool {
        revealMode == .hiddenUntilAnswer && !isAnswerRevealed
    }

    private var placeholder: some View {
        Text(shouldHide ? "Image hidden until answer" : (altText ?? "Image"))
            .font(DesignSystem.Typography.uiSecondary)
            .foregroundStyle(.secondary)
            .frame(minHeight: 80)
    }

    private var accessibilityDescription: String {
        guard isAnswerRevealed || revealMode == .always else {
            return revealMode == .blurred ? "Blurred image" : "Image hidden until answer"
        }
        return altText ?? "Image"
    }

    @ViewBuilder
    private func imageView(_ image: NSImage) -> some View {
        let view = Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: DesignSystem.readingColumnMaxWidth, maxHeight: 320)

        if revealMode == .blurred && !isAnswerRevealed {
            view.blur(radius: 12)
        } else {
            view
        }
    }

    @ViewBuilder
    private func gifView(_ image: NSImage) -> some View {
        let animated = AnimatedGIFView(
            image: image,
            animates: MediaPlaybackPolicy.gifAnimates(
                behavior: behavior,
                reduceMotion: reduceMotion,
                playOnTapActive: playOnTapActive
            )
        )
        .frame(maxWidth: DesignSystem.readingColumnMaxWidth, maxHeight: 320)

        if behavior == .playOnTap {
            Button {
                playOnTapActive.toggle()
            } label: {
                animated
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playOnTapActive ? "Pause animation" : "Play animation")
        } else {
            animated
        }
    }
}

private struct AnimatedGIFView: NSViewRepresentable {
    let image: NSImage
    let animates: Bool

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.animates = animates
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.image = image
        imageView.animates = animates
    }
}

struct VideoPlayerView: View {
    let url: URL
    let behavior: MediaBehavior
    let altText: String?
    let reduceMotion: Bool

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: DesignSystem.readingColumnMaxWidth, maxHeight: 240)
            } else {
                ProgressView()
                    .frame(height: 120)
            }

            if let altText, !altText.isEmpty {
                Text(altText)
                    .font(DesignSystem.Typography.uiCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { configurePlayer() }
        .onDisappear {
            player?.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
                self.loopObserver = nil
            }
        }
        .accessibilityLabel(altText ?? "Video")
    }

    private func configurePlayer() {
        let avPlayer = AVPlayer(url: url)
        if MediaPlaybackPolicy.shouldLoop(kind: .video, behavior: behavior) {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }
        }
        player = avPlayer
        if MediaPlaybackPolicy.shouldAutoplay(
            kind: .video,
            behavior: behavior,
            reduceMotion: reduceMotion
        ) {
            avPlayer.play()
        }
    }
}

struct ResolvedMediaView: View {
    let ref: MediaRef
    let presentation: Presentation
    let isAnswerRevealed: Bool
    let store: MediaStore?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resolvedURL: URL?
    @State private var resolutionError: String?

    var body: some View {
        Group {
            if let resolvedURL {
                mediaBody(url: resolvedURL)
            } else if let resolutionError {
                ErrorBanner(message: resolutionError)
            } else {
                ProgressView()
                    .accessibilityLabel("Loading media")
            }
        }
        .task(id: ref.id) {
            guard let store else { return }
            resolvedURL = nil
            resolutionError = nil
            do {
                resolvedURL = try await store.resolve(ref)
            } catch {
                resolutionError = UserFacingError.message(from: error)
            }
        }
    }

    @ViewBuilder
    private func mediaBody(url: URL) -> some View {
        switch ref.kind {
        case .audio:
            AudioPlayerView(
                url: url,
                behavior: presentation.media,
                altText: ref.altText,
                reduceMotion: reduceMotion
            )
        case .image, .gif:
            ImageMediaView(
                url: url,
                kind: ref.kind,
                behavior: presentation.media,
                revealMode: presentation.reveal,
                isAnswerRevealed: isAnswerRevealed,
                altText: ref.altText
            )
        case .video:
            VideoPlayerView(
                url: url,
                behavior: presentation.media,
                altText: ref.altText,
                reduceMotion: reduceMotion
            )
        }
    }
}
