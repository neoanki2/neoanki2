import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiTestSupport
import Testing

/// Measures the actual request-to-observable-publication boundary, including
/// main-actor hops and the coalescing worker, in an optimized build.
@Test @MainActor func perfForegroundDuePublication() async throws {
    guard let scale = PerformanceScale.require() else { return }
    let (store, root) = try await PerformanceFixtures.makeStore(label: "due-publication-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date.now
    try await PerformanceFixtures.seedBasicItems(count: scale.itemCount, in: store,
        now: now.addingTimeInterval(-86_400))
    let model = LibraryFeatureModel(library: SQLiteLibraryRepository(store: store))
    await model.bootstrap(startSync: false)
    await model.awaitDevicePublication()
    for repetition in 0..<31 {
        let reference = now.addingTimeInterval(-Double(repetition))
        _ = try await PerformanceHarness.measure(flow: "foreground-due-observable-publication", layer: "app", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            await model.dueCounts.refresh(asOf: reference)
            #expect(model.dueCounts.state == .ready)
            #expect(model.dueCounts.count(for: .allDecks) == scale.itemCount)
            #expect(model.dueCounts.snapshot?.calculatedAt == reference)
            return [:]
        }
    }
    await model.awaitDevicePublication()
}
