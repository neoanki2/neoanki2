import Foundation
import NeoAnkiCore

/// A compensating review and the session changes that must be undone with it.
public struct StudyGradeUndo: Equatable, Sendable {
    public let reviewLogID: UUID
    public let previousIndex: Int
    public let previousReviewedCount: Int
    public let reviewedCardID: UUID
    public let reviewedItemID: UUID
    public let insertedReviewedCardID: Bool
    public let insertedReviewedItemID: Bool
    public let rating: ReviewRating
    public let requeuedCardID: UUID?
}

/// The sole native queue/repair/undo authority. This value has no observation,
/// platform, clock, or persistence dependencies. Callers commit reviews before
/// applying their results, and commit compensating reverts before restoring state.
public struct StudySessionState: Sendable {
    public private(set) var queue: [DueCard] = []
    public private(set) var index = 0
    public private(set) var reviewedCount = 0
    public private(set) var completedSubmissionCount = 0
    public private(set) var reviewedCardIDs: Set<UUID> = []
    public private(set) var reviewedItemIDs: Set<UUID> = []
    public private(set) var pendingGradeUndo: StudyGradeUndo?
    private var repairs: [Card] = []

    public init() {}
    public var currentCard: DueCard? { queue.indices.contains(index) ? queue[index] : nil }
    public var remainingCount: Int { max(0, queue.count - index) + repairs.count }
    public var hasPendingRepairs: Bool { !repairs.isEmpty }

    public mutating func reset() { self = .init() }
    public mutating func load(_ cards: [DueCard]) { queue = cards }

    /// Preserve the readable head (including edits) when the exact queue arrives.
    public mutating func appendRemaining(_ cards: [DueCard], excluding headID: UUID) {
        queue.reserveCapacity(cards.count)
        for card in cards where card.id != headID { queue.append(card) }
    }

    public mutating func appendDueCards(_ cards: [DueCard]) {
        queue.append(contentsOf: cards)
    }

    public mutating func recordGrade(_ submission: ReviewSubmission, for card: DueCard, rating: ReviewRating) {
        let needsRepair = submission.memory.phase == .learning || submission.memory.phase == .relearning
        if needsRepair {
            var repeated = card.card
            repeated.memory = submission.memory
            repairs.append(repeated)
        }
        pendingGradeUndo = StudyGradeUndo(reviewLogID: submission.reviewLogID, previousIndex: index,
            previousReviewedCount: reviewedCount, reviewedCardID: card.id, reviewedItemID: card.item.id,
            insertedReviewedCardID: reviewedCardIDs.insert(card.id).inserted,
            insertedReviewedItemID: reviewedItemIDs.insert(card.item.id).inserted,
            rating: rating, requeuedCardID: needsRepair ? card.id : nil)
        index += 1
        reviewedCount += 1
    }

    public mutating func recordSubmission(for card: DueCard) {
        reviewedCardIDs.insert(card.id)
        reviewedItemIDs.insert(card.item.id)
        completedSubmissionCount += 1
        pendingGradeUndo = nil
        index += 1
    }

    public mutating func undoGrade(_ undo: StudyGradeUndo) {
        if let id = undo.requeuedCardID {
            repairs.removeAll { $0.id == id }
        }
        // A later attempt can come from a repair round or a fresh due check.
        if let queued = queue.indices.last(where: {
            $0 > undo.previousIndex && queue[$0].id == undo.reviewedCardID
        }) {
            queue.remove(at: queued)
        }
        index = undo.previousIndex
        reviewedCount = undo.previousReviewedCount
        if undo.insertedReviewedCardID { reviewedCardIDs.remove(undo.reviewedCardID) }
        if undo.insertedReviewedItemID { reviewedItemIDs.remove(undo.reviewedItemID) }
        pendingGradeUndo = nil
    }

    public mutating func dismissUndo() { pendingGradeUndo = nil }
    public mutating func skip() {
        pendingGradeUndo = nil
        guard currentCard != nil else { return }
        materializeRepairs()
        queue.append(queue.remove(at: index))
    }
    public mutating func discardCurrent() {
        guard let card = currentCard else { return }
        queue.remove(at: index)
        repairs.removeAll { $0.id == card.id }
    }
    public mutating func separateRelated() { StudyQueueOrdering.separateRelated(in: &queue, at: index) }

