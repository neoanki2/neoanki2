import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private struct CourseFixture {
    let root: URL
    let library: SQLiteLibraryRepository
    let course: Deck
    let lessons: [Item]
    let cards: [Item]
    let now: Date

    static func make(limit: Int? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("study-course-\(UUID())")
        let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await library.bootstrap()
        let course = try await library.createDeck(Deck(name: "Japanese Academy - Level 1", newCardsPerDay: limit))
        let chapter = try await library.createDeck(Deck(name: "Chapter", parentID: course.id))
        let title = FieldDef(name: "Lesson", type: .text, isRequired: true)
        let reading = FieldDef(name: "Reading 01", type: .richText, isRequired: true)
        let lessonType = ItemType(name: "Japanese Academy Lesson", fields: [title, reading], templates: [
            Template(name: "Lesson reader", prompt: Side(slots: [Slot(source: .field(title.id))]),
                     answer: Side(slots: [Slot(source: .field(reading.id))]), interaction: .reveal,
                     skill: Skill(input: .text, output: .text, operation: .recall), generateWhen: .fieldEmpty(title.id))
        ])
        let word = FieldDef(name: "Word", type: .text, isRequired: true)
        let sentence = FieldDef(name: "Sentence", type: .text, isRequired: true)
        let answer = FieldDef(name: "Translation", type: .text, isRequired: true)
        let vocabType = ItemType(name: "Japanese Academy Vocabulary", fields: [word, sentence, answer], templates: [
            Template(name: "Word and sentence", layout: .focus, components: [
                TemplateComponent(region: .primary, purpose: .question, source: .field(word.id)),
                TemplateComponent(region: .secondary, purpose: .question, source: .field(sentence.id)),
                TemplateComponent(region: .secondary, purpose: .expectedAnswer, source: .field(answer.id),
                                  presentation: Presentation(reveal: .hiddenUntilAnswer)),
            ], interaction: .reveal, skill: Skill(input: .text, output: .text, operation: .recall))
        ])
        _ = try await library.createItemType(lessonType)
        _ = try await library.createItemType(vocabType)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var lessons: [Item] = [], cards: [Item] = []
        for index in 1...6 {
            let deck = try await library.createDeck(Deck(name: "Lesson \(index)", parentID: chapter.id))
            let lesson = Item(itemTypeID: lessonType.id, fields: [
                .init(fieldID: title.id, value: .text("Lesson \(index)")),
                .init(fieldID: reading.id, value: .rich([Span("Reading \(index)")])),
            ], tags: ["lesson:1.\(index)", "migaku:lesson-\(index)"], deckID: deck.id)
            _ = try await library.createItem(lesson, asOf: now.addingTimeInterval(Double(-100 - index)))
            lessons.append(lesson)
            if [3, 5, 6].contains(index) {
                let card = Item(itemTypeID: vocabType.id, fields: [
                    .init(fieldID: word.id, value: .text("Word \(index)")),
                    .init(fieldID: sentence.id, value: .text("Sentence \(index)")),
                    .init(fieldID: answer.id, value: .text("Answer \(index)")),
                ], tags: ["lesson:1.\(index)", "migaku:vocabulary-\(index)"], deckID: deck.id)
                _ = try await library.createItem(card, asOf: now.addingTimeInterval(Double(index - 100)))
                cards.append(card)
            }
        }
        return .init(root: root, library: library, course: course, lessons: lessons, cards: cards, now: now)
    }
}

@Test @MainActor func japaneseAcademyStudyPathReadsLessonsInOrderAndResumesFromSavedProgress() async throws {
    let fixture = try await CourseFixture.make(limit: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scope = DeckScope.deck(fixture.course.id)
    let library = fixture.library
    let study = StudyFeatureModel(library: library, scope: scope, title: fixture.course.name, clock: { fixture.now })
    await study.start()
    #expect(study.currentLesson?.id == fixture.lessons[0].id)
    #expect(study.currentCard == nil)
    #expect(try await study.loadLesson(fixture.lessons[0].id).blocks == [.rich([Span("Reading 1")])])
    await study.completeLesson(fixture.lessons[0].id)
    #expect(study.currentLesson?.id == fixture.lessons[1].id)
    #expect(study.reviewedCount == 0)
    #expect(try await library.dueCount(scope: scope, asOf: fixture.now) == 2)

    let reopened = try SQLiteLibraryRepository(databaseURL: fixture.root.appendingPathComponent("library.sqlite"))
    try await reopened.bootstrap()
    let resumed = StudyFeatureModel(library: reopened, scope: scope, title: fixture.course.name, clock: { fixture.now })
    await resumed.start()
    #expect(resumed.currentLesson?.id == fixture.lessons[1].id)
    await resumed.completeLesson(fixture.lessons[1].id)
    #expect(resumed.currentLesson?.id == fixture.lessons[2].id)
    await resumed.completeLesson(fixture.lessons[2].id)
    let first = try #require(resumed.currentCard)
    #expect(first.item.id == fixture.cards[0].id)
    #expect(SideContent.values(for: .question, in: first.template, from: first.item) == [.text("Word 3"), .text("Sentence 3")])
    #expect(!resumed.canSkip)
    resumed.revealAnswer()
    await resumed.grade(.easy)
    #expect(resumed.currentLesson?.id == fixture.lessons[3].id)
    await resumed.undoLastGrade()
    #expect(resumed.currentCard?.id == first.id)
    await resumed.grade(.easy)
    #expect(resumed.currentLesson?.id == fixture.lessons[3].id)
    await resumed.completeLesson(fixture.lessons[3].id)
    #expect(resumed.currentLesson?.id == fixture.lessons[4].id)
    await resumed.completeLesson(fixture.lessons[4].id)
    #expect(resumed.currentCard?.item.id == fixture.cards[1].id)
    resumed.revealAnswer()
    await resumed.grade(.easy)
    #expect(resumed.isComplete)
    #expect(resumed.reviewedCount == 2)
    #expect(try await reopened.studyCourseLessons(in: scope).last?.isRead == false)
}

@Test @MainActor func japaneseAcademyStandaloneLessonIsStudyableWithZeroDueCards() async throws {
    let fixture = try await CourseFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let deckID = try #require(fixture.lessons[0].deckID)
    let scope = DeckScope.deck(deckID)
    let library = fixture.library
    #expect(try await library.dueCount(scope: scope, asOf: fixture.now) == 0)
    #expect(try await library.hasStandaloneCourseLesson(in: scope))
    let study = StudyFeatureModel(library: library, scope: scope, title: "Lesson", clock: { fixture.now })
    await study.start()
    #expect(study.currentLesson?.id == fixture.lessons[0].id)
    await study.completeLesson(fixture.lessons[0].id)
    #expect(study.isComplete)
    #expect(study.reviewedCount == 0)
    #expect(try await !library.hasStandaloneCourseLesson(in: scope))
}
