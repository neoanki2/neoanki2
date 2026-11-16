import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

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

private struct PendingRepeat: Sendable {
    var card: Card
}

public struct StudySessionStartTiming: Sendable, Equatable {
    public fileprivate(set) var dueCountSeconds = 0.0
    public fileprivate(set) var itemTypeCheckSeconds = 0.0
    public fileprivate(set) var headFetchSeconds = 0.0
    public fileprivate(set) var headPublicationSeconds = 0.0
    public fileprivate(set) var remainingFetchSeconds = 0.0
    public fileprivate(set) var remainingPublicationSeconds = 0.0
    public fileprivate(set) var firstReadySeconds = 0.0
    public fileprivate(set) var totalSeconds = 0.0
}

public struct StudyCompletion: Sendable, Equatable {
    public let reviews: Int
    public let uniqueCards: Int
    public let uniqueItems: Int
    public let savedSubmissions: Int

    public init(reviews: Int, uniqueCards: Int, uniqueItems: Int, savedSubmissions: Int = 0) {
        self.reviews = reviews
        self.uniqueCards = uniqueCards
        self.uniqueItems = uniqueItems
        self.savedSubmissions = savedSubmissions
    }
}

@MainActor
@Observable
public final class StudyFeatureModel: Identifiable {
    public let id = UUID()
    public private(set) var title: String
    public let mediaStore: MediaStore?
    private let errorMapper: any UserFacingErrorMapping
    private let onMutation: (@MainActor @Sendable () async -> Void)?
    private let clock: @Sendable () -> Date
    public private(set) var queue: [DueCard] = [] { didSet { updateLearningTime() } }
    public private(set) var index = 0 { didSet { updateLearningTime() } }
    public private(set) var isAnswerRevealed = false {
        didSet { if isAnswerRevealed && !oldValue { learningTime.interaction(); answerActiveStart = learningTime.sessionMilliseconds } }
    }
    private var attemptActiveStart: Int64 = 0
    private var answerActiveStart: Int64?
    public private(set) var isLoading = false { didSet { updateLearningTime() } }
    /// The first card is readable while the rest of the exact session queue is
    /// being validated. Persistence and queue mutations remain disabled until
    /// this becomes false.
    public private(set) var isPreparingQueue = false
    public private(set) var isGrading = false { didSet { updateLearningTime() } }
    public private(set) var isCompletingSubmission = false { didSet { updateLearningTime() } }
    public private(set) var error: UserFacingError?
    public private(set) var isFinished = false { didSet { updateLearningTime() } }
    /// Set only when the queue could not be read at all. Without it a failed
    /// load is indistinguishable from an empty one, and a session that never
    /// opened reports itself complete.
    public private(set) var didFailToLoad = false { didSet { updateLearningTime() } }
    public private(set) var pendingGradeUndo: StudyGradeUndo?
    public private(set) var typedAnswer = ""
    public private(set) var answerEvaluation: AnswerEvaluation?
    public private(set) var choiceOptions: [String] = []
    public private(set) var selectedChoice: String?
    public private(set) var arrangedItems: [String] = []
    public private(set) var selectedArrangementIndex: Int?
    public private(set) var interactionMessage: String?

    /// Retain the learner's actual response when the input controls disappear.
    public var reviewResponse: String? {
        guard isAnswerRevealed else { return nil }
        switch currentCard?.template.interaction {
        case .type:
            return typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : typedAnswer
        case .choose:
            return selectedChoice
        case .arrange:
            guard !arrangedItems.isEmpty else { return nil }
            let reference = currentCard.flatMap { StudyResponseEvaluator.acceptedAnswers(for: $0).first } ?? ""
            let separator = reference.split(whereSeparator: \.isNewline).count > 1 ? "\n"
                : (reference.split(whereSeparator: \.isWhitespace).count > 1 ? " " : "")
            return arrangedItems.joined(separator: separator)
        default:
            return nil
        }
    }
    public private(set) var reviewedCount = 0
    public private(set) var completedSubmissionCount = 0
    public private(set) var reviewedCardIDs: Set<UUID> = []
    public private(set) var reviewedItemIDs: Set<UUID> = []
    public private(set) var lastStartTiming = StudySessionStartTiming()