    public mutating func refresh(item: Item, itemType: ItemType) {
        reconcile(itemID: item.id, item: item, itemType: itemType, liveCards: nil)
    }

    /// Reconcile existing session membership. Newly generated siblings enter
    /// through a due-queue read.
    /// Keep the reviewed prefix in place so compensating undo indices remain
    /// valid. A retired reviewed card loses its undo affordance instead.
    public mutating func reconcile(itemID: UUID, snapshot: ItemCardSnapshot?) {
        reconcile(itemID: itemID, item: snapshot?.item, itemType: snapshot?.itemType, liveCards: snapshot?.cards ?? [])
    }

    private mutating func reconcile(itemID: UUID, item: Item?, itemType: ItemType?, liveCards: [Card]?) {
        let templates = Dictionary(uniqueKeysWithValues: (itemType?.templates ?? []).map { ($0.id, $0) })
        let persisted = liveCards.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
        func remainsValid(_ card: Card) -> Bool {
            guard card.itemID == itemID else { return true }
            let effective = persisted == nil ? card : persisted?[card.id]
            guard let effective, !effective.isSuspended, let item, let template = templates[effective.templateID],
                  CardGenerator.shouldGenerate(template, for: item) else { return false }
            if persisted != nil { return true }
            // Compatibility adapters without the atomic snapshot capability can
            // still prune retired generation coordinates from canonical content.
            if template.interaction == .cloze {
                guard let group = card.clozeGroup else { return false }
                return CardGenerator.clozeGroups(for: template, item: item).contains(group)
            }
            if template.interaction == .imageOcclusion {
                guard let group = card.occlusionGroup else { return false }
                return CardGenerator.occlusionGroups(for: template, item: item).contains(group)
            }
            return true
        }
        func refreshed(_ due: DueCard, updateCard: Bool) -> DueCard {
            guard due.item.id == itemID, let item, let itemType else { return due }
            var card = persisted?[due.id] ?? due.card
            guard let template = templates[card.templateID] else { return due }
            if !updateCard {
                card.memory = due.card.memory
                card.memoryModelVersion = due.card.memoryModelVersion
                card.memoryParameterSetID = due.card.memoryParameterSetID
                card.schedulingHistoryOrigin = due.card.schedulingHistoryOrigin
            }
            var result = due
            result.item = item
            result.itemType = itemType
            result.template = template
            result.card = card
            StudyQueueOrdering.refreshRelation(in: &result)
            return result
        }
        for position in queue.indices where position < index {
            queue[position] = refreshed(queue[position], updateCard: false)
        }
        let remaining = queue.dropFirst(index).filter { remainsValid($0.card) }.map { refreshed($0, updateCard: true) }
        queue.replaceSubrange(index..<queue.count, with: remaining)
        repairs = repairs.filter(remainsValid).map { repair in
            guard repair.itemID == itemID, var live = persisted?[repair.id] else { return repair }
            live.memory = repair.memory
            return live
        }
        if let undo = pendingGradeUndo, undo.reviewedItemID == itemID,
           !queue.prefix(index).contains(where: { $0.id == undo.reviewedCardID && remainsValid($0.card) }) {
            pendingGradeUndo = nil
        }
        StudyQueueOrdering.orderWorks(in: &queue, from: index + 1)
    }

    /// Skip places a card behind the deferred round, while normal advancement
    /// starts that round only after untouched cards have been exhausted.
    public mutating func materializeRepairs() {
        guard !repairs.isEmpty else { return }
        let passStart = queue.count
        var sourceIndices: [UUID: Int] = [:]
        sourceIndices.reserveCapacity(repairs.count)
        for (position, card) in queue.enumerated() { sourceIndices[card.id] = position }
        queue.reserveCapacity(queue.count + repairs.count)
        for repair in repairs {
            guard let source = sourceIndices[repair.id] else { continue }
            var card = queue[source]
            card.card = repair
            queue.append(card)
        }
        StudyQueueOrdering.orderWorks(in: &queue, from: passStart)
        repairs = []
    }
}
