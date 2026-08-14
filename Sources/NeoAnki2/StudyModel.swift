import Foundation
import NeoAnkiApplication
import NeoAnkiCore

struct PendingGradeUndo: Equatable, Sendable {
    let reviewLogID: UUID
    let previousIndex: Int
    let previousReviewedCount: Int
    let reviewedCardID: UUID
    let reviewedItemID: UUID
    let insertedReviewedCardID: Bool
    let insertedReviewedItemID: Bool
    let rating: ReviewRating
    let requeuedCardID: UUID?
}

private struct PendingRepeat: Sendable {
    var card: Card
}

struct StudyStartTiming: Sendable, Equatable {
    var dueCountSeconds = 0.0
    var itemTypeCheckSeconds = 0.0
    var headFetchSeconds = 0.0
    var headPublicationSeconds = 0.0
    var remainingFetchSeconds = 0.0
    var remainingPublicationSeconds = 0.0
    var firstReadySeconds = 0.0
    var totalSeconds = 0.0
}

@MainActor
@Observable
final class StudyModel {
    private(set) var queue: [DueCard] = []
    private(set) var index = 0
    private(set) var isAnswerRevealed = false
    private(set) var isLoading = false
    /// The first card is readable while the rest of the exact session queue is
    /// being validated. Persistence and queue mutations remain disabled until
    /// this becomes false.
    private(set) var isPreparingQueue = false
    private(set) var isGrading = false
    private(set) var isCompletingSubmission = false
    private(set) var errorMessage: String?
    private(set) var isFinished = false
    /// Set only when the queue could not be read at all. Without it a failed
    /// load is indistinguishable from an empty one, and a session that never
    /// opened reports itself complete.
    private(set) var didFailToLoad = false
    private(set) var scopeLabel = ""
    private(set) var pendingGradeUndo: PendingGradeUndo?
    private(set) var typedAnswer = ""
    private(set) var answerEvaluation: AnswerEvaluation?
    private(set) var choiceOptions: [String] = []
    private(set) var selectedChoice: String?
    private(set) var arrangedItems: [String] = []
    private(set) var selectedArrangementIndex: Int?
    private(set) var interactionMessage: String?
    private(set) var reviewedCount = 0
    private(set) var completedSubmissionCount = 0
    private(set) var reviewedCardIDs: Set<UUID> = []
    private(set) var reviewedItemIDs: Set<UUID> = []
    private(set) var lastStartTiming = StudyStartTiming()

    let library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses
    /// Repeats only need the newly persisted scheduling state while waiting for
    /// the current pass to finish. Item/type/template content stays canonical
    /// in `queue`, avoiding a second hydrated copy of every failed card.
    private var repairQueue: [PendingRepeat] = []
    private var expectedQueueCount = 0
    private var startGeneration: UInt64 = 0
    private let remainingQueueLoadGate: (@Sendable () async -> Void)?

    init(
        library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses,
        remainingQueueLoadGate: (@Sendable () async -> Void)? = nil
    ) {
        self.library = library
        self.remainingQueueLoadGate = remainingQueueLoadGate
    }