    private let library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses
    /// Repeats only need the newly persisted scheduling state while waiting for
    /// the current pass to finish. Item/type/template content stays canonical
    /// in `queue`, avoiding a second hydrated copy of every failed card.
    public private(set) var sessionScope: DeckScope = .allDecks
    private var repairQueue: [PendingRepeat] = []
    public let learningTime: LearningTimeTracker
    private var reviewTiming = ReviewTimingTracker()
    private var expectedQueueCount = 0
    private var startGeneration: UInt64 = 0
    package var remainingQueueLoadGate: (@Sendable () async -> Void)?

    public init(
        library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses,
        scope: DeckScope,
        title: String,
        mediaStore: MediaStore? = nil,
        onMutation: (@MainActor @Sendable () async -> Void)? = nil,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper(),
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.library = library
        self.sessionScope = scope
        self.title = title
        self.mediaStore = mediaStore
        self.onMutation = onMutation
        self.errorMapper = errorMapper
        self.clock = clock
        self.learningTime = LearningTimeTracker(library: library as? any LibraryLearningTime)
    }

    public var completion: StudyCompletion {
        .init(reviews: reviewedCount, uniqueCards: reviewedCardIDs.count,
              uniqueItems: reviewedItemIDs.count, savedSubmissions: completedSubmissionCount)
    }

    public var isComplete: Bool { isFinished && !didFailToLoad && !isLoading && !isPreparingQueue }
    public var remainingCount: Int { remainingCardCount }
    public var canUndo: Bool { pendingGradeUndo != nil && !isGrading && !isCompletingSubmission && !isPreparingQueue }

    public func start() async { await start(scope: sessionScope, title: title) }
    public func skip() async { await skipCurrentCard() }
    public func dismissError() { error = nil }

