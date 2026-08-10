import Foundation
import NeoAnkiAPI
import NeoAnkiApplication
import NeoAnkiCore
@testable import NeoAnki2

@MainActor
extension ItemsModel {
    convenience init(store: ItemStore, mediaStore: MediaStore?) {
        self.init(library: SQLiteLibraryRepository(store: store), mediaStore: mediaStore)
    }

    var store: any LibraryRepository { library as! any LibraryRepository }
}

@MainActor
extension DecksModel {
    convenience init(store: ItemStore) {
        self.init(library: SQLiteLibraryRepository(store: store))
    }
}

@MainActor
extension StudyModel {
    convenience init(
        store: ItemStore,
        remainingQueueLoadGate: (@Sendable () async -> Void)? = nil
    ) {
        self.init(
            library: SQLiteLibraryRepository(store: store),
            remainingQueueLoadGate: remainingQueueLoadGate
        )
    }

    var store: any LibraryRepository { library as! any LibraryRepository }
}

@MainActor
extension ImportModel {
    convenience init(
        itemsModel: ItemsModel,
        scopedAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess(),
        fileInspector: any ImportFileInspecting = SystemImportFileInspector()
    ) {
        self.init(
            itemsModel: itemsModel,
            library: itemsModel.library as! any LibraryRepository,
            scopedAccess: scopedAccess,
            fileInspector: fileInspector
        )
    }
}

@MainActor
extension TemplatesModel {
    convenience init(store: ItemStore) {
        self.init(library: SQLiteLibraryRepository(store: store))
    }
}

@MainActor
extension SchedulingModel {
    convenience init(store: ItemStore) {
        self.init(library: SQLiteLibraryRepository(store: store))
    }
}

@MainActor
extension PortableDeckTransferModel {
    convenience init(
        store: ItemStore,
        scopedAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess()
    ) {
        self.init(library: SQLiteLibraryRepository(store: store), scopedAccess: scopedAccess)
    }
}

@MainActor
extension APIControlModel {
    convenience init(store: ItemStore, vocabularyRootURL: URL) {
        self.init(
            library: SQLiteLibraryRepository(store: store),
            vocabularyRootURL: vocabularyRootURL
        )
    }
}

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
