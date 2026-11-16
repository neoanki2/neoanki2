import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Observation

typealias PendingGradeUndo = StudyGradeUndo
typealias StudyStartTiming = StudySessionStartTiming

/// Mac presentation names over the single native session engine. No queue or
/// review state is mirrored here; Swift Observation follows the nested model.
@MainActor @Observable
final class StudyModel {
    let session: StudyFeatureModel
    let library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses

    init(
        library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses,
        remainingQueueLoadGate: (@Sendable () async -> Void)? = nil
    ) {
        self.library = library
        session = StudyFeatureModel(library: library, scope: .allDecks, title: "All Decks",
                                    errorMapper: MacStudyErrorMapper())
        session.remainingQueueLoadGate = remainingQueueLoadGate
    }

    var queue: [DueCard] { session.queue }
    var currentCard: DueCard? { session.currentCard }
    var index: Int { session.index }
    var isAnswerRevealed: Bool { session.isAnswerRevealed }
    var isLoading: Bool { session.isLoading }
    var isPreparingQueue: Bool { session.isPreparingQueue }
    var isGrading: Bool { session.isGrading }
    var isCompletingSubmission: Bool { session.isCompletingSubmission }
    var isFinished: Bool { session.isFinished }
    var didFailToLoad: Bool { session.didFailToLoad }
    var pendingGradeUndo: PendingGradeUndo? { session.pendingGradeUndo }
    var typedAnswer: String { session.typedAnswer }
    var reviewResponse: String? { session.reviewResponse }
    var answerEvaluation: AnswerEvaluation? { session.answerEvaluation }
    var choiceOptions: [String] { session.choiceOptions }
    var selectedChoice: String? { session.selectedChoice }
    var arrangedItems: [String] { session.arrangedItems }
    var selectedArrangementIndex: Int? { session.selectedArrangementIndex }
    var interactionMessage: String? { session.interactionMessage }
    var reviewedCount: Int { session.reviewedCount }
    var completedSubmissionCount: Int { session.completedSubmissionCount }
    var reviewedCardIDs: Set<UUID> { session.reviewedCardIDs }
    var reviewedItemIDs: Set<UUID> { session.reviewedItemIDs }
    var lastStartTiming: StudyStartTiming { session.lastStartTiming }
    var learningTime: LearningTimeTracker { session.learningTime }
    var errorMessage: String? { session.error?.message }
    var scopeLabel: String { session.title }
    var remainingCardCount: Int { session.remainingCount }

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
        session.canUndo
    }

    func startSession(scope: StudyScope = .allDecks) async {
        await session.start(scope: scope.filter, title: scope.label)
    }
    func revealAnswer() { session.revealAnswer() }
    func updateTypedAnswer(_ answer: String) { session.updateTypedAnswer(answer) }
    func submitTypedAnswer() { session.submitTypedAnswer() }
    func selectChoice(_ option: String) { session.selectChoice(option) }
    func submitChoice() { session.submitChoice() }
    func selectArrangementItem(at index: Int) { session.selectArrangementItem(at: index) }
    func moveSelectedArrangementItem(by offset: Int) { session.moveSelectedArrangementItem(by: offset) }
    func submitArrangement() { session.submitArrangement() }
    func completeRecording() { session.completeRecording() }
    func performPrimaryAction() { session.performPrimaryAction() }
    func dismissGradeUndo() { session.dismissGradeUndo() }
    func pauseReviewTiming() { session.pauseReviewTiming() }
    func resumeReviewTiming() { session.resumeReviewTiming() }
    func grade(_ rating: ReviewRating) async { await session.grade(rating) }
    func undoLastGrade() async { await session.undoLastGrade() }
    func reloadCurrentItem() async { await session.reloadCurrentItem() }
    func skipCurrentCard() async { await session.skip() }
    func completeAudioSubmission(_ draft: StudyResponseDraft) async -> Bool {
        await session.completeAudioSubmission(draft)
    }
}

private struct MacStudyErrorMapper: UserFacingErrorMapping {
    func map(_ error: any Error) -> NeoAnkiApplication.UserFacingError {
        .init(title: "Could Not Complete Study Action", message: UserFacingError.message(from: error))
    }
}