    public var currentCard: DueCard? {
        guard !isFinished, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    public var remainingCardCount: Int {
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

    public func start(scope: DeckScope, title: String) async {
        let start = ContinuousClock.now
        guard !isGrading, !isCompletingSubmission else { return }
        let sessionNow = clock()
        var timing = StudySessionStartTiming()
        startGeneration &+= 1
        let generation = startGeneration
        lastStartTiming = timing
        isLoading = true
        isPreparingQueue = false
        expectedQueueCount = 0
        queue = []
        prepareCurrentInteraction()
        error = nil
        isFinished = false
        isAnswerRevealed = false
        index = 0
        reviewedCount = 0
        completedSubmissionCount = 0
        reviewedCardIDs = []
        reviewedItemIDs = []
        repairQueue = []
        reviewTiming = ReviewTimingTracker()
        self.title = title
        sessionScope = scope
        pendingGradeUndo = nil
        didFailToLoad = false

        do {
            let countStart = ContinuousClock.now
            let dueCount = try await library.dueCount(
                scope: scope,
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
                scope: scope,
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
            resetAttemptTiming()
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
                scope: scope,
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
            self.error = errorMapper.map(error)
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

    public func revealAnswer() {
        learningTime.interaction()
        guard currentCard != nil else { return }
        isAnswerRevealed = true
    }

    public func updateTypedAnswer(_ answer: String) {
        learningTime.interaction()
        guard !isAnswerRevealed else { return }
        typedAnswer = answer
        answerEvaluation = nil
        interactionMessage = nil
    }

    public func submitTypedAnswer() {
        guard let card = currentCard, card.template.interaction == .type else { return }
        let evaluation = StudyResponseEvaluator.evaluate(typedAnswer, for: card)
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

    public func selectChoice(_ option: String) {
        learningTime.interaction()
        guard choiceOptions.contains(option), !isAnswerRevealed else { return }
        selectedChoice = option
        interactionMessage = nil
    }

    public func submitChoice() {
        guard let card = currentCard, card.template.interaction == .choose else { return }
        guard !choiceOptions.isEmpty else {
            recoverFromMissingAnswer()
            return
        }
        guard let selectedChoice else {
            interactionMessage = "Choose an option, or reveal the answer to self-grade."
            return
        }
        answerEvaluation = StudyResponseEvaluator.evaluate(selectedChoice, for: card)
        isAnswerRevealed = true
    }

    public func selectArrangementItem(at index: Int) {
        learningTime.interaction()
        guard arrangedItems.indices.contains(index), !isAnswerRevealed else { return }
        selectedArrangementIndex = index
        interactionMessage = nil
    }

    public func moveSelectedArrangementItem(by offset: Int) {
        learningTime.interaction()
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

    public func submitArrangement() {
        guard let card = currentCard, card.template.interaction == .arrange else { return }
        guard !arrangedItems.isEmpty else {
            recoverFromMissingAnswer()
            return
        }
        answerEvaluation = StudyResponseEvaluator.isCorrectArrangement(arrangedItems, for: card)
        isAnswerRevealed = true
    }

    public func completeRecording() {
        guard let card = currentCard, card.template.interaction == .record else { return }
        interactionMessage = if StudyResponseEvaluator.hasReferenceAudio(for: card) {
            "Replay your recording, then play the reference audio below."
        } else {
            "No reference audio is available for this card. Replay your recording and compare it with the written answer."
        }
        isAnswerRevealed = true
    }

    public func performPrimaryAction() {
        learningTime.interaction()
        guard let interaction = currentCard?.template.interaction else { return }
        switch interaction {
        case .reveal, .cloze, .imageOcclusion:
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

    public func completeAudioSubmission(_ draft: StudyResponseDraft) async -> Bool {
        guard !isCompletingSubmission, !isGrading, !isLoading, !isPreparingQueue,
              let card = currentCard,
              card.id == draft.cardID,
              card.template.interaction == .audioSubmission
        else { return false }
        isCompletingSubmission = true
        defer { isCompletingSubmission = false }
        error = nil
        do {
            let context=StatisticsReviewContext(sessionID:learningTime.sessionID,deviceID:learningTime.deviceID,promptMilliseconds:max(0,learningTime.sessionMilliseconds-attemptActiveStart),answerMilliseconds:0)
            _ = try await StatisticsCapture.$context.withValue(context) {
                try await library.completeAudioSubmission(draft, submittedAt: clock())
            }
            reviewedCardIDs.insert(card.id)
            reviewedItemIDs.insert(card.item.id)
            completedSubmissionCount += 1
            pendingGradeUndo = nil
            index += 1
            isAnswerRevealed = false
            await advanceSession()
            await onMutation?()
            return true
        } catch {
            self.error = errorMapper.map(error)
            return false
        }
    }

    private func resetAttemptTiming() {
        reviewTiming.reset()
        attemptActiveStart = learningTime.sessionMilliseconds
        answerActiveStart = nil
    }

    public func grade(_ rating: ReviewRating) async {
        learningTime.interaction()
        guard !isGrading, !isCompletingSubmission, !isLoading, !isPreparingQueue else { return }
        error = nil
        guard let card = currentCard else { return }

        isGrading = true
        defer { isGrading = false }

        let previousIndex = index
        let now = clock()

        do {
            let activeEnd = learningTime.sessionMilliseconds
            let answerStart = answerActiveStart ?? activeEnd
            let context = StatisticsReviewContext(sessionID: learningTime.sessionID, deviceID: learningTime.deviceID,
                promptMilliseconds: max(0, answerStart - attemptActiveStart), answerMilliseconds: max(0, activeEnd - answerStart), checkedCorrect: answerEvaluation == .unavailable || answerEvaluation == nil ? nil : answerEvaluation == .correct)
            let submission = try await StatisticsCapture.$context.withValue(context) {
                try await library.submitReview(
                cardID: card.id,
                rating: rating,
                asOf: now,
                durationMilliseconds: reviewTiming.elapsedMilliseconds()
            )
            }
            var repeatedCard = card
            repeatedCard.card.memory = submission.memory
            let shouldRequeue = submission.memory.phase == .learning
                || submission.memory.phase == .relearning
            if shouldRequeue {
                repairQueue.append(PendingRepeat(card: repeatedCard.card))
            }
            let insertedReviewedCardID = reviewedCardIDs.insert(card.id).inserted
            let insertedReviewedItemID = reviewedItemIDs.insert(card.item.id).inserted
            pendingGradeUndo = StudyGradeUndo(
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
            await advanceSession()
            await onMutation?()
        } catch DatabaseError.cardNotFound(_) {
            await discardMissingCurrentCard(card.id)
        } catch {
            self.error = errorMapper.map(error)
        }
    }

    public func undoLastGrade() async {
        learningTime.interaction()
        guard !isGrading, !isCompletingSubmission, !isLoading, !isPreparingQueue else { return }
        guard let undo = pendingGradeUndo else { return }

        isGrading = true
        defer { isGrading = false }

        do {
            try await library.revertReview(id: undo.reviewLogID, asOf: clock())
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
            resetAttemptTiming()
            isAnswerRevealed = true
            pendingGradeUndo = nil
            await onMutation?()
        } catch {
            self.error = errorMapper.map(error)
        }
    }

    public func dismissGradeUndo() {
        pendingGradeUndo = nil
    }

    private func updateLearningTime() {
        learningTime.setBusy(isLoading || isGrading || isCompletingSubmission)
        let card = currentCard
        learningTime.setCard(itemID: card?.item.id, cardID: card?.id)
    }

    public func pauseReviewTiming() { reviewTiming.pause(); learningTime.setActive(false) }
    public func resumeReviewTiming() { reviewTiming.resume(); learningTime.setActive(true) }

    /// Re-reads the item behind the current card after it was edited mid-session,
    /// so the rest of the session shows the correction rather than the copy the
    /// queue was built from. Every queued card drawn from that item is refreshed,
    /// because one item can own several cards in the same session.
    public func reloadCurrentItem() async {
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
            self.error = errorMapper.map(error)
        }
    }

    private func refreshQueuedCards(for item: Item, itemType: ItemType) {
        func refresh(_ card: inout DueCard) {
            guard card.item.id == item.id else { return }
            card.item = item
            card.itemType = itemType
            StudyQueueOrdering.refreshRelation(in: &card)
            // Editing an item cannot change its templates, but reading the
            // template back keeps each card rendering from one revision.
            if let template = itemType.templates.first(where: { $0.id == card.template.id }) {
                card.template = template
            }
        }

        for index in queue.indices {
            refresh(&queue[index])
        }
        StudyQueueOrdering.orderWorks(in: &queue, from: index + 1)
    }

    public func skipCurrentCard() async {
        guard !isLoading, !isPreparingQueue, !isGrading, !isCompletingSubmission else { return }
        error = nil
        pendingGradeUndo = nil
        guard queue.indices.contains(index) else { return }

        materializePendingRepeats()
        let skippedCard = queue.remove(at: index)
        queue.append(skippedCard)
        isAnswerRevealed = false
        await advanceSession()
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
            ? StudyResponseEvaluator.choiceOptions(for: card)
            : []
        arrangedItems = card.template.interaction == .arrange
            ? StudyResponseEvaluator.arrangement(for: card)?.initial ?? []
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

    private func discardMissingCurrentCard(_ cardID: UUID) async {
        guard queue.indices.contains(index), queue[index].id == cardID else { return }
        queue.remove(at: index)
        isAnswerRevealed = false
        repairQueue.removeAll { $0.card.id == cardID }
        await advanceSession()
    }

    private func advanceSession() async {
        guard !isPreparingQueue else { return }
        while queue.indices.contains(index) {
            StudyQueueOrdering.separateRelated(in: &queue, at: index)
            guard queue[index].card.memory.phase == .new, queue[index].studyRelation?.work == nil else { break }
            isPreparingQueue = true
            do {
                let eligible = try await library.isNewStudyCardEligible(cardID: queue[index].id, scope: sessionScope, asOf: clock())
                isPreparingQueue = false
                if eligible { break }
                queue.remove(at: index)
            } catch {
                isPreparingQueue = false
                self.error = errorMapper.map(error)
                return
            }
        }
        guard index >= queue.count else {
            isFinished = false
            resetAttemptTiming()
            prepareCurrentInteraction()
            return
        }

        if !repairQueue.isEmpty {
            materializePendingRepeats()
            isFinished = false
            resetAttemptTiming()
            prepareCurrentInteraction()
            return
        }

        isFinished = true
        prepareCurrentInteraction()
    }

    /// Makes the deferred repair round concrete before another action changes
    /// queue order. This lets Skip move a card behind every card already waiting
    /// without creating a duplicate skipped entry.
    private func materializePendingRepeats() {
        guard !repairQueue.isEmpty else { return }

        let passStart = queue.count
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
        StudyQueueOrdering.orderWorks(in: &queue, from: passStart)
        repairQueue = []
    }

    private func loadCompleteQueue(
        scope: DeckScope,
        asOf now: Date,
        generation: UInt64,
        start: ContinuousClock.Instant,
        timing: inout StudySessionStartTiming
    ) async throws {
        let fetchStart = ContinuousClock.now
        let completeQueue = try await library.dueCards(
            scope: scope,
            asOf: now
        )
        timing.remainingFetchSeconds = fetchStart.elapsedSeconds
        guard startIsCurrent(generation) else { return }

        let publicationStart = ContinuousClock.now
        queue = completeQueue
        isFinished = queue.isEmpty
        prepareCurrentInteraction()
        if !queue.isEmpty { resetAttemptTiming() }
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
