import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

public typealias StudyGradeUndo = NeoAnkiApplication.StudyGradeUndo

public struct ExtraStudyStartUnavailable: LocalizedError, Sendable {
    public var errorDescription: String? {
        "This deck’s study availability changed. Check what’s ready on the deck."
    }
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
    private var sessionState = StudySessionState() { didSet { updateLearningTime() } }
    public var queue: [DueCard] { sessionState.queue }
    public var index: Int { sessionState.index }
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
    public private(set) var dueCheckError: UserFacingError?
    public var pendingGradeUndo: StudyGradeUndo? { sessionState.pendingGradeUndo }
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
        case .type, .cloze:
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
    public var reviewedCount: Int { sessionState.reviewedCount }
    public var completedSubmissionCount: Int { sessionState.completedSubmissionCount }
    public var reviewedCardIDs: Set<UUID> { sessionState.reviewedCardIDs }
    public var reviewedItemIDs: Set<UUID> { sessionState.reviewedItemIDs }
    public private(set) var lastStartTiming = StudySessionStartTiming()

    private let library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses
    private var extraLibrary: (any LibraryExtraStudying)? { library as? any LibraryExtraStudying }
    private var extraCardLimit: Int?
    public var isExtraStudy: Bool { extraCardLimit != nil }
    private let itemSnapshotReader: (any LibraryStudyItemSnapshotReading)?
    /// Repeats only need the newly persisted scheduling state while waiting for
    /// the current pass to finish. Item/type/template content stays canonical
    /// in `queue`, avoiding a second hydrated copy of every failed card.
    public private(set) var sessionScope: DeckScope = .allDecks
    public let learningTime: LearningTimeTracker
    private var reviewTiming = ReviewTimingTracker()
    private var coursePath = CourseStudyPath() { didSet { updateLearningTime() } }
    public private(set) var isCompletingLesson = false { didSet { updateLearningTime() } }
    private var expectedQueueCount = 0
    private var startGeneration: UInt64 = 0
    private var itemReloadGeneration: UInt64 = 0
    package var remainingQueueLoadGate: (@Sendable () async -> Void)?

