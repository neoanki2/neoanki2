@testable import NeoAnkiCloudSync
import Testing

struct CKSyncEngineTransportTests {
    @Test func acceptsTheConfiguredContainerEntitlement() throws {
        try CKSyncEngineTransport.validateContainerIdentifiers([
            "iCloud.example.unrelated",
            CKSyncEngineTransport.containerIdentifier,
        ])
    }

    @Test func rejectsMissingContainerEntitlementsBeforeCreatingCloudKitObjects() {
        #expect(throws: CKSyncEngineTransportError.missingContainerEntitlement(
            CKSyncEngineTransport.containerIdentifier
        )) {
            try CKSyncEngineTransport.validateContainerIdentifiers(nil)
        }
        #expect(throws: CKSyncEngineTransportError.missingContainerEntitlement(
            CKSyncEngineTransport.containerIdentifier
        )) {
            try CKSyncEngineTransport.validateContainerIdentifiers(["iCloud.example.unrelated"])
        }
    }
}
