/// The learner's self-assessed recall on a review. Raw values match the
/// 1...4 grades used by modern schedulers (FSRS), so ratings serialize the
/// same regardless of which `Scheduler` is active.
public enum ReviewRating: Int, Codable, Sendable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}
