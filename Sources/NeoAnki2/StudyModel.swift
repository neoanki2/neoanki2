import Foundation
import NeoAnkiCore

struct PendingGradeUndo: Equatable, Sendable {
    let reviewLogID: UUID
    let previousIndex: Int
    let previousReviewedCount: Int
    let previousReviewedCardIDs: Set<UUID>
    let rating: ReviewRating
    let requeuedCardID: UUID?
}

@MainActor
@Observable
final class StudyModel {
    private(set) var queue: [DueCard] = []
    private(set) var index = 0
    private(set) var isAnswerRevealed = false
    private(set) var isLoading = false
    private(set) var isGrading = false
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
    private(set) var reviewedCardIDs: Set<UUID> = []

    let store: ItemStore
    private var repairQueue: [DueCard] = []

    init(store: ItemStore) {
        self.store = store
    }

    var currentCard: DueCard? {
        guard !isFinished, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var progressLabel: String {
        guard !queue.isEmpty else { return "" }
        return "Card \(min(index + 1, queue.count)) of \(queue.count)"
    }

    var headerLabel: String {
        guard !scopeLabel.isEmpty else { return progressLabel }
        guard !progressLabel.isEmpty else { return scopeLabel }
        return "\(scopeLabel) · \(progressLabel)"
    }

    var cardsReviewed: Int {
        reviewedCount
    }

    var completionSummary: String {
        let reviewNoun = reviewedCount == 1 ? "review" : "reviews"
        let cardCount = reviewedCardIDs.count
        let cardNoun = cardCount == 1 ? "card" : "cards"
        return "Completed \(reviewedCount) \(reviewNoun) across \(cardCount) \(cardNoun)"
    }

    var canUndoLastGrade: Bool {
        pendingGradeUndo != nil
    }

    func startSession(scope: StudyScope = .allDecks) async {
        isLoading = true
        errorMessage = nil
        isFinished = false
        isAnswerRevealed = false
        index = 0
        reviewedCount = 0
        reviewedCardIDs = []
        repairQueue = []
        scopeLabel = scope.label
        pendingGradeUndo = nil
        didFailToLoad = false

        do {
            queue = try await store.fetchDueCards(scope: scope.filter)
            isFinished = queue.isEmpty
            prepareCurrentInteraction()
        } catch {
            errorMessage = userFacingError(from: error)
            queue = []
            isFinished = true
            didFailToLoad = true
        }

        isLoading = false
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
        guard currentCard?.template.interaction == .record else { return }
        interactionMessage = "Play your recording and the reference, then grade your recall."
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
        }
    }

    func grade(_ rating: ReviewRating) async {
        guard !isGrading else { return }
        errorMessage = nil
        guard let card = currentCard else { return }

        isGrading = true
        defer { isGrading = false }

        let previousIndex = index
        let now = Date.now

        do {
            let submission = try await store.submitReviewWithReceipt(
                cardID: card.id,
                rating: rating,
                now: now
            )
            var repeatedCard = card
            repeatedCard.card.memory = submission.memory
            let shouldRequeue = submission.memory.phase == .learning
                || submission.memory.phase == .relearning
            if shouldRequeue {
                repairQueue.append(repeatedCard)
            }
            pendingGradeUndo = PendingGradeUndo(
                reviewLogID: submission.reviewLogID,
                previousIndex: previousIndex,
                previousReviewedCount: reviewedCount,
                previousReviewedCardIDs: reviewedCardIDs,
                rating: rating,
                requeuedCardID: shouldRequeue ? card.id : nil
            )
            index += 1
            reviewedCount += 1
            reviewedCardIDs.insert(card.id)
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
            try await store.revertReview(reviewLogID: undo.reviewLogID)
            if let requeuedCardID = undo.requeuedCardID {
                repairQueue.removeAll { $0.id == requeuedCardID }
                if let queuedRepeat = queue.indices.last(where: {
                    $0 > undo.previousIndex && queue[$0].id == requeuedCardID
                }) {
                    queue.remove(at: queuedRepeat)
                }
            }
            index = undo.previousIndex
            reviewedCount = undo.previousReviewedCount
            reviewedCardIDs = undo.previousReviewedCardIDs
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

    func skipCurrentCard() {
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
        repairQueue.removeAll { $0.id == cardID }
        advanceSession()
    }

    private func advanceSession() {
        guard index >= queue.count else {
            isFinished = false
            prepareCurrentInteraction()
            return
        }

        if !repairQueue.isEmpty {
            queue.append(contentsOf: repairQueue)
            repairQueue = []
            isFinished = false
            prepareCurrentInteraction()
            return
        }

        isFinished = true
        prepareCurrentInteraction()
    }
}
