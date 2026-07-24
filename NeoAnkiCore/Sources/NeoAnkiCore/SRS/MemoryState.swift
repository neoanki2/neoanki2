import Foundation

/// Per-card memory state, following the FSRS memory model.
///
/// - `stability` (S): the memory's durability in days — the time for
///   retrievability to decay to the target retention. Roughly the interval.
/// - `difficulty` (D): FSRS difficulty on a 1–10 scale; higher means the card
///   gains stability more slowly. `0` means "not yet initialized" (a new card,
///   set on its first review).
///
/// The remaining fields (`due`, `lastReview`, `reps`, `lapses`, `phase`) are
/// used directly by the app for queuing and stats.
public struct MemoryState: Codable, Equatable, Sendable {
    public var stability: Double
    public var difficulty: Double
    public var due: Date
    public var lastReview: Date?
    public var reps: Int
    public var lapses: Int
    public var phase: Phase

    public init(
        stability: Double = 0,
        difficulty: Double = 0,
        due: Date = .now,
        lastReview: Date? = nil,
        reps: Int = 0,
        lapses: Int = 0,
        phase: Phase = .new
    ) {
        self.stability = stability
        self.difficulty = difficulty
        self.due = due
        self.lastReview = lastReview
        self.reps = reps
        self.lapses = lapses
        self.phase = phase
    }

    /// A brand-new, never-reviewed memory due at `due`.
    public static func new(due: Date = .now) -> MemoryState {
        MemoryState(due: due)
    }

    public func isDue(asOf now: Date = .now) -> Bool {
        due <= now
    }
}

/// Where a card sits in its learning lifecycle.
public enum Phase: String, Codable, Sendable {
    case new
    case learning
    case review
    case relearning
}
