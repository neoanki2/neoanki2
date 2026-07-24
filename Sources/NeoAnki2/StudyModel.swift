import Foundation
import NeoAnkiCore

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

    func startSession() async {
        isLoading = true
        errorMessage = nil
        isFinished = false
        isAnswerRevealed = false
        index = 0

        do {
            queue = try await store.fetchDueCards()
            isFinished = queue.isEmpty
        } catch {
            errorMessage = userFacingError(from: error)
            queue = []
            isFinished = true
        }

        isLoading = false
    }

    func revealAnswer() {
        guard currentCard?.template.interaction == .reveal else { return }
        isAnswerRevealed = true
    }

    func grade(_ rating: ReviewRating) async {
        errorMessage = nil
        guard let card = currentCard else { return }

        isGrading = true
        defer { isGrading = false }

        do {
            _ = try await store.submitReview(cardID: card.id, rating: rating)
            index += 1
            isAnswerRevealed = false

            if index >= queue.count {
                isFinished = true
            }
        } catch {
            errorMessage = userFacingError(from: error)
        }
    }

    func skipCurrentCard() {
        errorMessage = nil
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
}
