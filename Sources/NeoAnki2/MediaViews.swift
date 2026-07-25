import AVKit
import NeoAnkiCore
import SwiftUI

struct AudioPlayerView: View {
    let url: URL
    let behavior: MediaBehavior
    let altText: String?

    @State private var player: AVPlayer?

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
        }
    }

    private var playButtonAccessibilityLabel: String {
        guard let altText, !altText.isEmpty else { return "Play audio" }
        return "Play audio, \(altText)"
    }

    private func configurePlayer() {
        let avPlayer = AVPlayer(url: url)
        if behavior == .loop {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }
        }
        player = avPlayer
        if behavior == .autoplay {
            avPlayer.play()
        }
    }
}

struct ImageMediaView: View {
    let url: URL
    let behavior: MediaBehavior
    let revealMode: RevealMode
    let isAnswerRevealed: Bool
    let altText: String?

    var body: some View {
        Group {
            if shouldHide {
                placeholder
            } else if let image = NSImage(contentsOf: url) {
                imageView(image)
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
}

struct VideoPlayerView: View {
    let url: URL
    let behavior: MediaBehavior
    let altText: String?

    @State private var player: AVPlayer?

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
        .onDisappear { player?.pause() }
        .accessibilityLabel(altText ?? "Video")
    }

    private func configurePlayer() {
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        if behavior == .autoplay {
            avPlayer.play()
        }
    }
}

struct ResolvedMediaView: View {
    let ref: MediaRef
    let presentation: Presentation
    let isAnswerRevealed: Bool
    let store: MediaStore?

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
            AudioPlayerView(url: url, behavior: presentation.media, altText: ref.altText)
        case .image, .gif:
            ImageMediaView(
                url: url,
                behavior: presentation.media,
                revealMode: presentation.reveal,
                isAnswerRevealed: isAnswerRevealed,
                altText: ref.altText
            )
        case .video:
            VideoPlayerView(url: url, behavior: presentation.media, altText: ref.altText)
        }
    }
}
