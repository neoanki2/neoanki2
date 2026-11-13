import AppKit
import NeoAnkiApplication
import NeoAnkiSharedUI
import SwiftUI

/// Observes only the study view's own window; no global input monitoring.
struct StudyWindowActivity: NSViewRepresentable {
    let tracker: LearningTimeTracker
    func makeNSView(context: Context) -> StudyWindowActivityView { StudyWindowActivityView(tracker: tracker) }
    func updateNSView(_ view: StudyWindowActivityView, context: Context) {}
    static func dismantleNSView(_ view: StudyWindowActivityView, coordinator: ()) { view.stop() }
}

final class StudyWindowActivityView: NSView {
    private let tracker: LearningTimeTracker
    private var observers: [NSObjectProtocol] = []
    private var sleepObservers: [NSObjectProtocol] = []
    init(tracker: LearningTimeTracker) { self.tracker = tracker; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        tracker.setVisible(window.isKeyWindow && !window.isMiniaturized)
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tracker.setActive(false) }
        })
        sleepObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tracker.setActive(NSApp.isActive) }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.tracker.setVisible(window.isKeyWindow && !window.isMiniaturized)
                }
            })
        }
    }
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers = []
        tracker.setVisible(false)
    }
}


/// Keep lifecycle and input modifiers separately typed for shipping Xcode versions.
struct StudyLearningTimeModifier: ViewModifier {
    let tracker: LearningTimeTracker
    let isEditing: Bool
    let recordingActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var recordingActivityID = UUID()

    func body(content: Content) -> some View {
        lifecycle(content)
            .onChange(of: isEditing) { _, value in tracker.setEditing(value) }
            .onChange(of: recordingActive) { _, value in
                tracker.setMediaActivity(sourceID: recordingActivityID, isActive: value)
            }
            .simultaneousGesture(TapGesture().onEnded { tracker.interaction() })
            .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in tracker.interaction() })
            .onKeyPress { _ in tracker.interaction(); return KeyPress.Result.ignored }
    }

    private func lifecycle(_ content: Content) -> some View {
        content
            .background(StudyWindowActivity(tracker: tracker).frame(width: 0, height: 0))
            .environment(\.learningTimeActivity, LearningTimeMediaActivity { id, active in
                tracker.setMediaActivity(sourceID: id, isActive: active)
            })
            .onAppear { tracker.setActive(scenePhase == .active) }
            .onDisappear { tracker.setVisible(false) }
            .onChange(of: scenePhase) { _, phase in tracker.setActive(phase == .active) }
    }
}
