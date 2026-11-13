import Foundation
import NeoAnkiCore

/// Presentation order only. Every card phase keeps its queue positions and all memories remain unchanged.
enum ContextReviewOrdering {
    static func separateRelatedContexts(in queue: inout [DueCard], at index: Int) {
        guard index > 0, queue.indices.contains(index), canInterleave(queue[index]) else { return }
        let phase = queue[index].card.memory.phase
        guard let previous = SavedContextMetadata.groupID(in: queue[index - 1].item),
              SavedContextMetadata.groupID(in: queue[index].item) == previous,
              let alternate = queue.indices.dropFirst(index + 1).first(where: {
                  queue[$0].card.memory.phase == phase && SavedContextMetadata.groupID(in: queue[$0].item) != previous
              }) else { return }
        // Swapping only same-phase slots preserves the existing review-before-new
        // priority and every learning/repair position, including after a skip.
        queue.swapAt(index, alternate)
    }

    private static func canInterleave(_ value: DueCard) -> Bool {
        value.card.memory.phase == .new || value.card.memory.phase == .review
    }
}
