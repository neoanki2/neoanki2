import Foundation

/// A spaced-repetition algorithm. Cards store only `MemoryState`, so the
/// implementation (`FSRSScheduler`) stays swappable without changing the card
/// model or the review pipeline.
public protocol Scheduler: Sendable {
    /// Produce the next memory state from a review outcome.
    func schedule(_ state: MemoryState, rating: ReviewRating, now: Date) -> MemoryState
}
