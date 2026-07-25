import Foundation
import NeoAnkiCore

struct PendingGradeUndo: Equatable, Sendable {
    let cardID: UUID
    let previousMemory: MemoryState
    let previousIndex: Int
    let rating: ReviewRating
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
    private(set) var scopeLabel = ""
    private(set) var pendingGradeUndo: PendingGradeUndo?
    private(set) var typedAnswer = ""
    private(set) var answerEvaluation: AnswerEvaluation?
    private(set) var choiceOptions: [String] = []
    private(set) var selectedChoice: String?
    private(set) var arrangedItems: [String] = []
    private(set) var selectedArrangementIndex: Int?
    private(set) var interactionMessage: String?

    let store: ItemStore

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
        index
    }

    var completionSummary: String {
        let count = queue.count
        if count == 1 {
            return "Reviewed 1 card"
        }
        return "Reviewed \(count) cards"
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
        scopeLabel = scope.label
        pendingGradeUndo = nil

        do {
            queue = try await store.fetchDueCards(scope: scope.filter)
            isFinished = queue.isEmpty
            prepareCurrentInteraction()
        } catch {
            errorMessage = userFacingError(from: error)
            queue = []
            isFinished = true
        }

        isLoading = false
    }

    func revealAnswer() {
        guard currentCard != nil else { return }
        isAnswerRevealed = true
    }

    func updateTypedAnswer(_ answer: String) {
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

        let previousMemory = card.card.memory
        let previousIndex = index

        do {
            _ = try await store.submitReview(cardID: card.id, rating: rating)
            pendingGradeUndo = PendingGradeUndo(
                cardID: card.id,
                previousMemory: previousMemory,
                previousIndex: previousIndex,
                rating: rating
            )
            index += 1
            isAnswerRevealed = false

            if index >= queue.count {
                isFinished = true
            } else {
                prepareCurrentInteraction()
            }
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
            try await store.revertReview(cardID: undo.cardID, restoring: undo.previousMemory)
            index = undo.previousIndex
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

        if index >= queue.count {
            isFinished = true
        } else {
            prepareCurrentInteraction()
        }
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
        isFinished = index >= queue.count
    }
}
