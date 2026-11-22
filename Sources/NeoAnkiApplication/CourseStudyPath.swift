import Foundation
import NeoAnkiCore

private enum AcademyStudyFormat {
    static let lessonType = "Japanese Academy Lesson"
    static let vocabularyType = "Japanese Academy Vocabulary"
    static let sourceTagPrefix = "migaku:"
}

public protocol LibraryCourseStudying: Sendable {
    func studyCourseLessons(in scope: DeckScope) async throws -> [StudyCourseLesson]
    func markStudyCourseLessonRead(_ id: UUID, asOf: Date) async throws
}

public extension LibraryCourseStudying {
    func hasStandaloneCourseLesson(in scope: DeckScope) async throws -> Bool {
        guard case .deck = scope else { return false }
        let path = CourseStudyPath(lessons: try await studyCourseLessons(in: scope))
        return path.nextLesson(before: nil, in: scope) != nil
    }
}

extension SQLiteLibraryRepository: LibraryCourseStudying {
    public func studyCourseLessons(in scope: DeckScope) async throws -> [StudyCourseLesson] {
        try await store.studyCourseLessons(in: scope, lessonType: AcademyStudyFormat.lessonType,
            vocabularyType: AcademyStudyFormat.vocabularyType, sourceTagPrefix: AcademyStudyFormat.sourceTagPrefix)
    }

    public func markStudyCourseLessonRead(_ id: UUID, asOf now: Date) async throws {
        try await store.markStudyCourseLessonRead(id, lessonType: AcademyStudyFormat.lessonType,
            sourceTagPrefix: AcademyStudyFormat.sourceTagPrefix, asOf: now)
    }
}

/// Interleaves the readings with the scheduler's admitted vocabulary. Learned
/// reviews keep their existing schedule and lesson completion grants no grade.
public struct CourseStudyPath: Sendable {
    private var lessons: [StudyCourseLesson]
    private let unitIndexes: [UUID: Int]

    public init(lessons: [StudyCourseLesson] = []) {
        self.lessons = lessons
        unitIndexes = Dictionary(lessons.enumerated().map { ($0.element.deckID, $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
    }

    public func nextLesson(before card: DueCard?, in scope: DeckScope) -> StudyCourseLesson? {
        if let card {
            guard let unit = unitIndex(for: card) else { return nil }
            let course = lessons[unit].courseID
            return lessons[...unit].first { $0.courseID == course && !$0.isRead }
        }
        guard case .deck = scope else { return nil }
        return lessons.prefix { $0.unintroducedCards == 0 }.first { !$0.isRead }
    }

    public func isNewVocabulary(_ card: DueCard) -> Bool { unitIndex(for: card) != nil }

    public mutating func markRead(_ id: UUID) {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { return }
        lessons[index].isRead = true
    }

    public mutating func updateIntroductions(for card: DueCard, change: Int) {
        guard let index = unitIndex(for: card) else { return }
        lessons[index].unintroducedCards = max(0, lessons[index].unintroducedCards - change)
    }

    private func unitIndex(for card: DueCard) -> Int? {
        guard card.card.memory.phase == .new, card.itemType.name == AcademyStudyFormat.vocabularyType,
              card.item.tags.contains(where: { $0.hasPrefix(AcademyStudyFormat.sourceTagPrefix) }),
              let deck = card.item.deckID else { return nil }
        return unitIndexes[deck]
    }
}

public struct StudyLessonContent: Sendable {
    public let title: String
    public let blocks: [ContentValue]

    public init(item: Item, type: ItemType) throws {
        guard let heading = type.fields.first,
              case let .text(title, _)? = item.value(for: heading.id), !title.isEmpty else {
            throw DatabaseError.itemNotFound(item.id)
        }
        self.title = title
        blocks = type.fields.dropFirst().compactMap { field in
            guard let value = item.value(for: field.id), !value.isEmpty else { return nil }
            return value
        }
    }
}
