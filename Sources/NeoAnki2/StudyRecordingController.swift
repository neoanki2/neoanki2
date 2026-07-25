import AVFoundation
import Foundation

@MainActor
protocol RecordingPermissionProviding {
    func requestPermission() async -> Bool
}

@MainActor
protocol AudioRecording: AnyObject {
    var url: URL { get }
    func start() -> Bool
    func stop()
}

@MainActor
protocol AudioPlayback: AnyObject {
    func play() -> Bool
    func stop()
}

@MainActor
protocol StudyAudioFactory {
    func makeRecorder(url: URL) throws -> any AudioRecording
    func makePlayer(url: URL, onFinish: @escaping (Bool) -> Void) throws -> any AudioPlayback
}

@MainActor
struct SystemRecordingPermission: RecordingPermissionProviding {
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}

@MainActor
private final class AVRecorderBox: AudioRecording {
    let recorder: AVAudioRecorder
    var url: URL { recorder.url }

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
    }

    func start() -> Bool {
        recorder.prepareToRecord() && recorder.record()
    }

    func stop() {
        recorder.stop()
    }
}

@MainActor
private final class AVPlayerBox: NSObject, AudioPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let onFinish: (Bool) -> Void

    init(url: URL, onFinish: @escaping (Bool) -> Void) throws {
        player = try AVAudioPlayer(contentsOf: url)
        self.onFinish = onFinish
        super.init()
        player.delegate = self
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.onFinish(flag)
        }
    }
}

@MainActor
struct SystemStudyAudioFactory: StudyAudioFactory {
    func makeRecorder(url: URL) throws -> any AudioRecording {
        try AVRecorderBox(url: url)
    }

    func makePlayer(url: URL, onFinish: @escaping (Bool) -> Void) throws -> any AudioPlayback {
        try AVPlayerBox(url: url, onFinish: onFinish)
    }
}

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
    private var recorder: (any AudioRecording)?
    private var player: (any AudioPlayback)?
    private(set) var recordingURL: URL?
    private let permission: any RecordingPermissionProviding
    private let audioFactory: any StudyAudioFactory
    private let temporaryDirectory: URL

    init(
        permission: any RecordingPermissionProviding = SystemRecordingPermission(),
        audioFactory: any StudyAudioFactory = SystemStudyAudioFactory(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.permission = permission
        self.audioFactory = audioFactory
        self.temporaryDirectory = temporaryDirectory
    }

    var hasRecording: Bool {
        recordingURL != nil
    }

    func start() async {
        stopPlayback()
        recorder?.stop()
        recorder = nil
        discardRecording()
        state = .requestingPermission

        guard await permission.requestPermission() else {
            state = .failed("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone.")
            return
        }

        let url = temporaryDirectory
                .appendingPathComponent("neoanki-recording-\(UUID().uuidString).m4a")
        do {
            let recorder = try audioFactory.makeRecorder(url: url)
            guard recorder.start() else {
                throw RecordingError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            state = .recording
        } catch {
            try? FileManager.default.removeItem(at: url)
            discardRecording()
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
            let player = try audioFactory.makePlayer(url: recordingURL) { [weak self] succeeded in
                self?.playbackFinished(successfully: succeeded)
            }
            guard player.play() else { throw RecordingError.couldNotStart }
            self.player = player
            state = .playing
        } catch {
            state = .failed("The recording couldn't be played. Make a new recording and try again.")
        }
    }

    func reset() {
        recorder?.stop()
        stopPlayback()
        recorder = nil
        discardRecording()
        state = .idle
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }

    private func discardRecording() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    func playbackFinished(successfully: Bool) {
        guard state == .playing else { return }
        player = nil
        state = successfully
            ? .recorded
            : .failed("The recording couldn't finish playing. Make a new recording and try again.")
    }
}

private enum RecordingError: Error {
    case couldNotStart
}
