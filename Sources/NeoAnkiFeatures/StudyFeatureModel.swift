import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

private struct RepairEntry: Sendable { var card: Card }

public struct StudyCompletion: Sendable, Equatable {
    public let reviews: Int
    public let uniqueCards: Int
    public let uniqueItems: Int
}

@MainActor @Observable
public final class StudyFeatureModel: Identifiable {
    public let id = UUID()
    public let title: String
    public private(set) var queue: [DueCard] = []
    public private(set) var index = 0
    public private(set) var isAnswerRevealed = false
    public private(set) var isLoading = false
    public private(set) var isPreparingQueue = false
    public private(set) var isGrading = false
    public private(set) var isCompletingSubmission = false
    public private(set) var error: UserFacingError?
    public private(set) var typedAnswer = ""
    public private(set) var answerEvaluation: NeoAnkiCore.AnswerEvaluation?
    public private(set) var choiceOptions: [String] = []
    public private(set) var selectedChoice: String?
    public private(set) var arrangedItems: [String] = []
    public private(set) var selectedArrangementIndex: Int?
    public private(set) var interactionMessage: String?
    public private(set) var completion = StudyCompletion(reviews: 0, uniqueCards: 0, uniqueItems: 0)

    private let library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses
    private let scope: DeckScope
    private let errorMapper: any UserFacingErrorMapping
    private let onMutation: (@MainActor @Sendable () async -> Void)?
    public let mediaStore: MediaStore?
    private var repairQueue: [RepairEntry] = []
    private var reviewedCards: Set<UUID> = []
    private var reviewedItems: Set<UUID> = []
    private var pendingUndo: (reviewID: UUID, index: Int, rating: ReviewRating, requeuedID: UUID?)?
    private var generation: UInt64 = 0
    private var cardStartedAt = Date.now

    public init(
        library: any LibraryBrowsing & LibraryStudying & LibraryStudyResponses,
        scope: DeckScope,
        title: String,
        mediaStore: MediaStore? = nil,
        onMutation: (@MainActor @Sendable () async -> Void)? = nil,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper()
    ) {
        self.library = library
        self.scope = scope
        self.title = title
        self.mediaStore = mediaStore
        self.onMutation = onMutation
        self.errorMapper = errorMapper
    }

    public var currentCard: DueCard? { queue.indices.contains(index) ? queue[index] : nil }
    public var isComplete: Bool { !isLoading && !isPreparingQueue && currentCard == nil && repairQueue.isEmpty }
    public var remainingCount: Int { max(0, queue.count - index) + repairQueue.count }
    public var canUndo: Bool { pendingUndo != nil && !isGrading }

    public func start() async {
        generation &+= 1
        let currentGeneration = generation
        isLoading = true
        isPreparingQueue = false
        error = nil
        index = 0
        queue = []
        repairQueue = []
        completion = .init(reviews: 0, uniqueCards: 0, uniqueItems: 0)
        do {
            let count = try await library.dueCount(scope: scope, asOf: .now)
            guard generation == currentGeneration else { return }
            guard count > 0 else { isLoading = false; return }
            let first = try await library.dueCards(scope: scope, asOf: .now, limit: 1)
            guard generation == currentGeneration else { return }
            queue = first
            isLoading = false
            isPreparingQueue = count > first.count
            prepareInteraction()
            guard isPreparingQueue else { return }
            let all = try await library.dueCards(scope: scope, asOf: .now, limit: nil)
            guard generation == currentGeneration else { return }
            queue = all
            isPreparingQueue = false
        } catch {
            guard generation == currentGeneration else { return }
            self.error = errorMapper.map(error)
            isLoading = false
            isPreparingQueue = false
        }
    }

    public func revealAnswer() { if currentCard != nil { isAnswerRevealed = true } }
    public func updateTypedAnswer(_ value: String) { typedAnswer = value; answerEvaluation = nil }
    public func selectChoice(_ value: String) { guard choiceOptions.contains(value) else { return }; selectedChoice = value }
    public func selectArrangementItem(at value: Int) { guard arrangedItems.indices.contains(value) else { return }; selectedArrangementIndex = value }
    public func moveSelectedArrangementItem(by offset: Int) {
        guard let source = selectedArrangementIndex, arrangedItems.indices.contains(source + offset) else { return }
        arrangedItems.swapAt(source, source + offset); selectedArrangementIndex = source + offset
    }

