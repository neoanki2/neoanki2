import AVKit
import Foundation
import NeoAnkiApplication
import SwiftUI

public struct LearningTimeMediaActivity: Sendable {
    public var changed: @MainActor @Sendable (UUID, Bool) -> Void
    public init(_ changed: @escaping @MainActor @Sendable (UUID, Bool) -> Void = { _, _ in }) { self.changed = changed }
}
private struct LearningTimeMediaActivityKey: EnvironmentKey {
    static let defaultValue = LearningTimeMediaActivity()
}
public extension EnvironmentValues {
    var learningTimeActivity: LearningTimeMediaActivity {
        get { self[LearningTimeMediaActivityKey.self] }
        set { self[LearningTimeMediaActivityKey.self] = newValue }
    }
}

@MainActor
private final class LearningTimePlaybackObserver {
    private let id = UUID()
    private var observation: NSKeyValueObservation?
    private var generation = 0
    private var activity = LearningTimeMediaActivity()

    func observe(_ player: AVPlayer?, activity: LearningTimeMediaActivity) {
        stop()
        self.activity = activity
        let generation = generation
        observation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.activity.changed(self.id, playing)
            }
        }
    }
    func stop() {
        generation += 1
        observation = nil
        activity.changed(id, false)
    }
}

private struct LearningTimePlaybackModifier: ViewModifier {
    let player: AVPlayer?
    @Environment(\.learningTimeActivity) private var activity
    @State private var observer = LearningTimePlaybackObserver()
    func body(content: Content) -> some View {
        content.onAppear { observer.observe(player, activity: activity) }
            .onChange(of: player) { _, _ in observer.observe(player, activity: activity) }
            .onDisappear { observer.stop() }
    }
}
public extension View {
    func trackingLearningTimePlayback(_ player: AVPlayer?) -> some View {
        modifier(LearningTimePlaybackModifier(player: player))
    }
}

public struct LearningTimePauseButton: View {
    @Bindable var tracker: LearningTimeTracker
    public init(tracker: LearningTimeTracker) { self.tracker = tracker }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(tracker.isPaused ? "Resume Timer" : "Pause Timer",
                   systemImage: tracker.isPaused ? "play" : "pause") {
                if tracker.isManuallyPaused { tracker.togglePause() }
                else if tracker.isIdle { tracker.interaction() }
                else { tracker.togglePause() }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("learningTimePause")
            if let error = tracker.persistenceError { Text(error).font(.caption).foregroundStyle(.secondary) }
            else if tracker.isIdle { Text("Paused · no activity").font(.caption).foregroundStyle(.secondary) }
        }
    }
}


public struct LearningTimeSaveStatusView: View {
    @State private var status = LearningTimeSaveStatus.shared
    public init() {}
    public var body: some View {
        if let message = status.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry Saving") { Task { await LearningTimeTracker.retryPendingSaves() } }
                    .buttonStyle(.borderless)
            }
            .accessibilityIdentifier("learningTimeSaveError")
        } else if status.hasPendingSaves {
            Text("Saving learning time…").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("learningTimeSaving")
        }
    }
}
