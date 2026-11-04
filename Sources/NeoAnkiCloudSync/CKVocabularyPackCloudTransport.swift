import CloudKit
import Foundation
import NeoAnkiVocabularyKit

/// A separate private zone keeps large dictionary assets out of library sync batches.
public actor CKVocabularyPackCloudTransport: VocabularyPackCloudTransport {
    public static let zoneName = "NeoAnkiVocabulary"
    public static let packResourceKind = "vocabularyPack"
    public static let chunkResourceKind = "vocabularyPackChunk"
    static let catalogKeys = ["resourceKind", "payload"]
    static let chunkMetadataKeys = ["resourceKind", "assetHash", "assetByteSize"]
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private var preparedAccount: String?
    private var catalogToken: CKServerChangeToken?
    private var catalogPacks: [String: CloudVocabularyPack] = [:]
    private typealias CatalogPage = (
        modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
        deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool
    )

    public init() {}

    private func database() throws -> CKDatabase {
        try CKSyncEngineTransport.validateCurrentProcessEntitlements()
        return CKContainer(identifier: CKSyncEngineTransport.containerIdentifier).privateCloudDatabase
    }

    public func accountIdentifier() async throws -> String {
        try CKSyncEngineTransport.validateCurrentProcessEntitlements()
        let container = CKContainer(identifier: CKSyncEngineTransport.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        return try await container.userRecordID().recordName
    }

    private func prepare() async throws -> CKDatabase {
        try Task.checkCancellation()
        let account = try await accountIdentifier()
        let database = try database()
        if let previous = preparedAccount, previous != account {
            preparedAccount = nil
            catalogToken = nil; catalogPacks = [:]
            throw VocabularyPackError.ioFailure("The iCloud account changed. Retry the dictionary transfer.")
        }
        if preparedAccount != account {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            preparedAccount = account
        }
        return database
    }

    public func catalog() async throws -> [CloudVocabularyPack] {
        let database = try await prepare()
        var packs = catalogPacks
        var token = catalogToken
        var more = true
        while more {
            try Task.checkCancellation()
            // Exclude "asset" explicitly: listing a catalog must not download any dictionary bytes.
            let page: CatalogPage
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: Self.catalogKeys, resultsLimit: 200)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                token = nil; packs = [:]; catalogToken = nil; catalogPacks = [:]
                continue
            }
            for (_, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == "LibraryResource", record["resourceKind"] as? String == Self.packResourceKind else { continue }
                guard let data = record["payload"] as? Data, data.count <= CloudVocabularyPack.maximumCatalogEntryBytes else {
                    throw VocabularyPackError.invalidPackage("Invalid iCloud dictionary catalog entry.")
                }
                let pack = try JSONDecoder().decode(CloudVocabularyPack.self, from: data)
                try pack.validate()
                guard record.recordID.recordName == pack.id else {
                    throw VocabularyPackError.invalidPackage("Dictionary catalog identity does not match.")
                }
                packs[pack.id] = pack
            }
            for deletion in page.deletions { packs[deletion.recordID.recordName] = nil }
            token = page.changeToken; more = page.moreComing
        }
        // Commit only complete fetches, so a failed page is retried without losing entries.
        catalogPacks = packs; catalogToken = token
        return Array(packs.values)
    }

    public func publish(_ pack: CloudVocabularyPack) async throws {
        try pack.validate()
        let database = try await prepare()
        let id = CKRecord.ID(recordName: pack.id, zoneID: zoneID)
        let record = try Self.catalogRecord(pack, id: id)
        let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        _ = try results.saveResults[id]?.get()
        guard results.saveResults[id] != nil else { throw CKSyncEngineTransportError.unacknowledgedUpload }
    }

    public func uploadChunk(id: String, data: Data) async throws {
        guard data.count <= CloudVocabularyPack.chunkBytes else {
            throw VocabularyPackError.invalidPackage("Dictionary transfer chunk is too large.")
        }
        let database = try await prepare()
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let hash = CloudVocabularyPack.digest(data)
        let existing = try await database.records(for: [recordID], desiredKeys: Self.chunkMetadataKeys)
        if let result = existing[recordID] {
            switch result {
            case let .success(record):
                guard record.recordType == "LibraryResource", record["resourceKind"] as? String == Self.chunkResourceKind,
                      record["assetHash"] as? String == hash, (record["assetByteSize"] as? NSNumber)?.intValue == data.count else {
                    throw VocabularyPackError.invalidPackage("An iCloud dictionary chunk has conflicting content.")
                }
                return // Deterministic chunk records allow interrupted uploads to resume.
            case let .failure(error):
                if (error as? CKError)?.code != .unknownItem { throw error }
            }
        }
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("neoanki-pack-chunk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let record = Self.chunkRecord(id: recordID, data: data, fileURL: temporary)
        // Identical concurrent uploads are safe: an immutable chunk ID has the same validated bytes.
        let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        _ = try results.saveResults[recordID]?.get()
        guard results.saveResults[recordID] != nil else { throw CKSyncEngineTransportError.unacknowledgedUpload }
    }

    public func downloadChunk(id: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= CloudVocabularyPack.chunkBytes else {
            throw VocabularyPackError.invalidPackage("Invalid dictionary chunk size.")
        }
        let database = try await prepare()
        let record = try await database.record(for: CKRecord.ID(recordName: id, zoneID: zoneID))
        guard record.recordType == "LibraryResource", record["resourceKind"] as? String == Self.chunkResourceKind,
              let asset = record["asset"] as? CKAsset, let url = asset.fileURL,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == maximumBytes else {
            throw VocabularyPackError.invalidPackage("Incomplete iCloud dictionary chunk.")
        }
        let bytes = try Data(contentsOf: url)
        guard record["assetHash"] as? String == CloudVocabularyPack.digest(bytes) else {
            throw VocabularyPackError.invalidPackage("iCloud dictionary chunk failed its checksum.")
        }
        return bytes
    }

    // Reuse the production LibraryResource field types, isolated by zone and kind.
    // This does not require new record types, fields, or query indexes in CloudKit.
    static func catalogRecord(_ pack: CloudVocabularyPack, id: CKRecord.ID) throws -> CKRecord {
        let record = CKRecord(recordType: "LibraryResource", recordID: id)
        record["resourceID"] = pack.id as NSString
        record["resourceKind"] = Self.packResourceKind as NSString
        record["payload"] = try JSONEncoder().encode(pack) as NSData
        return record
    }

    static func chunkRecord(id: CKRecord.ID, data: Data, fileURL: URL) -> CKRecord {
        let record = CKRecord(recordType: "LibraryResource", recordID: id)
        record["resourceID"] = id.recordName as NSString
        record["resourceKind"] = Self.chunkResourceKind as NSString
        record["asset"] = CKAsset(fileURL: fileURL)
        record["assetHash"] = CloudVocabularyPack.digest(data) as NSString
        record["assetByteSize"] = NSNumber(value: data.count)
        return record
    }
}
