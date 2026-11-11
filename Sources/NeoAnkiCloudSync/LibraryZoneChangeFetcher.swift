import Foundation
import NeoAnkiApplication

/// Explicit zone reads do not depend on CKSyncEngine's push/foreground hints.
/// Keep their token separate from the engine's opaque serialization and commit
/// each page with its durable inbox before requesting the next page.
actor LibraryZoneChangeFetcher {
    struct Page: Sendable {
        let records: [SyncRecordEnvelope]
        let token: Data
        let moreComing: Bool
    }

    private let metadataStore: SyncMetadataStore

    init(metadataStore: SyncMetadataStore) {
        self.metadataStore = metadataStore
    }

    func fetch(page: @Sendable (Data?) async throws -> Page) async throws -> [SyncRecordEnvelope] {
        var token = try await metadataStore.load().libraryZoneChangeToken
        var received: [SyncRecordEnvelope] = []
        while true {
            try Task.checkCancellation()
            let result = try await page(token)
            try await metadataStore.receiveZonePage(result.records, token: result.token)
            received += result.records
            token = result.token
            if !result.moreComing { return received }
        }
    }
}