    public init(
        library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses,
        scope: DeckScope,
        title: String,
        mediaStore: MediaStore? = nil,
        itemSnapshotReader: (any LibraryStudyItemSnapshotReading)? = nil,
        onMutation: (@MainActor @Sendable () async -> Void)? = nil,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper(),
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.library = library
        self.itemSnapshotReader = itemSnapshotReader ?? (library as? any LibraryStudyItemSnapshotReading)
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
    public var canUndo: Bool {
        pendingGradeUndo != nil && !isLoading && !isGrading && !isCompletingSubmission && !isPreparingQueue
            && !isCompletingLesson
    }

    /// Native shells share action availability. Platform adapters add only
    /// local restrictions such as an open editor or microphone permission.
    public var canShowAnswer: Bool { currentCard != nil && !isAnswerRevealed && !isLoading && !isFinished }
    public var canGrade: Bool {
        currentCard != nil && isAnswerRevealed && !isLoading && !isGrading
            && !isCompletingSubmission && !isPreparingQueue
    }
    public var canSkip: Bool {
        guard let card = currentCard, !isLoading, !isGrading, !isCompletingSubmission, !isPreparingQueue else { return false }
        return !coursePath.isNewVocabulary(card)
    }
    public var supportsRevealWithoutChecking: Bool {
        switch currentCard?.template.interaction {
        case .type, .choose, .arrange, .record: true
        default: false
        }
    }

    public func start() async { await start(scope: sessionScope, title: title, extraCardLimit: extraCardLimit) }

    public func extraStudyAvailability() async throws -> Int {
        guard isComplete, !isExtraStudy else { return 0 }
        return try await extraLibrary?.availableExtraStudyCardCount(scope: sessionScope, asOf: clock()) ?? 0
    }

    public func startExtraStudy(scope: DeckScope, title: String, limit: Int) async throws {
        await start(scope: scope, title: title, extraCardLimit: limit)
        try Task.checkCancellation()
        if let error = error ?? dueCheckError { throw error }
        guard !isFinished else {
            throw ExtraStudyStartUnavailable()
        }
    }
    public func skip() async { await skipCurrentCard() }
    public func dismissError() { error = nil }

    public var currentLesson: StudyCourseLesson? {
        guard !isFinished, !isLoading else { return nil }
        return nextLesson
    }

    private var nextLesson: StudyCourseLesson? {
        if isExtraStudy, sessionState.currentCard == nil { return nil }
        return coursePath.nextLesson(before: sessionState.currentCard, in: sessionScope)
    }

    public func retryLoadingCards() async {
        guard !isLoading, !isGrading, !isCompletingSubmission, !isCompletingLesson else { return }
        if dueCheckError != nil {
            if isExtraStudy {
                dueCheckError = nil
                await advanceSession()
            } else {
                await checkForMoreDueCards()
            }
        } else if didFailToLoad {
            await start()
        }
    }

    public var currentCard: DueCard? {
        guard !isFinished, currentLesson == nil else { return nil }
        return sessionState.currentCard
    }

    public func loadLesson(_ id: UUID) async throws -> StudyLessonContent {
        guard let record = try await library.item(id: id) else { throw DatabaseError.itemNotFound(id) }
        return try StudyLessonContent(item: record.item, type: record.itemType)
    }

    public func completeLesson(_ id: UUID) async {
        guard currentLesson?.id == id, !isCompletingLesson, !isPreparingQueue, !isGrading,
              let courses = library as? any LibraryCourseStudying else { return }
        let generation = startGeneration
        isCompletingLesson = true
        defer { isCompletingLesson = false }
        do {
            try await courses.markStudyCourseLessonRead(id, asOf: clock())
            guard generation == startGeneration else { return }
            coursePath.markRead(id)
            error = nil
            if isExtraStudy {
                await advanceSession()
                return
            }
            if sessionState.currentCard == nil, nextLesson == nil {
                await checkForMoreDueCards()
                return
            }
            prepareCurrentInteraction()
            resetAttemptTiming()
        } catch {
            self.error = errorMapper.map(error)
        }
    }

    public var remainingCardCount: Int {
        guard !isFinished else { return 0 }
        if isPreparingQueue && !isExtraStudy {
            return expectedQueueCount
        }
        guard queue.indices.contains(index) else { return 0 }

        // A failed card waits once in the next repair round while untouched
        // cards remain once in the current queue. Counting both pending groups
        // keeps Again stable without rescanning a potentially large session.
        return sessionState.remainingCount
    }

    public func start(scope: DeckScope, title: String) async {
        await start(scope: scope, title: title, extraCardLimit: nil)
    }

    private func start(scope: DeckScope, title: String, extraCardLimit: Int?) async {
        let start = ContinuousClock.now
        guard !isGrading, !isCompletingSubmission, !isCompletingLesson else { return }
        let sessionNow = clock()
        var timing = StudySessionStartTiming()
        startGeneration &+= 1
        let generation = startGeneration
        lastStartTiming = timing
        isLoading = true
        isPreparingQueue = false
        expectedQueueCount = 0
        sessionState.reset()
        coursePath = CourseStudyPath()
        prepareCurrentInteraction()
        error = nil
        dueCheckError = nil
        isFinished = false
        isAnswerRevealed = false
        reviewTiming = ReviewTimingTracker()
        self.title = title
        sessionScope = scope
        didFailToLoad = false
        self.extraCardLimit = extraCardLimit

        do {
            if let extraCardLimit {
                if let courses = library as? any LibraryCourseStudying {
                    let lessons = try await courses.studyCourseLessons(in: scope)
                    guard startIsCurrent(generation) else { return }
                    coursePath = CourseStudyPath(lessons: lessons)
                }
                let cards: [DueCard]
                if coursePath.nextLesson(before: nil, in: scope) != nil {
                    cards = []
                } else {
                    cards = try await extraLibrary?.extraStudyCards(scope: scope, asOf: clock(), limit: extraCardLimit) ?? []
                }
                guard startIsCurrent(generation) else { return }
                sessionState.load(cards)
                await advanceSession()
                guard startIsCurrent(generation) else { return }
                isLoading = false
                timing.firstReadySeconds = start.elapsedSeconds
                timing.totalSeconds = timing.firstReadySeconds
                lastStartTiming = timing
                return
            }

            let countStart = ContinuousClock.now
            let dueCount = try await library.dueCount(
                scope: scope,
                asOf: sessionNow
            )
            timing.dueCountSeconds = countStart.elapsedSeconds
            guard startIsCurrent(generation) else { return }

            if let courses = library as? any LibraryCourseStudying {
                let lessons = try await courses.studyCourseLessons(in: scope)
                guard startIsCurrent(generation) else { return }
                coursePath = CourseStudyPath(lessons: lessons)
            }

            if dueCount == 0 {
                let publicationStart = ContinuousClock.now
                sessionState.load([])
                isFinished = nextLesson == nil
                isLoading = false
                prepareCurrentInteraction()
                updateLearningTime()
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
            sessionState.load([firstCard])
            expectedQueueCount = dueCount
            isFinished = false
            isPreparingQueue = true
            prepareCurrentInteraction()
            resetAttemptTiming()
            isLoading = false
            updateLearningTime()
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
            sessionState.appendRemaining(completeQueue, excluding: firstCard.id)
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
            sessionState.load([])
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
        guard let card = currentCard, !isAnswerRevealed,
              card.template.interaction == .type || VocabularySet.supportsTypedResponse(card) else { return }
        let evaluation = VocabularySet.supportsTypedResponse(card)
            ? VocabularySet.check(typedAnswer, for: card)
            : StudyResponseEvaluator.evaluate(typedAnswer, for: card)
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
        case .cloze where currentCard.map(VocabularySet.supportsTypedResponse) == true && !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            submitTypedAnswer()
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
                if let extraLibrary, isExtraIntroduction(card) {
                    return try await extraLibrary.completeExtraStudyAudioSubmission(draft, scope: sessionScope, asOf: clock())
                }
                return try await library.completeAudioSubmission(draft, submittedAt: clock())
            }
            sessionState.recordSubmission(for: card)
            isAnswerRevealed = false
            await advanceSession()
            await onMutation?()
            return true
        } catch is ExtraStudyCardUnavailable {
            await discardMissingCurrentCard(card.id)
            return false
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

        let now = clock()

        do {
            let activeEnd = learningTime.sessionMilliseconds
            let answerStart = answerActiveStart ?? activeEnd
            let context = StatisticsReviewContext(sessionID: learningTime.sessionID, deviceID: learningTime.deviceID,
                promptMilliseconds: max(0, answerStart - attemptActiveStart), answerMilliseconds: max(0, activeEnd - answerStart), checkedCorrect: answerEvaluation == .unavailable || answerEvaluation == nil ? nil : answerEvaluation == .correct)
            let submission = try await StatisticsCapture.$context.withValue(context) {
                let duration = reviewTiming.elapsedMilliseconds()
                if let extraLibrary, isExtraIntroduction(card) {
                    return try await extraLibrary.submitExtraStudyReview(cardID: card.id, scope: sessionScope,
                                                                         rating: rating, asOf: now, durationMilliseconds: duration)
                }
                return try await library.submitReview(cardID: card.id, rating: rating,
                                                      asOf: now, durationMilliseconds: duration)
            }
            coursePath.updateIntroductions(for: card, change: 1)
            sessionState.recordGrade(submission, for: card, rating: rating)
            isAnswerRevealed = false
            await advanceSession()
            await onMutation?()
        } catch DatabaseError.cardNotFound(_) {
            await discardMissingCurrentCard(card.id)
        } catch is ExtraStudyCardUnavailable {
            await discardMissingCurrentCard(card.id)
        } catch {
            self.error = errorMapper.map(error)
        }
    }

    public func undoLastGrade() async {
        learningTime.interaction()
        guard !isGrading, !isCompletingSubmission, !isLoading, !isPreparingQueue else { return }
        guard !isCompletingLesson, let undo = pendingGradeUndo else { return }

        isGrading = true
        defer { isGrading = false }

        do {
            try await library.revertReview(id: undo.reviewLogID, asOf: clock())
            sessionState.undoGrade(undo)
            if let card = sessionState.currentCard { coursePath.updateIntroductions(for: card, change: -1) }
            dueCheckError = nil
            isFinished = false
            isAnswerRevealed = true
            prepareCurrentInteraction()
            resetAttemptTiming()
            isAnswerRevealed = true
            if isExtraIntroduction(sessionState.currentCard) {
                await advanceSession()
                if sessionState.currentCard?.id != undo.reviewedCardID { isAnswerRevealed = false }
            }
            await onMutation?()
        } catch {
            self.error = errorMapper.map(error)
        }
    }

    public func dismissGradeUndo() {
        sessionState.dismissUndo()
    }

    private func updateLearningTime() {
        learningTime.setBusy(isLoading || isGrading || isCompletingSubmission || isCompletingLesson)
        let card = currentCard
        learningTime.setCard(itemID: currentLesson?.id ?? card?.item.id, cardID: card?.id)
    }

    public func pauseReviewTiming() { reviewTiming.pause(); learningTime.setActive(false) }
    public func resumeReviewTiming() { reviewTiming.resume(); learningTime.setActive(true) }

    /// Re-reads the item behind the current card after it was edited mid-session,
    /// so the rest of the session shows the correction rather than the copy the
    /// queue was built from. Every queued card drawn from that item is refreshed,
    /// because one item can own several cards in the same session.
    public func reloadCurrentItem() async {
        guard !isLoading, !isPreparingQueue, !isGrading, !isCompletingSubmission,
              let current = currentCard else { return }
        let itemID = current.item.id
        let cardID = current.id
        let position = index
        let generation = startGeneration
        itemReloadGeneration &+= 1
        let reloadGeneration = itemReloadGeneration

        do {
            let snapshot: ItemCardSnapshot?
            let compatibilityItem: (item: Item, itemType: ItemType)?
            if let reader = itemSnapshotReader {
                snapshot = try await reader.studyItemSnapshot(id: itemID)
                compatibilityItem = nil
            } else {
                compatibilityItem = try await library.item(id: itemID)
                snapshot = nil
            }
            let stillEligible: Bool
            if isExtraIntroduction(current), let extraLibrary {
                stillEligible = try await extraLibrary.isExtraStudyCardEligible(cardID: cardID, scope: sessionScope, asOf: clock())
            } else {
                stillEligible = true
            }
            guard !isLoading, !isPreparingQueue, !isGrading, !isCompletingSubmission,
                  startIsCurrent(generation), itemReloadGeneration == reloadGeneration,
                  currentCard?.id == cardID, index == position else { return }
            guard stillEligible else {
                await discardMissingCurrentCard(cardID)
                return
            }
            if let compatibilityItem {
                sessionState.refresh(item: compatibilityItem.item, itemType: compatibilityItem.itemType)
            } else {
                sessionState.reconcile(itemID: itemID, snapshot: snapshot)
            }
            error = nil
            if currentCard?.id != cardID {
                isAnswerRevealed = false
                resetAttemptTiming()
                await advanceSession()
                return
            }
            // An answer already on screen keeps its feedback: re-deriving the
            // interaction here would clear the message the learner is reading,
            // and the choices or ordering they answered no longer matter.
            if !isAnswerRevealed {
                prepareCurrentInteraction()
            }
        } catch {
            guard !isLoading, !isPreparingQueue, !isGrading, !isCompletingSubmission,
                  startIsCurrent(generation), itemReloadGeneration == reloadGeneration,
                  currentCard?.id == cardID, index == position else { return }
            self.error = errorMapper.map(error)
        }
    }

    public func skipCurrentCard() async {
        guard canSkip else { return }
        error = nil
        sessionState.dismissUndo()

        sessionState.skip()
        isAnswerRevealed = false
        await advanceSession()
    }

    private func prepareCurrentInteraction() {
        // A delayed editor read cannot update a different attempt, including
        // skipping through a queue and returning to the same card ID/index.
        itemReloadGeneration &+= 1
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
        sessionState.discardCurrent()
        isAnswerRevealed = false
        await advanceSession()
    }

    private func isExtraIntroduction(_ card: DueCard?) -> Bool {
        guard isExtraStudy, let card else { return false }
        return !sessionState.reviewedCardIDs.contains(card.id)
    }

    private func advanceSession() async {
        guard !isPreparingQueue else { return }
        while queue.indices.contains(index) {
            sessionState.separateRelated()
            let card = queue[index]
            let isExtra = isExtraIntroduction(card)
            guard isExtra || (card.card.memory.phase == .new && card.studyRelation?.work == nil) else { break }
            let generation = startGeneration
            let cardID = queue[index].id
            let position = index
            isPreparingQueue = true
            do {
                let eligible: Bool
                if isExtra, let extraLibrary {
                    eligible = try await extraLibrary.isExtraStudyCardEligible(cardID: cardID, scope: sessionScope, asOf: clock())
                } else {
                    eligible = try await library.isNewStudyCardEligible(cardID: cardID, scope: sessionScope, asOf: clock())
                }
                guard generation == startGeneration, sessionState.currentCard?.id == cardID, index == position else { return }
                isPreparingQueue = false
                guard !Task.isCancelled else { return }
                if eligible { break }
                sessionState.discardCurrent()
            } catch {
                guard generation == startGeneration, sessionState.currentCard?.id == cardID, index == position else { return }
                isPreparingQueue = false
                guard !Task.isCancelled else { return }
                if isExtra {
                    dueCheckError = errorMapper.map(error)
                } else {
                    self.error = errorMapper.map(error)
                }
                return
            }
        }
        guard index >= queue.count else {
            isFinished = false
            resetAttemptTiming()
            prepareCurrentInteraction()
            return
        }

        if sessionState.hasPendingRepairs {
            sessionState.materializeRepairs()
            isFinished = false
            resetAttemptTiming()
            prepareCurrentInteraction()
            return
        }

        if isExtraStudy {
            isFinished = true
            prepareCurrentInteraction()
        } else {
            await checkForMoreDueCards()
        }
    }

    private func checkForMoreDueCards() async {
        let generation = startGeneration
        isLoading = true
        dueCheckError = nil
        do {
            // Time, sync, or a change in eligibility can add due cards after
            // the startup read. Check again only after the current pass and
            // its repairs are exhausted.
            let cards = try await library.dueCards(scope: sessionScope, asOf: clock())
            guard generation == startGeneration else { return }
            try Task.checkCancellation()
            sessionState.appendDueCards(cards)
            sessionState.separateRelated()
            isFinished = cards.isEmpty && nextLesson == nil
            isLoading = false
            prepareCurrentInteraction()
            if !isFinished { resetAttemptTiming() }
        } catch {
            guard generation == startGeneration else { return }
            dueCheckError = errorMapper.map(error)
            isLoading = false
        }
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
        sessionState.load(completeQueue)
        isFinished = queue.isEmpty && nextLesson == nil
        prepareCurrentInteraction()
        if !queue.isEmpty { resetAttemptTiming() }
        isLoading = false
        updateLearningTime()
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
