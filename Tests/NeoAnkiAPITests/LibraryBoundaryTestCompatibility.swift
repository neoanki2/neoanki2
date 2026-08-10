import Foundation
import NeoAnkiAPI
import NeoAnkiApplication
import NeoAnkiCore

extension NeoAnkiAPIService {
    init(
        store: ItemStore,
        authorization: APIAuthorizationStore,
        pairingApprover: any APIPairingApprover = DenyAPIPairingApprover(),
        applicationVersion: String,
        authority: String = "127.0.0.1:8766",
        vocabularyRootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-api-vocabulary-\(UUID().uuidString)", isDirectory: true),
        pairingRequestLifetime: TimeInterval = 5 * 60,
        transferJobLifetime: TimeInterval = 24 * 60 * 60,
        faultInjector: any APIFaultInjector = NoAPIFaultInjector()
    ) {
        self.init(
            library: SQLiteLibraryRepository(store: store),
            authorization: authorization,
            pairingApprover: pairingApprover,
            applicationVersion: applicationVersion,
            authority: authority,
            vocabularyRootURL: vocabularyRootURL,
            pairingRequestLifetime: pairingRequestLifetime,
            transferJobLifetime: transferJobLifetime,
            faultInjector: faultInjector
        )
    }
}
