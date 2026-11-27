#if os(iOS)
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

/// Explicit fixture dependency composed by the app root. Presentation receives
/// scenario operations, never the repository used to seed an isolated test library.
public struct MobileUITestFixtures: Sendable {
    private let library: any LibraryRepository
    public init(library: any LibraryRepository) { self.library = library }
    @MainActor func prepareStudio() async throws {
        try await MobileItemTypeStudioUITestSeeder.seedIfRequested(library: library)
    }
    @MainActor func prepareFitStudyArea() async throws {
        try await MobileFitStudyAreaUITestFixture.seedIfRequested(library: library)
    }
    @MainActor func prepareRedesign() async throws {
        try await MobileRedesignUITestSeeder.seedIfRequested(library: library)
    }
    @MainActor func prepareVocabulary(_ model: MobileVocabularyLibraryModel) async throws {
        try await model.seedVisualFixtureIfRequested(library: library)
    }
    @MainActor func prepareGrammarExercise() async throws {
        guard let raw = ProcessInfo.processInfo.environment["NEOANKI_TEST_GRAMMAR_MODE"],
              let mode = StudyExercise.Mode(rawValue: raw == "replacement" ? "target" : raw) else { return }
        let exercise: StudyExercise
        let solution: String
        let cue: String
        switch mode {
        case .target where raw == "replacement":
            exercise = .init(mode: .target, parts: ["We ", " the service."],
                             targets: [.init(original: "need call", choices: ["need to call", "need call"])],
                             answers: [["need to call"]])
            solution = "We need to call the service."
            cue = "We must call the service"
        case .target:
            exercise = .init(mode: .target, parts: ["Then I opened ", " file from another folder."],
                             targets: [.init(choices: ["a", "an", "the"], allowsOmission: true)], answers: [["a"]])
            solution = "Then I opened a file from another folder."
            cue = "A different file"
        case .rewrite:
            exercise = .init(mode: .rewrite, prompt: "It works.", answers: [["Does it work?"]])
            solution = "Does it work?"
            cue = "Yes/no question"
        case .choose:
            exercise = .init(mode: .choose, options: [
                .init(id: "wrong", label: "I need an advice."),
                .init(id: "right", label: "I need advice."),
            ], correctOptionID: "right")
            solution = "I need advice."
            cue = "Standard American English"
        }
        let field = FieldDef(name: "Exercise", type: .studyExercise, isRequired: true)
        let type = ItemType(name: "Grammar exercise fixture", fields: [field], templates: [
            Template(name: mode.title, layout: .split, components: [
                TemplateComponent(region: .label, purpose: .supporting, source: .literal(cue)),
                TemplateComponent(region: .primary, purpose: .question, source: .field(field.id)),
                TemplateComponent(region: .secondary, purpose: .expectedAnswer, source: .literal(solution),
                                  presentation: .init(reveal: .hiddenUntilAnswer)),
            ], interaction: mode == .choose ? .choose : .type,
               skill: .init(input: .text, output: .freeResponse, operation: .apply)),
        ])
        _ = try await library.createItemType(type)
        _ = try await library.createItem(Item(
            itemTypeID: type.id, fields: [.init(fieldID: field.id, value: .studyExercise(exercise))]
        ))
    }
    func createOcclusionType(_ type: ItemType) async throws { _ = try await library.createItemType(type) }
    func reserveOcclusionImage(_ data: Data) async throws -> MediaRef {
        try await library.reserveMedia(data: data, kind: .image, altText: "", asOf: .now).reference
    }
    func saveOcclusionItem(_ item: Item, isNew: Bool) async throws {
        if isNew { _ = try await library.createItem(item, asOf: .now) }
        else { _ = try await library.updateItem(item, asOf: .now) }
    }
}
private struct MobileUITestFixturesKey: EnvironmentKey {
    static let defaultValue: MobileUITestFixtures? = nil
}
public extension EnvironmentValues {
    var mobileUITestFixtures: MobileUITestFixtures? {
        get { self[MobileUITestFixturesKey.self] }
        set { self[MobileUITestFixturesKey.self] = newValue }
    }
}
#endif
