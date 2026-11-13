import AppKit
import NeoAnkiApplication
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
