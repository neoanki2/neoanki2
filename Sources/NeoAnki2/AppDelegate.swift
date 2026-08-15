import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Self.updateDockBadge(dueCount: 0)
    }

    @MainActor
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
