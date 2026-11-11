import AppKit
import NeoAnkiApplication
import NeoAnkiCloudSync
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Leaves a visible strip below the window even when the Dock is hidden,
    /// so the fixed study action footer can never sit on the display edge.
    private static let windowBottomClearance: CGFloat = 16
    private var windowPresentations: [ObjectIdentifier: WindowFramePolicy.Presentation] = [:]
    var synchronizeCloudChanges: (@MainActor () async -> Void)?
    private static let cloudPushLogger = Logger(subsystem: "com.neoanki2.app", category: "CloudSyncPush")

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.cloudPushLogger.notice("Registered for remote change notifications")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.cloudPushLogger.error("Remote notification registration failed: \((error as NSError).code, privacy: .public)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard CKSyncEngineTransport.isLibraryNotification(userInfo) else { return }
        Self.cloudPushLogger.notice("Received library change notification")
        Task { await synchronizeCloudChanges?() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Bootstrap may already have published the count. Reapply it after
        // activation instead of erasing it until the next count change.
        Self.dockBadge.reapply()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryDidChange(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowGeometryDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: nil
        )
        // Preserve SwiftUI's NSWindow delegate. AppKit owns the frame throughout
        // Full Screen entry/exit, including resize notifications during animation.
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowFullScreenDidChange(_:)), name: name, object: nil
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil
        )
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        for window in NSApp.windows {
            constrainToVisibleScreen(window)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from notification settings must restore an unchanged count.
        Self.dockBadge.reapply()
    }

    @objc private func windowGeometryDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        constrainToVisibleScreen(window)
    }

    @objc private func windowFullScreenDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let identifier = ObjectIdentifier(window)
        var presentation = windowPresentations[identifier] ?? .init()
        presentation.observe(notification.name)
        if presentation.isTransitioning {
            windowPresentations[identifier] = presentation
        } else {
            windowPresentations.removeValue(forKey: identifier)
        }
        constrainToVisibleScreen(window)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowPresentations.removeValue(forKey: ObjectIdentifier(window))
    }

    private func constrainToVisibleScreen(_ window: NSWindow) {
        guard window.styleMask.contains(.resizable),
              let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return }

        // Do not persist a visible-frame height in maxSize: AppKit also uses
        // that cap when entering Full Screen, before its first resize callback.
        let constrainedFrame = WindowFramePolicy.constrainedFrame(
            window.frame,
            in: visibleFrame,
            bottomClearance: Self.windowBottomClearance,
            isFullScreen: window.styleMask.contains(.fullScreen),
            presentation: windowPresentations[ObjectIdentifier(window)] ?? .init()
        )
        if constrainedFrame != window.frame {
            window.setFrame(constrainedFrame, display: true)
        }
    }

    private static let badgeLogger = Logger(subsystem: "com.neoanki2.app", category: "AppIconBadge")
    private static let dockBadge = DockBadgeController(
        apply: { label in
            guard let app = NSApp else { return }
            app.dockTile.badgeLabel = label
            badgeLogger.info("Dock badge applied: \(app.dockTile.badgeLabel ?? "none", privacy: .public)")
        },
        authorize: MacAppIconBadgeAuthorization.request
    )

    static func updateDockBadge(dueCount: Int) {
        dockBadge.update(dueCount: dueCount)
    }

    nonisolated static func badgeLabel(forDueCount dueCount: Int) -> String? {
        AppIconBadge(dueCount: dueCount).label
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Retains a count published before AppKit finishes launching.
@MainActor
final class DockBadgeController {
    private var badge = AppIconBadge(dueCount: 0)
    private let apply: (String?) -> Void
    private let authorize: (@MainActor () async throws -> Bool)?
    private var isAuthorized = false
    private(set) var authorizationTask: Task<Void, Never>?

    init(
        apply: @escaping (String?) -> Void,
        authorize: (@MainActor () async throws -> Bool)? = nil
    ) {
        self.apply = apply
        self.authorize = authorize
    }

    func update(dueCount: Int) {
        badge = AppIconBadge(dueCount: dueCount)
        reapply()
    }

    func reapply() {
        apply(badge.label)
        guard badge.count > 0, !isAuthorized, authorizationTask == nil,
              let authorize else { return }
        authorizationTask = Task {
            defer { authorizationTask = nil }
            do {
                isAuthorized = try await authorize()
                if isAuthorized {
                    // Permission can finish after studying or another refresh.
                    // Always use the latest count rather than the requested one.
                    apply(badge.label)
                }
            } catch {
                // Retry on the next activation or count update, preserving the
                // library count while notification services are unavailable.
            }
        }
    }
}

enum WindowFramePolicy {
    struct Presentation {
        private(set) var isTransitioning = false

        mutating func observe(_ notification: Notification.Name) {
            switch notification {
            case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
                isTransitioning = true
            case NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification:
                isTransitioning = false
            default:
                break
            }
        }
    }

    static func maximumHeight(in visibleFrame: NSRect, bottomClearance: CGFloat) -> CGFloat {
        max(1, visibleFrame.height - max(0, bottomClearance))
    }

    static func constrainedFrame(
        _ frame: NSRect,
        in visibleFrame: NSRect,
        bottomClearance: CGFloat,
        isFullScreen: Bool = false,
        presentation: Presentation = .init()
    ) -> NSRect {
        guard !isFullScreen, !presentation.isTransitioning,
              visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        var constrained = frame
        constrained.size.height = min(
            max(1, frame.height),
            maximumHeight(in: visibleFrame, bottomClearance: bottomClearance)
        )

        let minimumY = visibleFrame.minY + max(0, bottomClearance)
        let maximumY = visibleFrame.maxY - constrained.height
        constrained.origin.y = min(max(frame.minY, minimumY), maximumY)
        return constrained
    }
}
