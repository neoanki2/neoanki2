import Foundation
import NeoAnkiTestSupport
import Testing
@testable import NeoAnkiCore

/// Run with an optimized build and --no-parallel. Fixture creation is untimed.
@Test @MainActor func perfIndependentQueueOrdering() async throws {
    guard let scale = PerformanceScale.require() else { return }
    let type = BuiltInItemTypes.basic
    let source = (0..<scale.itemCount).map { index -> DueCard in
        let item = Item(itemTypeID: type.id, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question \(index)")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer \(index)")),
        ])
        return DueCard(card: Card(itemID: item.id, templateID: type.templates[0].id, skill: type.templates[0].skill),
                       item: item, itemType: type, template: type.templates[0])
    }
    for repetition in 0..<6 {
        var queue = source
        _ = try await PerformanceHarness.measure(flow: "independent-queue-ordering", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
            "positions": "\(min(100, source.count))",
        ]) {
            for index in 0..<min(100, queue.count) {
                StudyQueueOrdering.separateRelated(in: &queue, at: index)
            }
            return [:]
        }
        #expect(queue == source)
    }
}
