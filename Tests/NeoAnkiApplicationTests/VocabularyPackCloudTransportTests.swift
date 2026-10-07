import CloudKit
import Foundation
import NeoAnkiVocabularyKit
import Testing
@testable import NeoAnkiCloudSync

@Test func packCloudCatalogExcludesAssetsAndReusesProductionSchemaInSeparateZone() throws {
    #expect(CKVocabularyPackCloudTransport.zoneName != CKSyncEngineTransport.zoneName)
    #expect(CKVocabularyPackCloudTransport.catalogKeys == ["resourceKind", "payload"])
    #expect(CKVocabularyPackCloudTransport.chunkMetadataKeys == ["resourceKind", "assetHash", "assetByteSize"])
    let manifest = VocabularyPackManifest(id: "fixture", title: "Fixture", languages: ["uk"],
        capabilities: [.lexicon, .pronunciation], entryCount: 0, databaseSHA256: CloudVocabularyPack.digest(Data()))
    let data = try CloudVocabularyPack.manifestData(manifest)
    let pack = try CloudVocabularyPack(manifest: manifest, files: [
        .init(path: "manifest.json", byteCount: Int64(data.count), sha256: CloudVocabularyPack.digest(data)),
        .init(path: "lexicon.sqlite", byteCount: 0, sha256: manifest.databaseSHA256)
    ])
    let zone = CKRecordZone.ID(zoneName: CKVocabularyPackCloudTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    let record = try CKVocabularyPackCloudTransport.catalogRecord(pack, id: .init(recordName: pack.id, zoneID: zone))
    #expect(record.recordType == "LibraryResource")
    #expect(Set(record.allKeys()) == ["resourceID", "resourceKind", "payload"])
    #expect(record["resourceKind"] as? String == "vocabularyPack")
    #expect(try JSONDecoder().decode(CloudVocabularyPack.self, from: #require(record["payload"] as? Data)) == pack)
    let bytes = Data([1, 2, 3])
    let chunk = CKVocabularyPackCloudTransport.chunkRecord(id: .init(recordName: pack.chunkID(file: 1, chunk: 0), zoneID: zone),
        data: bytes, fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fixture"))
    #expect(chunk.recordType == "LibraryResource")
    #expect(Set(chunk.allKeys()) == ["resourceID", "resourceKind", "asset", "assetHash", "assetByteSize"])
    #expect(chunk["assetHash"] as? String == CloudVocabularyPack.digest(bytes))
    #expect((chunk["assetByteSize"] as? NSNumber)?.intValue == 3)
}
