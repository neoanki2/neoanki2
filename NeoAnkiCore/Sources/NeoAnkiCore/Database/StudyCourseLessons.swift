import Foundation

/// A reading step that uses the course's existing item and deck identities.
public struct StudyCourseLesson: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let deckID: UUID
    public let courseID: UUID
    public var isRead: Bool
    public var unintroducedCards: Int

    static let readTag = "neoanki:lesson-read"

    static func position(in tags: [String], sourceTagPrefix: String) -> (Int, Int)? {
        guard tags.contains(where: { $0.hasPrefix(sourceTagPrefix) }),
              let tag = tags.first(where: { $0.hasPrefix("lesson:") }) else { return nil }
        let numbers = tag.dropFirst("lesson:".count).split(separator: ".")
        guard numbers.count == 2, let chapter = Int(numbers[0]), let lesson = Int(numbers[1]),
              chapter > 0, lesson > 0 else { return nil }
        return (chapter, lesson)
    }
}

public extension ItemStore {
    func studyCourseLessons(in scope: DeckScope, lessonType: String, vocabularyType: String,
                            sourceTagPrefix: String) async throws -> [StudyCourseLesson] {
        try await database.studyCourseLessons(in: scope, lessonType: lessonType, vocabularyType: vocabularyType,
                                              sourceTagPrefix: sourceTagPrefix)
    }

    func markStudyCourseLessonRead(_ id: UUID, lessonType: String, sourceTagPrefix: String, asOf now: Date) async throws {
        try await database.markStudyCourseLessonRead(id, lessonType: lessonType, sourceTagPrefix: sourceTagPrefix, asOf: now)
    }
}

extension SQLiteDatabase {
    func studyCourseLessons(in scope: DeckScope, lessonType: String, vocabularyType: String,
                            sourceTagPrefix: String) throws -> [StudyCourseLesson] {
        let scopeSQL: String
        let filter: String
        var bindings: [Binding] = []
        switch scope {
        case .allDecks:
            scopeSQL = ""
            filter = "AND \(scopeClause(try allDecksStudyScope(), column: "lesson.deck_id").sql)"
        case .unassigned:
            return []
        case let .deck(id, includeDescendants):
            scopeSQL = """
                WITH RECURSIVE scope_decks(id) AS (
                    VALUES (?)
                    UNION
                    SELECT decks.id FROM decks JOIN scope_decks ON decks.parent_id = scope_decks.id WHERE ?
                )
                """
            filter = "AND lesson.deck_id IN (SELECT id FROM scope_decks)"
            bindings = [.text(id.uuidString), .int(includeDescendants ? 1 : 0)]
        }
        // The original export uses one deck per lesson below its chapter. Only
        // read IDs, tags and counts here. A lesson's text and attachments load
        // when it becomes the active step. Walk the deck index so counting
        // new vocabulary never scans every new card once per lesson.
        let courseTemplate = try fetchItemType(id: VocabularySet.typeID)
            .flatMap(VocabularySet.courseRecognitionTemplate(in:))
        let rows = try query(scopeSQL + """
            SELECT lesson.id, lesson.deck_id, lesson.tags, chapter.parent_id AS course_id,
                   (SELECT COUNT(*) FROM cards INDEXED BY idx_cards_deck_due
                    JOIN items AS vocabulary ON vocabulary.id = cards.item_id
                    WHERE cards.deck_id = lesson.deck_id AND cards.phase = 'new' AND cards.is_suspended = 0
                      AND (vocabulary.item_type_id IN (SELECT id FROM item_types WHERE name = ?)
                           OR (vocabulary.item_type_id = ? AND cards.template_id = ?
                               AND EXISTS (SELECT 1 FROM json_each(CAST(vocabulary.tags AS TEXT))
                                           WHERE substr(value, 1, length(?)) = ?)))) AS new_count
            FROM items AS lesson
            JOIN decks AS unit ON unit.id = lesson.deck_id
            JOIN decks AS chapter ON chapter.id = unit.parent_id
            WHERE lesson.item_type_id IN (SELECT id FROM item_types WHERE name = ?) \(filter)
            """, bindings: bindings + [
                .text(vocabularyType), .text(VocabularySet.typeID.uuidString),
                courseTemplate.map { .text($0.id.uuidString) } ?? .null,
                .text(sourceTagPrefix), .text(sourceTagPrefix), .text(lessonType)
            ])
        let decoder = JSONDecoder()
        let parsed: [(lesson: StudyCourseLesson, chapter: Int, position: Int)] = try rows.compactMap { row in
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let deck = (row["deck_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let course = (row["course_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let tagsData = row["tags"] as? Data,
                  let newCount = row["new_count"] as? Int64 else { return nil }
            let tags = try decoder.decode([String].self, from: tagsData)
            guard let (chapter, order) = StudyCourseLesson.position(in: tags, sourceTagPrefix: sourceTagPrefix) else { return nil }
            return (.init(id: id, deckID: deck, courseID: course, isRead: tags.contains(StudyCourseLesson.readTag),
                          unintroducedCards: Int(newCount)), chapter, order)
        }
        return parsed.sorted {
            ($0.lesson.courseID.uuidString, $0.chapter, $0.position, $0.lesson.id.uuidString)
                < ($1.lesson.courseID.uuidString, $1.chapter, $1.position, $1.lesson.id.uuidString)
        }.map(\.lesson)
    }

    func markStudyCourseLessonRead(_ id: UUID, lessonType: String, sourceTagPrefix: String, asOf now: Date) throws {
        try inTransaction {
            guard let item = try fetchItem(id: id)?.item,
                  StudyCourseLesson.position(in: item.tags, sourceTagPrefix: sourceTagPrefix) != nil,
                  try fetchItemType(id: item.itemTypeID)?.name == lessonType else {
                throw DatabaseError.itemNotFound(id)
            }
            guard !item.tags.contains(StudyCourseLesson.readTag) else { return }
            try updateItemTags([(id, item.tags + [StudyCourseLesson.readTag])], now: now)
        }
    }
}
