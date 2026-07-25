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
        } catch {
            errorMessage = userFacingError(from: error)
            queue = []
            isFinished = true
        }

        isLoading = false
    }

    func revealAnswer() {
        guard let interaction = currentCard?.template.interaction,
              StudySupport.isSupportedInteraction(interaction)
        else { return }
        isAnswerRevealed = true
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
        }
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
