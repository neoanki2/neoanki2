// Compiled against the real local Core/Application products by confirm.py.
// The executable creates no library, opens no UI, and uses no live services.
import Foundation
import NeoAnkiCore
import NeoAnkiApplication

struct WitnessFailure: Error { let message: String }
func check(_ condition: Bool, _ id: String, _ message: String) throws {
    guard condition else { throw WitnessFailure(message: "\(id): \(message)") }
    print("PASS \(id): \(message)")
}
struct PreviewlessStudy: LibraryStudying {
    func dueCount(scope: DeckScope, asOf: Date) async throws -> Int { 0 }
    func dueCards(scope: DeckScope, asOf: Date, limit: Int?) async throws -> [DueCard] { [] }
    func submitReview(cardID: UUID, rating: ReviewRating, asOf: Date,
                      durationMilliseconds: Int) async throws -> ReviewSubmission { throw WitnessFailure(message: "unused") }
    func revertReview(id: UUID, asOf: Date) async throws {}
}
struct UnsupportedEditor: LibraryCoordinatedItemEditing {}

@main struct ArchitectureWitnesses {
    @MainActor static func main() async throws {
        let time = Date(timeIntervalSince1970: 1_000_000)
        let order = FieldDef(name: "Order", type: .text)
        let template = Template(name: "Recall", layout: .focus, components: [],
                                interaction: .reveal, skill: .init(input: .text, output: .text, operation: .recall))
        var type = ItemType(name: "Prose Unit", fields: [order], templates: [template])
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: order.id, value: .text("7"))])
        let card = Card(itemID: item.id, templateID: template.id, skill: template.skill)
        let initial = StudyCardRelation(family: "fixed-family", work: "fixed-work", ordinal: 1)
        var recognized = DueCard(card: card, item: item, itemType: type, template: template, studyRelation: initial)
        StudyQueueOrdering.refreshRelation(in: &recognized)
        type.name = "Renamed Prose Unit"
        var renamed = DueCard(card: card, item: item, itemType: type, template: template, studyRelation: initial)
        StudyQueueOrdering.refreshRelation(in: &renamed)
        try check(recognized.studyRelation?.ordinal == 7 && renamed.studyRelation?.ordinal == 1,
                  "W1", "changing only the type name changes ordinal refresh (7 versus 1)")
        let metadataID = UUID()
        var contextual = Item(itemTypeID: type.id, fields: [.init(fieldID: metadataID,
            value: .text(#"{"format":"neoanki-context-example","target":{"language":"en","expression":"bank"}}"#))])
        let inferredFamily = StudyCardRelation.family(for: contextual)
        contextual.fields[0].value = .text(#"{"format":"another-format","target":{"language":"en","expression":"bank"}}"#)
        let ordinaryFamily = StudyCardRelation.family(for: contextual)
        try check(inferredFamily.hasPrefix("context:") && ordinaryFamily == "item:\(contextual.id.uuidString)",
                  "W2", "feature envelope format in an ordinary text field controls family identity")
        let previews = try await PreviewlessStudy().reviewSchedulePreviews(cardID: card.id, asOf: time)
        try check(previews.isEmpty, "W3", "a valid LibraryStudying conformer inherits an empty preview result")
        var refused = false
        do { _ = try await UnsupportedEditor().deleteUnchangedUnreviewedItems([], asOf: time) }
        catch let error as DatabaseError {
            if case .invalidItem(let reason) = error { refused = reason.contains("cannot safely undo") }
        }
        try check(refused, "W4", "a valid coordinated-editing conformer can reject every operation by default")
        var rejectedInteger = false
        do {
            _ = try await NativeLibraryCommands.createGeneratedDeck(on: 42,
                source: URL(fileURLWithPath: "/unused-no-file-opened"), parentDeckID: UUID())
        } catch let error as DatabaseError {
            if case .invalidItem(let reason) = error { rejectedInteger = reason.contains("cannot create a generated deck atomically") }
        }
        try check(rejectedInteger, "W5", "generated-deck command accepts Int at compile time and rejects it at runtime")
        let outcome = try await NativeLibraryCommands.perform(on: 42,
            context: .init(operation: "architecture-witness", input: Data())) { "completed" }
        try check(outcome.value == "completed" && outcome.receipt == nil,
                  "W6", "generic command wrapper can succeed with no receipt capability")
        print("6 behavioral witnesses passed; no application data or services accessed.")
    }
}
