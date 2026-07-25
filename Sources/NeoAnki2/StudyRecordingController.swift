import AVFoundation
import Foundation

@MainActor
@Observable
final class StudyRecordingController {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case recorded
        case playing
        case failed(String)
    }

    private(set) var state: State = .idle
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private(set) var recordingURL: URL?

    var hasRecording: Bool {
        recordingURL != nil
    }

    func start() async {
        stopPlayback()
        state = .requestingPermission

        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }

        guard granted else {
            state = .failed("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone.")
            return
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("neoanki-recording-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord(), recorder.record() else {
                throw RecordingError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            state = .recording
        } catch {
            state = .failed("Recording couldn't start. Check your microphone and try again.")
        }
    }

    func stop() {
        guard state == .recording else { return }
        recorder?.stop()
        recorder = nil
        state = recordingURL == nil ? .failed("No recording was saved. Try again.") : .recorded
    }

    func togglePlayback() {
        if state == .playing {
            stopPlayback()
            state = .recorded
            return
        }
        guard let recordingURL else {
            state = .failed("Make a recording before playing it.")
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: recordingURL)
            guard player?.play() == true else { throw RecordingError.couldNotStart }
            state = .playing
        } catch {
            state = .failed("The recording couldn't be played. Make a new recording and try again.")
        }
    }

    func reset() {
        recorder?.stop()
        stopPlayback()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recorder = nil
        recordingURL = nil
        state = .idle
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }
}

private enum RecordingError: Error {
    case couldNotStart
}
