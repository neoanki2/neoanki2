import Foundation
import NeoAnkiSharedUI

/// The keys behind `@AppStorage`, in one place so a UI test launch can start
/// from the shipped defaults instead of inheriting whatever the previous test
/// left behind. Test databases are already per-launch; preferences are not,
/// because they live in the shared user defaults domain.
enum AppPreferences {
    static let browseShowsAnswerColumn = "browseShowsAnswerColumn"
    static let localAPIEnabled = "localAPIEnabled"
    static let localAPIPort = "localAPIPort"
    static let cloudSyncEnabled = "cloudSyncEnabled"

    private static let all = [
        browseShowsAnswerColumn,
        localAPIEnabled,
        localAPIPort,
        cloudSyncEnabled,
        StudyPreferences.usesPassFailGrades,
    ]

    static func resetForTesting() {
        for key in all {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
