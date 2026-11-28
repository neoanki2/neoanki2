import Foundation
import NeoAnkiCore

public protocol PersonalVocabulary: Sendable {
    func vocabularyNotifications() async -> AsyncStream<Void>
    /// Statuses for terms with a judgment or cards. `expression` filters by match key.
    func vocabularyStatuses(language: String?, expression: String?) async throws -> [VocabularyStatus]
    /// A compact, versioned view of one language for highlighting text.
    func vocabularySnapshot(language: String) async throws -> VocabularySnapshot
    func setVocabularyJudgment(_ judgment: VocabularyJudgment, for term: VocabularyTerm,
                               changeID: UUID) async throws -> VocabularyJudgmentChange
    /// Record many judgments at once. Retrying the same `batchID` returns the first receipt.
    func setVocabularyJudgments(_ entries: [VocabularyJudgmentEntry], batchID: UUID) async throws -> VocabularyBatchReceipt
    /// Undo a bulk change for every term nothing has changed since.
    func undoVocabularyBatch(_ batchID: UUID, undoID: UUID) async throws -> VocabularyBatchReceipt
    func createVocabularySet(_ draft: VocabularySetDraft, id: UUID) async throws -> UUID
    func matchingVocabularySets(_ draft: VocabularySetDraft) async throws -> [VocabularySetMatch]
    func createVocabularyExample(_ draft: VocabularySetDraft, id: UUID, recognition: Bool, cloze: Bool) async throws -> UUID
    func appendVocabularyExample(_ draft: VocabularySetDraft, to itemID: UUID, exampleID: UUID, recognition: Bool, cloze: Bool) async throws
}

public extension PersonalVocabulary {
    func matchingVocabularySets(_ draft: VocabularySetDraft) async throws -> [VocabularySetMatch] { [] }

    func createVocabularyExample(_ draft: VocabularySetDraft, id: UUID, recognition: Bool, cloze: Bool) async throws -> UUID {
        guard recognition && cloze else { throw VocabularySetError.changedPreset }
        return try await createVocabularySet(draft, id: id)
    }

    func appendVocabularyExample(_ draft: VocabularySetDraft, to itemID: UUID, exampleID: UUID, recognition: Bool, cloze: Bool) async throws {
        throw VocabularySetError.changedPreset
    }

    func vocabularyStatuses(language: String?) async throws -> [VocabularyStatus] {
        try await vocabularyStatuses(language: language, expression: nil)
    }
}

extension SQLiteLibraryRepository: PersonalVocabulary {
    public func vocabularyNotifications() async -> AsyncStream<Void> {
        await store.vocabularyNotifications()
    }

    public func vocabularyStatuses(language: String?, expression: String?) async throws -> [VocabularyStatus] {
        try await store.vocabularyStatuses(language: language, expression: expression)
    }

    public func vocabularySnapshot(language: String) async throws -> VocabularySnapshot {
        try await store.vocabularySnapshot(language: language)
    }

    public func setVocabularyJudgment(_ judgment: VocabularyJudgment, for term: VocabularyTerm,
                                      changeID: UUID) async throws -> VocabularyJudgmentChange {
        try await store.setVocabularyJudgment(judgment, for: term, changeID: changeID)
    }

    public func setVocabularyJudgments(_ entries: [VocabularyJudgmentEntry],
                                       batchID: UUID) async throws -> VocabularyBatchReceipt {
        try await store.setVocabularyJudgments(entries, batchID: batchID)
    }

    public func undoVocabularyBatch(_ batchID: UUID, undoID: UUID) async throws -> VocabularyBatchReceipt {
        try await store.undoVocabularyBatch(batchID, undoID: undoID)
    }

    public func createVocabularySet(_ draft: VocabularySetDraft, id: UUID) async throws -> UUID {
        try await store.createVocabularySet(draft, id: id)
    }

    public func matchingVocabularySets(_ draft: VocabularySetDraft) async throws -> [VocabularySetMatch] {
        try await store.matchingVocabularySets(draft)
    }

    public func createVocabularyExample(_ draft: VocabularySetDraft, id: UUID, recognition: Bool, cloze: Bool) async throws -> UUID {
        try await store.createVocabularyExample(draft, id: id, recognition: recognition, cloze: cloze)
    }

    public func appendVocabularyExample(_ draft: VocabularySetDraft, to itemID: UUID, exampleID: UUID, recognition: Bool, cloze: Bool) async throws {
        try await store.appendVocabularyExample(draft, to: itemID, exampleID: exampleID, recognition: recognition, cloze: cloze)
    }

    public func mergeVocabularyJudgments(_ changes: [VocabularyJudgmentChange]) async throws {
        try await store.mergeVocabularyJudgments(changes)
    }

    /// Merge synchronized records byte-for-byte, so data from newer releases is kept.
    public func mergeVocabularyJudgmentPayloads(_ payloads: [Data]) async throws {
        try await store.mergeVocabularyJudgmentPayloads(payloads)
    }

    public func vocabularyJudgments(after sequence: Int64, limit: Int) async throws -> [VocabularyJudgmentPageRow] {
        try await store.vocabularyJudgments(after: sequence, limit: limit)
    }
}