    var currentCard: DueCard? {
        guard !isFinished, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var remainingCardCount: Int {
        guard !isFinished else { return 0 }
        if isPreparingQueue {
            return expectedQueueCount
        }
        guard queue.indices.contains(index) else { return 0 }

        // A failed card waits once in the next repair round while untouched
        // cards remain once in the current queue. Counting both pending groups
        // keeps Again stable without rescanning a potentially large session.
        return queue.count - index + repairQueue.count
    }

    var remainingLabel: String {
        let count = remainingCardCount
        guard count > 0 else { return "" }
        let noun = count == 1 ? "card" : "cards"
        return "\(count) \(noun) remaining"
    }

    var headerLabel: String {
        guard !scopeLabel.isEmpty else { return remainingLabel }
        guard !remainingLabel.isEmpty else { return scopeLabel }
        return "\(scopeLabel) · \(remainingLabel)"
    }

    var cardsReviewed: Int {
        reviewedCount
    }

    var completionSummary: String {
        let reviewNoun = reviewedCount == 1 ? "review" : "reviews"
        let cardCount = reviewedCardIDs.count
        let cardNoun = cardCount == 1 ? "card" : "cards"
        let submissionNoun = completedSubmissionCount == 1 ? "submission" : "submissions"
        return "Completed \(reviewedCount) \(reviewNoun) and \(completedSubmissionCount) \(submissionNoun) across \(cardCount) \(cardNoun)"
    }

    var canUndoLastGrade: Bool {
        pendingGradeUndo != nil
    }

    func startSession(scope: StudyScope = .allDecks) async {
        let start = ContinuousClock.now
        let sessionNow = Date.now
        var timing = StudyStartTiming()
        startGeneration &+= 1
        let generation = startGeneration
        lastStartTiming = timing
        isLoading = true
        isPreparingQueue = false
        expectedQueueCount = 0
        errorMessage = nil
        isFinished = false
        isAnswerRevealed = false
        index = 0
        reviewedCount = 0
        completedSubmissionCount = 0
        reviewedCardIDs = []
        reviewedItemIDs = []
        repairQueue = []
        scopeLabel = scope.label
        pendingGradeUndo = nil
        didFailToLoad = false

        do {
            let countStart = ContinuousClock.now
            let dueCount = try await library.dueCount(
                scope: scope.filter,
                asOf: sessionNow
            )
            timing.dueCountSeconds = countStart.elapsedSeconds
            guard startIsCurrent(generation) else { return }

            if dueCount == 0 {
                let publicationStart = ContinuousClock.now
                queue = []
                isFinished = true
                prepareCurrentInteraction()
                isLoading = false
                timing.remainingPublicationSeconds = publicationStart.elapsedSeconds
                timing.firstReadySeconds = start.elapsedSeconds
                timing.totalSeconds = timing.firstReadySeconds
                lastStartTiming = timing
                return
            }

            let itemTypeStart = ContinuousClock.now
            let itemTypes = try await library.loadItemTypes()
            timing.itemTypeCheckSeconds = itemTypeStart.elapsedSeconds
            guard startIsCurrent(generation) else { return }

            let headStart = ContinuousClock.now
            let head = try await library.dueCards(
                scope: scope.filter,
                asOf: sessionNow,
                limit: 1
            )
            timing.headFetchSeconds = headStart.elapsedSeconds
            guard startIsCurrent(generation) else { return }

            // A corrupt definition can make the database's raw due count differ
            // from the renderable queue. Keep the original all-or-failure load
            // behavior for those libraries instead of publishing an inexact
            // progress total.
            guard itemTypes.corruptions.isEmpty, let firstCard = head.first else {
                try await loadCompleteQueue(
                    scope: scope,
                    asOf: sessionNow,
                    generation: generation,
                    start: start,
                    timing: &timing
                )
                return
            }

            let headPublicationStart = ContinuousClock.now
            queue = [firstCard]
            expectedQueueCount = dueCount
            isFinished = false
            isPreparingQueue = true
            prepareCurrentInteraction()
            isLoading = false
            timing.headPublicationSeconds = headPublicationStart.elapsedSeconds
            timing.firstReadySeconds = start.elapsedSeconds
            lastStartTiming = timing

            if let remainingQueueLoadGate {
                await remainingQueueLoadGate()
                guard startIsCurrent(generation) else { return }
            }

            let remainingFetchStart = ContinuousClock.now
            let completeQueue = try await library.dueCards(
                scope: scope.filter,
                asOf: sessionNow
            )
            timing.remainingFetchSeconds = remainingFetchStart.elapsedSeconds
            guard startIsCurrent(generation) else { return }

            let remainingPublicationStart = ContinuousClock.now
            // Keep the already-rendered copy: it may hold local interaction
            // state or an edit reload. The complete read supplies every
            // remaining card in its original database order.
            queue.reserveCapacity(completeQueue.count)
            for card in completeQueue where card.id != firstCard.id {
                queue.append(card)
            }
            expectedQueueCount = 0
            isPreparingQueue = false
            isLoading = false
            isFinished = false
            timing.remainingPublicationSeconds = remainingPublicationStart.elapsedSeconds
            timing.totalSeconds = start.elapsedSeconds
            lastStartTiming = timing
        } catch {
            guard startIsCurrent(generation) else { return }
            errorMessage = userFacingError(from: error)
            queue = []
            expectedQueueCount = 0
            isPreparingQueue = false
            isFinished = true
            didFailToLoad = true
            isLoading = false
            timing.totalSeconds = start.elapsedSeconds
            if timing.firstReadySeconds == 0 {
                timing.firstReadySeconds = timing.totalSeconds
            }
            lastStartTiming = timing
        }
    }

    func revealAnswer() {
        guard currentCard != nil else { return }
        isAnswerRevealed = true
    }

    func updateTypedAnswer(_ answer: String) {
        guard !isAnswerRevealed else { return }
        typedAnswer = answer
        answerEvaluation = nil
        interactionMessage = nil
    }

    func submitTypedAnswer() {
        guard let card = currentCard, card.template.interaction == .type else { return }
        let evaluation = StudySupport.evaluate(typedAnswer, for: card)
        if evaluation == .unavailable {
            recoverFromMissingAnswer()
            return
        }
        guard !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            interactionMessage = "Enter an answer, or reveal it to self-grade."
            return
        }
        answerEvaluation = evaluation
        isAnswerRevealed = true
    }

