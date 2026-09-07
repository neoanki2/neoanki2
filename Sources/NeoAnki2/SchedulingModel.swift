import Foundation
import NeoAnkiApplication
import NeoAnkiCore

@MainActor
@Observable
final class SchedulingModel {
    private(set) var rolloverMinutes = StudyDay.defaultRolloverMinutes
    private(set) var isLoadingSettings = false
    private(set) var isSavingSettings = false
    var isShowingSettings = false
    var settingsError: String?

    private let library: any LibraryScheduling

    init(library: any LibraryScheduling) {
        self.library = library
    }

    func openSettings() {
        isShowingSettings = true
        Task { await loadSettings() }
    }

    func loadSettings() async {
        isLoadingSettings = true
        settingsError = nil
        defer { isLoadingSettings = false }
        do {
            rolloverMinutes = try await library.studyDayRolloverMinutes()
        } catch {
            settingsError = UserFacingError.message(from: error)
        }
    }

    func saveRolloverMinutes(_ minutes: Int) async -> Bool {
        guard !isSavingSettings else { return false }
        isSavingSettings = true
        settingsError = nil
        defer { isSavingSettings = false }
        do {
            try await library.setStudyDayRolloverMinutes(minutes)
            rolloverMinutes = minutes
            return true
        } catch {
            settingsError = UserFacingError.message(from: error)
            return false
        }
    }

    /// Continues tuning this profile's weights after each session that adds a
    /// usable review outcome.
    ///
    /// Nothing is reported either way. Fitting is maintenance the learner did
    /// not ask for and cannot act on: a better fit changes only future due
    /// times, and a failure leaves the working parameters in place. Interrupting
    /// the end of a session to say so would be noise.
    func requestAutomaticMaintenance() async {
        await library.requestAutomaticSchedulingMaintenance(asOf: .now)
    }
}
