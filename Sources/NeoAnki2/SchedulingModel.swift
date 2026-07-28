import Foundation
import NeoAnkiCore

@MainActor
@Observable
final class SchedulingModel {
    private(set) var isOptimizing = false
    private(set) var rolloverMinutes = StudyDay.defaultRolloverMinutes
    private(set) var isLoadingSettings = false
    private(set) var isSavingSettings = false
    var isShowingSettings = false
    var settingsError: String?

    private let store: ItemStore

    init(store: ItemStore) {
        self.store = store
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
            rolloverMinutes = try await store.studyDayRolloverMinutes()
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
            try await store.setStudyDayRolloverMinutes(minutes)
            rolloverMinutes = minutes
            return true
        } catch {
            settingsError = UserFacingError.message(from: error)
            return false
        }
    }

    /// Tunes this profile's weights when accumulated history warrants it.
    ///
    /// Nothing is reported either way. Fitting is maintenance the learner did
    /// not ask for and cannot act on: a better fit changes only future due
    /// times, and a failure leaves the working parameters in place. Interrupting
    /// the end of a session to say so would be noise.
    func optimizeIfNeeded() async {
        guard !isOptimizing else { return }
        isOptimizing = true
        defer { isOptimizing = false }
        _ = try? await store.optimizeSchedulingIfNeeded()
    }
}