    func selectChoice(_ option: String) {
        guard choiceOptions.contains(option), !isAnswerRevealed else { return }
        selectedChoice = option
        interactionMessage = nil
    }

    func submitChoice() {
        guard let card = currentCard, card.template.interaction == .choose else { return }
        guard !choiceOptions.isEmpty else {
            recoverFromMissingAnswer()
            return
        }
        guard let selectedChoice else {
            interactionMessage = "Choose an option, or reveal the answer to self-grade."
            return
        }
        answerEvaluation = StudySupport.evaluate(selectedChoice, for: card)
        isAnswerRevealed = true
    }

    func selectArrangementItem(at index: Int) {
        guard arrangedItems.indices.contains(index), !isAnswerRevealed else { return }
        selectedArrangementIndex = index
        interactionMessage = nil
    }

    func moveSelectedArrangementItem(by offset: Int) {
        guard let selectedArrangementIndex else {
            interactionMessage = "Select an item before moving it."
            return
        }
        let destination = selectedArrangementIndex + offset
        guard arrangedItems.indices.contains(destination), !isAnswerRevealed else { return }
        arrangedItems.swapAt(selectedArrangementIndex, destination)
        self.selectedArrangementIndex = destination
        answerEvaluation = nil
    }

    func submitArrangement() {
        guard let card = currentCard, card.template.interaction == .arrange else { return }
        guard !arrangedItems.isEmpty else {
            recoverFromMissingAnswer()
            return
        }
        answerEvaluation = StudySupport.isCorrectArrangement(arrangedItems, for: card)
        isAnswerRevealed = true
    }

    func completeRecording() {
        guard let card = currentCard, card.template.interaction == .record else { return }
        interactionMessage = if StudySupport.hasReferenceAudio(for: card) {
            "Replay your recording, then play the reference audio below."
        } else {
            "No reference audio is available for this card. Replay your recording and compare it with the written answer."
        }
        isAnswerRevealed = true
    }

    func performPrimaryAction() {
        guard let interaction = currentCard?.template.interaction else { return }
        switch interaction {
        case .reveal, .cloze:
            revealAnswer()
        case .type:
            submitTypedAnswer()
        case .choose:
            submitChoice()
        case .record:
            completeRecording()
        case .arrange:
            submitArrangement()
        case .audioSubmission:
            break
        }
    }

    func completeAudioSubmission(_ draft: StudyResponseDraft) async -> Bool {
        guard !isCompletingSubmission, !isPreparingQueue,
              let card = currentCard,
              card.id == draft.cardID,
              card.template.interaction == .audioSubmission
        else { return false }
        isCompletingSubmission = true
        defer { isCompletingSubmission = false }
        errorMessage = nil
        do {
            _ = try await library.completeAudioSubmission(draft, submittedAt: .now)
            reviewedCardIDs.insert(card.id)
            reviewedItemIDs.insert(card.item.id)
            completedSubmissionCount += 1
            pendingGradeUndo = nil
            index += 1
            isAnswerRevealed = false
            advanceSession()
            return true
        } catch {
            errorMessage = userFacingError(from: error)
            return false
        }
    }

