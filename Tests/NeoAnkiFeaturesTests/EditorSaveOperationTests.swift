import Foundation
import NeoAnkiApplication
import NeoAnkiFeatures
import Testing

private enum EditorWriteFailure: Error { case unavailable }
private struct EditorWriteFailureMapper: UserFacingErrorMapping {
    func map(_ error: any Error) -> UserFacingError {
        UserFacingError(title: "Storage unavailable", message: "Your correction is still here.", recoverySuggestion: "Try again.")
    }
}

private actor EditorCommitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation {
            continuation = $0
            observer?.resume(); observer = nil
        }
    }
    func waitUntilHeld() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite @MainActor struct EditorSaveOperationTests {
    @Test func duplicateSubmissionsAndDismissalAreExcludedDuringCommit() async throws {
        let state = EditorSaveOperation()
        let gate = EditorCommitGate()
        var writes = 0
        let save = Task {
            await state.perform {
                writes += 1
                await gate.hold()
                return "Committed"
            }
        }
        await gate.waitUntilHeld()
        #expect(state.phase == .saving)
        #expect(!state.canDismiss)
        let duplicate: String? = await state.perform { writes += 1; return "Duplicate" }
        #expect(duplicate == nil && writes == 1)
        state.beginEditing()
        #expect(state.isSaving)
        await gate.release()
        #expect(await save.value == "Committed")
        #expect(state.phase == .saved && state.canDismiss)
        let afterCommit: String? = await state.perform { writes += 1; return "Duplicate after commit" }
        #expect(afterCommit == nil && writes == 1)
    }

    @Test func failureIsExplicitAndCanBeRetriedWithoutPublishingSuccess() async {
        let state = EditorSaveOperation()
        let draft = "Keep this unsaved correction"
        let presented = UserFacingError(title: "Write failed", message: "Injected failure", recoverySuggestion: "Retry the save.")
        let failure: String? = await state.perform {
            throw presented
        }
        #expect(failure == nil)
        #expect(!state.isSaving && state.canDismiss)
        #expect(state.error == presented)
        let success: String? = await state.perform { draft }
        #expect(success == draft)
        #expect(state.phase == .saved && state.error == nil)
    }

    @Test func storageErrorsAreMappedWithoutPublishingSuccess() async {
        let mapper = EditorWriteFailureMapper()
        let state = EditorSaveOperation(errorMapper: mapper)
        let result: Bool? = await state.perform { throw EditorWriteFailure.unavailable }
        #expect(result == nil)
        #expect(state.phase == .failed(mapper.map(EditorWriteFailure.unavailable)))
        #expect(state.canDismiss && !state.isSaving)
    }
}
