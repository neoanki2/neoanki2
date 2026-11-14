import NeoAnkiCore

/// Compatibility entry point for feature clients; the policy is shared by all clients.
enum ContextReviewOrdering {
    static func separateRelatedContexts(in queue: inout [DueCard], at index: Int) {
        StudyQueueOrdering.separateRelated(in: &queue, at: index)
    }
}
