import AppKit
import NeoAnkiApplication
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Leaves a visible strip below the window even when the Dock is hidden,
    /// so the fixed study action footer can never sit on the display edge.
    private static let windowBottomClearance: CGFloat = 16

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

    private func constrainToVisibleScreen(_ window: NSWindow) {
        guard window.styleMask.contains(.resizable),
              let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return }

        let maximumHeight = WindowFramePolicy.maximumHeight(
            in: visibleFrame,
            bottomClearance: Self.windowBottomClearance
        )
        window.maxSize = NSSize(width: window.maxSize.width, height: maximumHeight)

        let constrainedFrame = WindowFramePolicy.constrainedFrame(
            window.frame,
            in: visibleFrame,
            bottomClearance: Self.windowBottomClearance
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
    static func maximumHeight(in visibleFrame: NSRect, bottomClearance: CGFloat) -> CGFloat {
        max(1, visibleFrame.height - max(0, bottomClearance))
    }

    static func constrainedFrame(
        _ frame: NSRect,
        in visibleFrame: NSRect,
        bottomClearance: CGFloat
    ) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

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
