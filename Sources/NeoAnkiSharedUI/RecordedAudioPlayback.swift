import AVFoundation
import Foundation
import Observation

@MainActor
package final class RecordedAudioPlayback: NSObject, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let onFinish: (Bool) -> Void

    package convenience init(url: URL, onFinish: @escaping (Bool) -> Void) throws {
        try self.init(AVAudioPlayer(contentsOf: url), onFinish: onFinish)
    }

    convenience init(data: Data, onFinish: @escaping (Bool) -> Void) throws {
        try self.init(AVAudioPlayer(data: data), onFinish: onFinish)
    }

    private init(_ player: AVAudioPlayer, onFinish: @escaping (Bool) -> Void) {
        self.player = player
        self.onFinish = onFinish
        super.init()
        player.delegate = self
    }

    package func play() -> Bool {
        do { try CardAudioSession.preparePlayback() }
        catch { return false }
        return player.prepareToPlay() && player.play()
    }

    package func stop() {
        player.stop()
    }

    nonisolated package func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish(flag) }
    }
}

@MainActor @Observable
package final class SavedResponsePlayer {
    package private(set) var playingID: UUID?
    package var errorMessage: String?
    private var playback: RecordedAudioPlayback?
    private var request: UUID?
    private var requestedID: UUID?

    package init() {}

    package func toggle(id: UUID, data: () async throws -> Data) async {
        if playingID == id || requestedID == id {
            stop()
            return
        }
        stop()
        let token = UUID()
        request = token
        requestedID = id
        do {
            let bytes = try await data()
            guard request == token, !Task.isCancelled else { return }
            requestedID = nil
            let next = try RecordedAudioPlayback(data: bytes) { [weak self] _ in self?.stop() }
            guard next.play() else { throw CocoaError(.fileReadUnknown) }
            playback = next
            playingID = id
        } catch {
            guard request == token else { return }
            stop()
            errorMessage = error.localizedDescription
        }
    }

    package func stop() {
        request = nil
        requestedID = nil
        playback?.stop()
        playback = nil
        playingID = nil
    }
}
