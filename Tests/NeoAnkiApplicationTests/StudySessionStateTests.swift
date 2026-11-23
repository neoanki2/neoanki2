import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

private func sessionCard(_ question: String) -> DueCard {
    let type = BuiltInItemTypes.basic
    let item = Item(itemTypeID: type.id, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(question)),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ])
    let template = type.templates[0]
    return DueCard(card: Card(itemID: item.id, templateID: template.id, skill: template.skill),
                   item: item, itemType: type, template: template)
}

@Suite struct StudySessionStateTests {
    @Test func skipFollowsDeferredRepairAndUndoRestoresTheOriginalPass() throws {
        let first = sessionCard("First"), second = sessionCard("Second")
        var state = StudySessionState()
        state.load([first, second])
        state.recordGrade(.init(memory: .init(phase: .learning), reviewLogID: UUID()), for: first, rating: .again)
        #expect(state.currentCard?.id == second.id)
        #expect(state.remainingCount == 2)
        state.skip()
        #expect(state.queue.map(\.id) == [first.id, first.id, second.id])
        #expect(state.currentCard?.card.memory.phase == .learning)
        #expect(state.pendingGradeUndo == nil)
        let repeatCard = try #require(state.currentCard)
        state.recordGrade(.init(memory: .init(phase: .relearning), reviewLogID: UUID()), for: repeatCard, rating: .again)
        let undo = try #require(state.pendingGradeUndo)
        state.materializeRepairs()
        #expect(state.remainingCount == 2)
        state.undoGrade(undo)
        #expect(state.currentCard?.id == first.id)
        #expect(state.reviewedCount == 1)
        #expect(state.reviewedCardIDs == [first.id])
        #expect(state.queue.map(\.id) == [first.id, first.id, second.id])
    }

    @Test func repairsUseEditedContentWhileRetainingPersistedMemory() throws {
        let first = sessionCard("Before edit"), second = sessionCard("Unchanged")
        var state = StudySessionState()
        state.load([first, second])
        let memory = MemoryState(stability: 3, reps: 1, phase: .learning)
        state.recordGrade(.init(memory: memory, reviewLogID: UUID()), for: first, rating: .again)
        var edited = first.item
        edited.fields[0].value = .text("After edit")
        state.refresh(item: edited, itemType: first.itemType)
        state.materializeRepairs()
        #expect(state.queue.last?.item == edited)
        #expect(state.queue.last?.card.memory == memory)
        #expect(state.currentCard?.id == second.id)
    }

    @Test func undoRemovesTheReviewedCardsNewQueueEntry() throws {
        let first = sessionCard("First"), second = sessionCard("Second")
        var state = StudySessionState()
        state.load([first])
        state.recordGrade(.init(memory: .init(phase: .review), reviewLogID: UUID()), for: first, rating: .good)
        let undo = try #require(state.pendingGradeUndo)
        state.appendDueCards([second, first])

        state.undoGrade(undo)

        #expect(state.currentCard?.id == first.id)
        #expect(state.queue.map(\.id) == [first.id, second.id])
        #expect(state.reviewedCount == 0)
        #expect(state.remainingCount == 2)
    }

    @Test func fullQueuePreservesThePublishedHeadAndResetClearsAllHistory() {
        let first = sessionCard("Published"), second = sessionCard("Remaining")
        var state = StudySessionState()
        state.load([first])
        var edited = first.item
        edited.fields[0].value = .text("Edited head")
        state.refresh(item: edited, itemType: first.itemType)
        state.appendRemaining([first, second], excluding: first.id)
        #expect(state.queue.map(\.id) == [first.id, second.id])
        #expect(state.currentCard?.item == edited)
        state.recordSubmission(for: first)
        #expect(state.completedSubmissionCount == 1)
        #expect(state.reviewedCount == 0)
        state.reset()
        #expect(state.queue.isEmpty && state.remainingCount == 0)
        #expect(state.reviewedCardIDs.isEmpty && state.reviewedItemIDs.isEmpty)
        #expect(state.completedSubmissionCount == 0 && state.pendingGradeUndo == nil)
    }
}