    func grade(_ rating: ReviewRating) async {
        guard !isGrading, !isPreparingQueue else { return }
        errorMessage = nil
        guard let card = currentCard else { return }

        isGrading = true
        defer { isGrading = false }

        let previousIndex = index
        let now = Date.now

        do {
            let submission = try await library.submitReview(
                cardID: card.id,
                rating: rating,
                asOf: now,
                durationMilliseconds: 0
            )
            var repeatedCard = card
            repeatedCard.card.memory = submission.memory
            let shouldRequeue = submission.memory.phase == .learning
                || submission.memory.phase == .relearning
            if shouldRequeue {
                repairQueue.append(PendingRepeat(card: repeatedCard.card))
            }
            let insertedReviewedCardID = reviewedCardIDs.insert(card.id).inserted
            let insertedReviewedItemID = reviewedItemIDs.insert(card.item.id).inserted
            pendingGradeUndo = PendingGradeUndo(
                reviewLogID: submission.reviewLogID,
                previousIndex: previousIndex,
                previousReviewedCount: reviewedCount,
                reviewedCardID: card.id,
                reviewedItemID: card.item.id,
                insertedReviewedCardID: insertedReviewedCardID,
                insertedReviewedItemID: insertedReviewedItemID,
                rating: rating,
                requeuedCardID: shouldRequeue ? card.id : nil
            )
            index += 1
            reviewedCount += 1
            isAnswerRevealed = false
            advanceSession()
        } catch DatabaseError.cardNotFound(_) {
            discardMissingCurrentCard(card.id)
        } catch {
            errorMessage = userFacingError(from: error)
        }
    }

    func undoLastGrade() async {
        guard !isGrading else { return }
        guard let undo = pendingGradeUndo else { return }

        isGrading = true
        defer { isGrading = false }

        do {
            try await library.revertReview(id: undo.reviewLogID, asOf: .now)
            if let requeuedCardID = undo.requeuedCardID {
                repairQueue.removeAll { $0.card.id == requeuedCardID }
                if let queuedRepeat = queue.indices.last(where: {
                    $0 > undo.previousIndex && queue[$0].id == requeuedCardID
                }) {
                    queue.remove(at: queuedRepeat)
                }
            }
            index = undo.previousIndex
            reviewedCount = undo.previousReviewedCount
            if undo.insertedReviewedCardID {
                reviewedCardIDs.remove(undo.reviewedCardID)
            }
            if undo.insertedReviewedItemID {
                reviewedItemIDs.remove(undo.reviewedItemID)
            }
            isFinished = false
            isAnswerRevealed = true
            prepareCurrentInteraction()
            isAnswerRevealed = true
            pendingGradeUndo = nil
        } catch {
            errorMessage = userFacingError(from: error)
        }
    }

    func dismissGradeUndo() {
        pendingGradeUndo = nil
    }

    /// Re-reads the item behind the current card after it was edited mid-session,
    /// so the rest of the session shows the correction rather than the copy the
    /// queue was built from. Every queued card drawn from that item is refreshed,
    /// because one item can own several cards in the same session.
    func reloadCurrentItem() async {
        guard !isPreparingQueue else { return }
        guard let itemID = currentCard?.item.id else { return }

        do {
            guard let reloaded = try await library.item(id: itemID) else { return }
            refreshQueuedCards(for: reloaded.item, itemType: reloaded.itemType)
            // An answer already on screen keeps its feedback: re-deriving the
            // interaction here would clear the message the learner is reading,
            // and the choices or ordering they answered no longer matter.
            if !isAnswerRevealed {
                prepareCurrentInteraction()
            }
        } catch {
            errorMessage = userFacingError(from: error)
        }
    }

