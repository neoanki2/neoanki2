import Foundation

/// Criterion-based acquisition policy layered over FSRS memory updates.
///
/// The phase/rating contract is explicit:
/// - New/learning/relearning + Again: update D/S with FSRS, but remain due now
///   for a non-waiting acquisition repair round.
/// - New/learning/relearning + Hard/Good/Easy: graduate and keep FSRS's precise
///   (possibly intraday) due date.
/// - Review + Again: count one lapse and enter immediate relearning repair.
/// - Review + Hard/Good/Easy: remain in review with the FSRS-selected due date.
///
/// Repeated repair attempts never add lapses or interval fuzz to their
/// immediate due date. Every attempt still updates FSRS memory state so the
/// eventual post-recall interval reflects the complete history.
public struct LearningScheduler: Scheduler {
    public static let policyIdentifier = "repair-rounds"

    private let fsrs: FSRSScheduler

    public init(parameters: FSRSScheduler.Parameters = .init()) {
        fsrs = FSRSScheduler(parameters: parameters)
    }

    public func schedule(
        _ state: MemoryState,
        rating: ReviewRating,
        now: Date = .now
    ) -> MemoryState {
        var next = fsrs.schedule(state, rating: rating, now: now)

        switch state.phase {
        case .new:
            switch rating {
            case .again:
                enterRepairRound(&next, phase: .learning, previousStep: nil, now: now)
            case .hard, .good, .easy:
                graduate(&next)
            }

        case .learning:
            next.lapses = state.lapses
            switch rating {
            case .again:
                enterRepairRound(
                    &next,
                    phase: .learning,
                    previousStep: state.stepIndex,
                    now: now
                )
            case .hard, .good, .easy:
                graduate(&next)
            }

        case .review:
            if rating == .again {
                enterRepairRound(&next, phase: .relearning, previousStep: nil, now: now)
            } else {
                graduate(&next)
            }

        case .relearning:
            next.lapses = state.lapses
            switch rating {
            case .again:
                enterRepairRound(
                    &next,
                    phase: .relearning,
                    previousStep: state.stepIndex,
                    now: now
                )
            case .hard, .good, .easy:
                graduate(&next)
            }
        }

        return next
    }

    private func enterRepairRound(
        _ state: inout MemoryState,
        phase: Phase,
        previousStep: Int?,
        now: Date
    ) {
        state.phase = phase
        state.stepIndex = previousStep.map { $0 + 1 } ?? 0
        state.due = now
    }

    private func graduate(_ state: inout MemoryState) {
        state.phase = .review
        state.stepIndex = nil
    }
}
