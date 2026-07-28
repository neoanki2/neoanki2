import Foundation

/// The keys behind `@AppStorage`, in one place so a UI test launch can start
/// from the shipped defaults instead of inheriting whatever the previous test
/// left behind. Test databases are already per-launch; preferences are not,
/// because they live in the shared user defaults domain.
enum AppPreferences {
    static let browseShowsAnswerColumn = "browseShowsAnswerColumn"

    private static let all = [browseShowsAnswerColumn]

    /// AppKit autosaves window and split view geometry into this same domain,
    /// under keys derived from the SwiftUI view type. Those outlive a test run,
    /// so a launch would otherwise restore whatever size the last one left —
    /// including a window taller than the screen, which pushes the sidebar and
    /// the bottom controls out of reach. The key names also embed an address
    /// that changes between debug builds, so they accumulate rather than being
    /// reused, and have to be matched by prefix instead of listed.
    private static let autosavePrefixes = [
        "NSWindow Frame",
        "NSSplitView Subview Frames",
    ]

    static func resetForTesting() {
        let defaults = UserDefaults.standard
        for key in all {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys
        where autosavePrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
