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
    var notice: Notice?

    private let store: ItemStore

    init(store: ItemStore) {
        self.store = store
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
            notice = .failure(error.localizedDescription)
        } catch {
            notice = .failure("Scheduling parameters could not be saved. Try again.")
        }
    }
}