    private func refreshQueuedCards(for item: Item, itemType: ItemType) {
        func refresh(_ card: inout DueCard) {
            guard card.item.id == item.id else { return }
            card.item = item
            card.itemType = itemType
            // Editing an item cannot change its templates, but reading the
            // template back keeps each card rendering from one revision.
            if let template = itemType.templates.first(where: { $0.id == card.template.id }) {
                card.template = template
            }
        }

        for index in queue.indices {
            refresh(&queue[index])
        }
    }

    func skipCurrentCard() {
        guard !isPreparingQueue else { return }
        errorMessage = nil
        pendingGradeUndo = nil
        guard currentCard != nil else { return }

        index += 1
        isAnswerRevealed = false
        advanceSession()
    }

    private func prepareCurrentInteraction() {
        typedAnswer = ""
        answerEvaluation = nil
        selectedChoice = nil
        selectedArrangementIndex = nil
        interactionMessage = nil
        guard let card = currentCard else {
            choiceOptions = []
            arrangedItems = []
            return
        }
        choiceOptions = card.template.interaction == .choose
            ? StudySupport.choiceOptions(for: card)
            : []
        arrangedItems = card.template.interaction == .arrange
            ? StudySupport.arrangement(for: card)?.initial ?? []
            : []
        if card.template.interaction == .choose, choiceOptions.isEmpty {
            interactionMessage = "This card has no usable answer options. Reveal it to self-grade."
        } else if card.template.interaction == .arrange, arrangedItems.isEmpty {
            interactionMessage = "This card has nothing to arrange. Reveal it to self-grade."
        }
    }

    private func recoverFromMissingAnswer() {
        answerEvaluation = .unavailable
        interactionMessage = "No checkable answer is available. Review the card and self-grade."
        isAnswerRevealed = true
    }

    private func userFacingError(from error: Error) -> String {
        UserFacingError.message(from: error)
    }

    private func discardMissingCurrentCard(_ cardID: UUID) {
        guard queue.indices.contains(index), queue[index].id == cardID else { return }
        queue.remove(at: index)
        isAnswerRevealed = false
        repairQueue.removeAll { $0.card.id == cardID }
        advanceSession()
    }

    private func advanceSession() {
        guard !isPreparingQueue else { return }
        guard index >= queue.count else {
            isFinished = false
            prepareCurrentInteraction()
            return
        }

        if !repairQueue.isEmpty {
            var sourceIndexByCardID: [UUID: Int] = [:]
            sourceIndexByCardID.reserveCapacity(repairQueue.count)
            for (sourceIndex, card) in queue.enumerated() {
                sourceIndexByCardID[card.id] = sourceIndex
            }
            queue.reserveCapacity(queue.count + repairQueue.count)
            for repeatEntry in repairQueue {
                guard let sourceIndex = sourceIndexByCardID[repeatEntry.card.id] else {
                    continue
                }
                var repeatedCard = queue[sourceIndex]
                repeatedCard.card = repeatEntry.card
                queue.append(repeatedCard)
            }
            repairQueue = []
            isFinished = false
            prepareCurrentInteraction()
            return
        }

        isFinished = true
        prepareCurrentInteraction()
    }

    private func loadCompleteQueue(
        scope: StudyScope,
        asOf now: Date,
        generation: UInt64,
        start: ContinuousClock.Instant,
        timing: inout StudyStartTiming
    ) async throws {
        let fetchStart = ContinuousClock.now
        let completeQueue = try await library.dueCards(
            scope: scope.filter,
            asOf: now
        )
        timing.remainingFetchSeconds = fetchStart.elapsedSeconds
        guard startIsCurrent(generation) else { return }

        let publicationStart = ContinuousClock.now
        queue = completeQueue
        isFinished = queue.isEmpty
        prepareCurrentInteraction()
        isLoading = false
        timing.remainingPublicationSeconds = publicationStart.elapsedSeconds
        timing.firstReadySeconds = start.elapsedSeconds
        timing.totalSeconds = timing.firstReadySeconds
        lastStartTiming = timing
    }

    private func startIsCurrent(_ generation: UInt64) -> Bool {
        generation == startGeneration && !Task.isCancelled
    }
}

private extension ContinuousClock.Instant {
    var elapsedSeconds: Double {
        let duration = duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
