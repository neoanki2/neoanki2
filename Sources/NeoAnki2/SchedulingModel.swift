import Foundation
import NeoAnkiCore

@MainActor
@Observable
final class SchedulingModel {
    enum Notice: Equatable {
        case success(String)
        case failure(String)

        var title: String {
            switch self {
            case .success: "Scheduling Optimized"
            case .failure: "Could Not Optimize Scheduling"
            }
        }

        var message: String {
            switch self {
            case let .success(message), let .failure(message): message
            }
        }
    }

    private(set) var isOptimizing = false
    private(set) var rolloverMinutes = StudyDay.defaultRolloverMinutes
    private(set) var isLoadingSettings = false
    private(set) var isSavingSettings = false
    var isShowingSettings = false
    var settingsError: String?
    var notice: Notice?

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

    func optimize() async {
        guard !isOptimizing else { return }
        isOptimizing = true
        notice = nil
        defer { isOptimizing = false }

        do {
            let result = try await store.optimizeScheduling()
            if result.improved {
                let percent = max(
                    0,
                    (result.previousLoss - result.optimizedLoss) / result.previousLoss * 100
                )
                notice = .success(
                    "Updated this profile using \(result.observationCount) review outcomes "
                        + "(\(percent.formatted(.number.precision(.fractionLength(1))))% lower log loss)."
                )
            } else {
                notice = .success(
                    "The current parameters already fit the \(result.observationCount) "
                        + "available review outcomes; no change was needed."
                )
            }
        } catch let error as FSRSOptimizationError {
            notice = .failure(UserFacingError.schedulingMessage(from: error))
        } catch {
            notice = .failure(UserFacingError.schedulingMessage(from: error))
        }
    }
}
