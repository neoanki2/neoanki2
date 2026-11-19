import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiTestSupport
import Testing

/// Same immutable library, comparing discarded screen models with the Mac's
/// retained workspace. Run opt-in with Release optimization; setup is untimed.
@Test @MainActor func perfStatisticsRoundTripNavigation() async throws {
    guard let scale = PerformanceScale.require() else { return }
    let (store, root) = try await PerformanceFixtures.makeStore(label: "statistics-navigation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date.now
    let past = now.addingTimeInterval(-30 * 86_400)
    try await PerformanceFixtures.seedBasicItems(count: scale.itemCount, in: store, now: past)
    for card in try await store.fetchDueCards(asOf: past, limit: 32) {
        _ = try await store.submitReview(cardID: card.id, rating: .good, now: past)
    }
    let library = SQLiteLibraryRepository(store: store)
    let factory = LibraryFeatureFactory(library: library)
    let workspace = factory.makeStatisticsWorkspace()
    for repetition in 0..<6 {
        _ = try await PerformanceHarness.measure(flow: "statistics-recreated-round-trip", layer: "app", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let home = factory.makeStatistics()
            home.query.period = .today
            await home.refresh(now: now)
            let report = factory.makeStatistics()
            await report.refresh(now: now)
            #expect(home.snapshot != nil && report.snapshot != nil)
            #expect(home.error == nil && report.error == nil)
            return [:]
        }
    }
    await workspace.home().refresh(now: now, force: false)
    await workspace.report().refresh(now: now, force: false)
    for repetition in 0..<31 {
        _ = try await PerformanceHarness.measure(flow: "statistics-retained-round-trip", layer: "app", metadata: [
            "repetition": "\(repetition)", "warmup": "\(repetition == 0)",
        ]) {
            let home = workspace.home(), report = workspace.report()
            await home.refresh(now: now.addingTimeInterval(1), force: false)
            await report.refresh(now: now.addingTimeInterval(1), force: false)
            #expect(home.snapshot?.asOf == now && report.snapshot?.asOf == now)
            #expect(!home.isLoading && !report.isLoading)
            return [:]
        }
    }
}
