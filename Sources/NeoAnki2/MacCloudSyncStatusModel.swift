import Foundation
import NeoAnkiApplication
import Observation
import OSLog

/// Settings observes the service's live status, including automatic retries.
/// The service has no status stream, so sample its actor-local state without
/// performing extra network operations.
@MainActor
@Observable
final class MacCloudSyncStatusModel {
    private static let logger = Logger(subsystem: "com.neoanki2.app", category: "CloudSyncStatus")
    private(set) var status: SyncStatus = .offline
    @ObservationIgnored private var service: (any SyncService)?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private let interval: Duration

    init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    deinit { monitor?.cancel() }

    func observe(_ service: any SyncService) {
        stop()
        self.service = service
        let interval = interval
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }

    func refresh() async {
        guard let service else { return }
        let expectedGeneration = generation
        let latest = await service.status()
        guard expectedGeneration == generation, !Task.isCancelled else { return }
        updateStatus(latest)
    }

    func stop(status: SyncStatus = .offline) {
        generation += 1
        monitor?.cancel()
        monitor = nil
        service = nil
        updateStatus(status)
    }

    private func updateStatus(_ latest: SyncStatus) {
        guard status != latest else { return }
        status = latest
        // Only the status enum is logged, never library records or content.
        Self.logger.notice("Cloud sync status: \(String(describing: latest), privacy: .public)")
    }
}
