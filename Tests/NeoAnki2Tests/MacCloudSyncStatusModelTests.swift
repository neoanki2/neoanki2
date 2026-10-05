import Foundation
import NeoAnkiApplication
import Testing
@testable import NeoAnki2

private actor ChangingSyncService: SyncService {
    private var value: SyncStatus = .offline
    func start() async {}
    func synchronize() async {}
    func stop() async {}
    func status() async -> SyncStatus { value }
    func issues() async -> [SyncIssue] { [] }
    func setStatus(_ status: SyncStatus) { value = status }
}

@MainActor
private func waitForStatus(_ status: SyncStatus, in model: MacCloudSyncStatusModel) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while model.status != status, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.status == status)
}

@MainActor
@Test func macSyncSettingsRecoversFromOfflineWithoutManualSync() async throws {
    let service = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .milliseconds(5))
    defer { model.stop() }
    model.observe(service)
    #expect(model.status == .offline)
    await service.setStatus(.syncing)
    try await waitForStatus(.syncing, in: model)
    let current = SyncStatus.current(lastSync: Date(timeIntervalSince1970: 100))
    await service.setStatus(current)
    try await waitForStatus(current, in: model)
    await service.setStatus(.needsAttention(issueCount: 1))
    try await waitForStatus(.needsAttention(issueCount: 1), in: model)
}

@MainActor
@Test func disablingMacSyncStopsOldStatusUpdates() async throws {
    let service = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .milliseconds(5))
    model.observe(service)
    await service.setStatus(.syncing)
    try await waitForStatus(.syncing, in: model)
    model.stop()
    await service.setStatus(.current(lastSync: .now))
    try await Task.sleep(for: .milliseconds(25))
    #expect(model.status == .offline)
}

@MainActor
@Test func replacingMacSyncServiceDoesNotDisplayOldServiceStatus() async throws {
    let old = ChangingSyncService()
    let replacement = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .milliseconds(5))
    defer { model.stop() }
    model.observe(old)
    await old.setStatus(.syncing)
    try await waitForStatus(.syncing, in: model)
    model.observe(replacement)
    await old.setStatus(.current(lastSync: .now))
    await replacement.setStatus(.accountUnavailable)
    try await waitForStatus(.accountUnavailable, in: model)
}
