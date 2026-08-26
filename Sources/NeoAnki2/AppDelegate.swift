import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Leaves a visible strip below the window even when the Dock is hidden,
    /// so the fixed study action footer can never sit on the display edge.
    private static let windowBottomClearance: CGFloat = 16

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Self.updateDockBadge(dueCount: 0)

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

    static func updateDockBadge(dueCount: Int) {
        NSApp.dockTile.badgeLabel = badgeLabel(forDueCount: dueCount)
    }

    nonisolated static func badgeLabel(forDueCount dueCount: Int) -> String? {
        dueCount > 0 ? String(dueCount) : nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
