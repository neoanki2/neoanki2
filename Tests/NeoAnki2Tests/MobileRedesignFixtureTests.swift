import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiSharedUI
import Testing
@testable import NeoAnkiMobile

@Test func answerReviewFixtureHasOneCheckableAnswerAndSeparateNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    try await MobileRedesignUITestSeeder.seedAnswerReview(library: library)
    let cards = try await library.dueCards(scope: .allDecks, asOf: .now)
    #expect(cards.count == 1)
    let card = try #require(cards.first)
    #expect(StudyResponseEvaluator.acceptedAnswers(for: card) == ["They canceled the meeting."])
    let review = StudyAnswerReviewProjection(components: SideContent.resolvedComponents(for: card.template, from: card.item))
    #expect(review.explanation.count == 2)
    #expect(review.prompt.count == 3)
}

@Test func mobileRedesignFixturesSeedEveryInteractionAndAllLaterJourneys() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()

    try await MobileRedesignUITestSeeder.seed(library: library)

    let types = try await library.loadItemTypes().itemTypes.filter { $0.name.hasPrefix("Fixture ") }
    #expect(Set(types.flatMap(\.templates).map { $0.interaction.rawValue }) == Set(Interaction.allCases.map(\.rawValue)))
    for type in types {
        #expect(try await library.countItems(itemTypeID: type.id) == 1)
    }
    let authoring = try await library.items(scope: .allDecks, sort: .createdAscending, search: "Authoring media fixture")
    #expect(authoring.count == 1)
    let attention = try await library.items(scope: .allDecks, sort: .createdAscending, search: "Repeatedly forgotten prompt")
    #expect(try #require(attention.first).schedule?.needsAttention == true)
    #expect(try await library.studyResponses().count == 1)
    #expect(try await library.items(scope: .allDecks, sort: .createdAscending, search: "A long question invites careful reading").count == 1)

    let count = try await library.items(scope: .allDecks, sort: .createdAscending, search: "").count
    #expect(count == Interaction.allCases.count + 4)
    try await MobileRedesignUITestSeeder.seed(library: library)
    #expect(try await library.items(scope: .allDecks, sort: .createdAscending, search: "").count == count)
}
