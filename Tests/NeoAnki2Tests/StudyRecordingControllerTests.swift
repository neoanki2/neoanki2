import Foundation
import Testing

@testable import NeoAnki2

@MainActor
private struct PermissionStub: RecordingPermissionProviding {
    let granted: Bool
    func requestPermission() async -> Bool { granted }
}

@MainActor
private final class RecorderStub: AudioRecording {
    let url: URL
    let starts: Bool
    private(set) var stopped = false

    init(url: URL, starts: Bool) {
        self.url = url
        self.starts = starts
    }

    func start() -> Bool { starts }
    func stop() { stopped = true }
}

@MainActor
private final class PlayerStub: AudioPlayback {
    let starts: Bool
    private(set) var stopped = false

    init(starts: Bool) {
        self.starts = starts
    }

    func play() -> Bool { starts }
    func stop() { stopped = true }
}

@MainActor
private final class AudioFactoryStub: StudyAudioFactory {
    var recorderStarts = true
    var playerStarts = true
    var onFinish: ((Bool) -> Void)?

    func makeRecorder(url: URL) throws -> any AudioRecording {
        RecorderStub(url: url, starts: recorderStarts)
    }

    func makePlayer(url: URL, onFinish: @escaping (Bool) -> Void) throws -> any AudioPlayback {
        self.onFinish = onFinish
        return PlayerStub(starts: playerStarts)
    }
}

@Test @MainActor func recordingPermissionDenialFailsCalmly() async {
    let controller = StudyRecordingController(
        permission: PermissionStub(granted: false),
        audioFactory: AudioFactoryStub()
    )

    await controller.start()

    guard case let .failed(message) = controller.state else {
        Issue.record("Expected permission failure.")
        return
    }
    #expect(message.contains("Microphone access is off"))
    #expect(controller.hasRecording == false)
}

@Test @MainActor func recordingStartFailureDoesNotKeepPhantomRecording() async {
    let factory = AudioFactoryStub()
    factory.recorderStarts = false
    let controller = StudyRecordingController(
        permission: PermissionStub(granted: true),
        audioFactory: factory
    )

    await controller.start()

    #expect(controller.hasRecording == false)
    guard case .failed = controller.state else {
        Issue.record("Expected recording failure.")
        return
    }
}

@Test @MainActor func playbackCompletionTransitionsNaturallyToRecorded() async {
    let factory = AudioFactoryStub()
    let controller = StudyRecordingController(
        permission: PermissionStub(granted: true),
        audioFactory: factory
    )
    await controller.start()
    controller.stop()
    controller.togglePlayback()
    #expect(controller.state == .playing)

    factory.onFinish?(true)

    #expect(controller.state == .recorded)
}

@Test @MainActor func playbackFailureTransitionsToActionableFailure() async {
    let factory = AudioFactoryStub()
    let controller = StudyRecordingController(
        permission: PermissionStub(granted: true),
        audioFactory: factory
    )
    await controller.start()
    controller.stop()
    controller.togglePlayback()

    factory.onFinish?(false)

    guard case let .failed(message) = controller.state else {
        Issue.record("Expected playback failure.")
        return
    }
    #expect(message.contains("finish playing"))
}
