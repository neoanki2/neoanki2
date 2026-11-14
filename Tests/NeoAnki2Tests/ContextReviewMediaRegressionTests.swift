import AVFoundation
import Foundation
import NeoAnkiCore
import NeoAnkiSharedUI
import Testing
@testable import NeoAnki2

@Suite struct ContextReviewMediaRegressionTests {
    @Test @MainActor func movingBetweenContextCardsReplacesAndStopsThePreviousRecording() throws {
        for kind in [MediaKind.audio, .video] {
            let first = FileManager.default.temporaryDirectory.appendingPathComponent("first-context-\(UUID()).caf")
            let second = FileManager.default.temporaryDirectory.appendingPathComponent("second-context-\(UUID()).caf")
            let playback = ReviewMediaPlayer()
            playback.configure(url: first, kind: kind, behavior: .playOnTap, reduceMotion: false)
            let previous = try #require(playback.player)
            playback.configure(url: second, kind: kind, behavior: .playOnTap, reduceMotion: false)
            let current = try #require(playback.player)
            #expect(current !== previous)
            #expect(previous.currentItem == nil)
            #expect((current.currentItem?.asset as? AVURLAsset)?.url == second)
            playback.reset()
            #expect(playback.player == nil)
            #expect(current.currentItem == nil)
        }
    }

    @Test func listeningQuestionsDoNotExposeTheirTranscriptThroughMediaAccessibility() {
        for kind in [MediaKind.audio, .video] {
            let reference = MediaRef(kind: kind, assetHash: String(repeating: "a", count: 64), fileExtension: "caf", altText: "SECRET TRANSCRIPT")
            #expect(!ReviewMediaAccessibility.description(for: reference, isAnswerRevealed: false).contains("SECRET"))
            #expect(ReviewMediaAccessibility.description(for: reference, isAnswerRevealed: true) == "SECRET TRANSCRIPT")
        }
        let image = MediaRef(kind: .image, assetHash: String(repeating: "b", count: 64), fileExtension: "png", altText: "A red apple")
        #expect(ReviewMediaAccessibility.description(for: image, isAnswerRevealed: false) == "A red apple")
    }
}
