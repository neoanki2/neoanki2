import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

@testable import NeoAnki2

private func reportStudyStartTiming(_ label: String, _ timing: StudyStartTiming) {
    print(
        "neoanki-study-start label=\(label)"
            + " due_count_s=\(timing.dueCountSeconds)"
            + " item_type_check_s=\(timing.itemTypeCheckSeconds)"
            + " head_fetch_s=\(timing.headFetchSeconds)"
            + " head_publication_s=\(timing.headPublicationSeconds)"
            + " remaining_fetch_s=\(timing.remainingFetchSeconds)"
            + " remaining_publication_s=\(timing.remainingPublicationSeconds)"
            + " first_ready_s=\(timing.firstReadySeconds)"
            + " total_s=\(timing.totalSeconds)"
    )
}

@Test @MainActor func perfStudyStartPhases() async throws {
    guard let scale = PerformanceScale.require(flow: "study-start-phases") else { return }

    let (emptyStore, emptyDirectory) = try await PerformanceFixtures.makeStore(
        label: "study-start-empty"
    )
    defer { try? FileManager.default.removeItem(at: emptyDirectory) }
    let emptyModel = StudyModel(store: emptyStore)
    await emptyModel.startSession()
    reportStudyStartTiming("empty", emptyModel.lastStartTiming)
    #expect(emptyModel.isFinished)

    let (normalStore, normalDirectory) = try await PerformanceFixtures.makeStore(
        label: "study-start-normal"
    )
    defer { try? FileManager.default.removeItem(at: normalDirectory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: 1, in: normalStore)
    let normalModel = StudyModel(store: normalStore)
    await normalModel.startSession()
    reportStudyStartTiming("normal", normalModel.lastStartTiming)
    #expect(normalModel.currentCard != nil)

    let (largeStore, largeDirectory) = try await PerformanceFixtures.makeStore(
        label: "study-start-\(scale.rawValue)"
    )
    defer { try? FileManager.default.removeItem(at: largeDirectory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: scale.itemCount, in: largeStore)

    let coldModel = StudyModel(store: largeStore)
    let coldTask = Task { await coldModel.startSession() }
    await Task.yield()
    while coldModel.isLoading {
        await Task.yield()
    }
    let coldFirstReady = coldModel.lastStartTiming.firstReadySeconds
    await coldTask.value
    reportStudyStartTiming("cold-\(scale.rawValue)", coldModel.lastStartTiming)
    #expect(coldFirstReady >= 0)
    #expect(coldModel.queue.count == scale.itemCount)

    let warmModel = StudyModel(store: largeStore)
    await warmModel.startSession()
    reportStudyStartTiming("warm-\(scale.rawValue)", warmModel.lastStartTiming)
    #expect(warmModel.queue.count == scale.itemCount)

    let now = Date.now
    let countStart = ContinuousClock.now
    let dueCount = try await largeStore.dueCount(asOf: now)
    let countDuration = countStart.duration(to: .now)
    let headStart = ContinuousClock.now
    let head = try await largeStore.fetchDueCards(asOf: now, limit: 1)
    let headDuration = headStart.duration(to: .now)
    let countSeconds = Double(countDuration.components.seconds)
        + Double(countDuration.components.attoseconds) / 1e18
    let headSeconds = Double(headDuration.components.seconds)
        + Double(headDuration.components.attoseconds) / 1e18
    print(
        "neoanki-study-start label=warm-store-phases"
            + " count_s=\(countSeconds)"
            + " head_s=\(headSeconds)"
    )
    #expect(dueCount == scale.itemCount)
    #expect(head.count == 1)
}
