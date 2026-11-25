import Foundation
import NeoAnkiCore

public protocol PersonalVocabulary: Sendable {
    func vocabularyNotifications() async -> AsyncStream<Void>
    func vocabularyStatuses(language: String?) async throws -> [VocabularyStatus]
    func setVocabularyJudgment(_ judgment: VocabularyJudgment, for term: VocabularyTerm,
                               changeID: UUID) async throws -> VocabularyJudgmentChange
    func createVocabularySet(_ draft: VocabularySetDraft, id: UUID) async throws -> UUID
}

extension SQLiteLibraryRepository: PersonalVocabulary {
    public func vocabularyNotifications() async -> AsyncStream<Void> {
        await store.vocabularyNotifications()
    }

    public func vocabularyStatuses(language: String? = nil) async throws -> [VocabularyStatus] {
        try await store.vocabularyStatuses(language: language)
    }

    public func setVocabularyJudgment(_ judgment: VocabularyJudgment, for term: VocabularyTerm,
                                      changeID: UUID) async throws -> VocabularyJudgmentChange {
        try await store.setVocabularyJudgment(judgment, for: term, changeID: changeID)
    }

    public func createVocabularySet(_ draft: VocabularySetDraft, id: UUID) async throws -> UUID {
        try await store.createVocabularySet(draft, id: id)
    }

    public func mergeVocabularyJudgments(_ changes: [VocabularyJudgmentChange]) async throws {
        try await store.mergeVocabularyJudgments(changes)
    }

    public func vocabularyJudgments(after sequence: Int64, limit: Int) async throws -> [VocabularyJudgmentPageRow] {
        try await store.vocabularyJudgments(after: sequence, limit: limit)
    }
}