    public func performPrimaryAction() {
        guard let card = currentCard else { return }
        switch card.template.interaction {
        case .reveal, .cloze: revealAnswer()
        case .type:
            guard !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { interactionMessage = "Enter an answer, or reveal it to self-grade."; return }
            answerEvaluation = StudyResponseEvaluator.evaluate(typedAnswer, for: card); isAnswerRevealed = true
        case .choose:
            guard let selectedChoice else { interactionMessage = "Choose an option, or reveal it to self-grade."; return }
            answerEvaluation = StudyResponseEvaluator.evaluate(selectedChoice, for: card); isAnswerRevealed = true
        case .arrange:
            guard !arrangedItems.isEmpty else { revealAnswer(); return }
            answerEvaluation = StudyResponseEvaluator.isCorrectArrangement(arrangedItems, for: card); isAnswerRevealed = true
        case .record:
            interactionMessage = StudyResponseEvaluator.hasReferenceAudio(for: card)
                ? "Replay your recording, then compare it with the reference."
                : "Replay your recording and compare it with the written answer."
            isAnswerRevealed = true
        case .audioSubmission:
            break
        }
    }

    /// Completes a one-off Audio Submission without manufacturing a review.
    public func completeAudioSubmission(_ draft: StudyResponseDraft) async -> Bool {
        guard let card = currentCard,
              card.id == draft.cardID,
              card.template.interaction == .audioSubmission,
              !isCompletingSubmission,
              !isPreparingQueue
        else { return false }
        isCompletingSubmission = true
        defer { isCompletingSubmission = false }
        do {
            _ = try await library.completeAudioSubmission(draft, submittedAt: .now)
            pendingUndo = nil
            reviewedCards.insert(card.id)
            reviewedItems.insert(card.item.id)
            completion = .init(
                reviews: completion.reviews,
                uniqueCards: reviewedCards.count,
                uniqueItems: reviewedItems.count
            )
            index += 1
            advance()
            await onMutation?()
            return true
        } catch {
            self.error = errorMapper.map(error)
            return false
        }
    }

    public func grade(_ rating: ReviewRating) async {
        guard let card = currentCard, !isGrading, !isPreparingQueue else { return }
        isGrading = true
        defer { isGrading = false }
        do {
            let duration = max(0, Int(Date.now.timeIntervalSince(cardStartedAt) * 1_000))
            let receipt = try await library.submitReview(cardID: card.id, rating: rating, asOf: .now, durationMilliseconds: duration)
            var repeated = card.card
            repeated.memory = receipt.memory
            let requeue = receipt.memory.phase == .learning || receipt.memory.phase == .relearning
            if requeue { repairQueue.append(.init(card: repeated)) }
            pendingUndo = (receipt.reviewLogID, index, rating, requeue ? card.id : nil)
            reviewedCards.insert(card.id)
            reviewedItems.insert(card.item.id)
            completion = .init(reviews: completion.reviews + 1, uniqueCards: reviewedCards.count, uniqueItems: reviewedItems.count)
            index += 1
            advance()
            await onMutation?()
        } catch { self.error = errorMapper.map(error) }
    }

    public func undoLastGrade() async {
        guard let undo = pendingUndo, !isGrading else { return }
        isGrading = true
        defer { isGrading = false }
        do {
            try await library.revertReview(id: undo.reviewID, asOf: .now)
            if let id = undo.requeuedID { repairQueue.removeAll { $0.card.id == id } }
            index = undo.index
            completion = .init(reviews: max(0, completion.reviews - 1), uniqueCards: reviewedCards.count, uniqueItems: reviewedItems.count)
            pendingUndo = nil
            isAnswerRevealed = true
            await onMutation?()
        } catch { self.error = errorMapper.map(error) }
    }

    public func skip() { guard currentCard != nil, !isPreparingQueue else { return }; pendingUndo = nil; index += 1; advance() }

    public func reloadCurrentItem() async {
        guard let itemID = currentCard?.item.id, let loaded = try? await library.item(id: itemID) else { return }
        for position in queue.indices where queue[position].item.id == itemID {
            queue[position].item = loaded.item
            queue[position].itemType = loaded.itemType
            if let template = loaded.itemType.templates.first(where: { $0.id == queue[position].template.id }) {
                queue[position].template = template
            }
        }
        prepareInteraction()
    }

    public func dismissError() { error = nil }

    private func advance() {
        isAnswerRevealed = false
        cardStartedAt = .now
        if index >= queue.count, !repairQueue.isEmpty {
            for entry in repairQueue {
                if var source = queue.first(where: { $0.id == entry.card.id }) { source.card = entry.card; queue.append(source) }
            }
            repairQueue = []
        }
        prepareInteraction()
    }

    private func prepareInteraction() {
        typedAnswer = ""; answerEvaluation = nil; selectedChoice = nil; selectedArrangementIndex = nil; interactionMessage = nil
        guard let card = currentCard else { choiceOptions = []; arrangedItems = []; return }
        choiceOptions = card.template.interaction == .choose ? StudyResponseEvaluator.choiceOptions(for: card) : []
        arrangedItems = card.template.interaction == .arrange ? (StudyResponseEvaluator.arrangement(for: card)?.initial ?? []) : []
    }
}
