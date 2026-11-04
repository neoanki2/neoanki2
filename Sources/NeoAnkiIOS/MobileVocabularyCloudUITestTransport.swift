#if os(iOS)
import Foundation
import NeoAnkiVocabularyKit

/// Test-only remote pack fixture; ordinary launches always use the composition root's CloudKit adapter.
public enum MobileVocabularyCloudUITestTransport {
    public static func makeIfRequested() -> (any VocabularyPackCloudTransport)? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              process.environment["NEOANKI_TEST_SCENARIO"] == "mobile-vocabulary-cloud" else { return nil }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-vocabulary-fixture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let entries = root.appendingPathComponent("entries.jsonl")
            let entry = LexicalEntry(id: "en:swift", language: "en", canonicalForm: .init(text: .init("swift")),
                senses: [.init(id: "meaning", definitions: [.init(text: .init("Moving quickly and smoothly."))])])
            try (JSONEncoder().encode(entry) + Data([0x0A])).write(to: entries)
            let package = root.appendingPathComponent("Acceptance.neovocab")
            _ = try VocabularyPackCompiler.compile(jsonlURL: entries, to: package,
                descriptor: .init(id: "acceptance.cloud", title: "Cloud Acceptance Lexicon", languages: ["en"], capabilities: [.lexicon]))
            return Fixture(source: package)
        } catch { return nil }
    }

    private actor Fixture: VocabularyPackCloudTransport {
        let source: URL
        let transfer = VocabularyPackCloudTransfer()
        init(source: URL) { self.source = source }
        func accountIdentifier() -> String { "cloud-ui-fixture" }
        func catalog() async throws -> [CloudVocabularyPack] { [try await transfer.describe(at: source)] }
        func publish(_ pack: CloudVocabularyPack) {}
        func uploadChunk(id: String, data: Data) {}
        func downloadChunk(id: String, maximumBytes: Int) async throws -> Data {
            let pack = try await transfer.describe(at: source)
            let parts = id.split(separator: "-")
            guard parts.count == 3, parts[0] == pack.id, let file = Int(parts[1]), let chunk = Int64(parts[2]),
                  pack.files.indices.contains(file), chunk >= 0 else {
                throw VocabularyPackError.invalidPackage("Unexpected test chunk.")
            }
            let offset = chunk * Int64(CloudVocabularyPack.chunkBytes)
            if file == 0 {
                let data = try CloudVocabularyPack.manifestData(pack.manifest)
                return Data(data[Int(offset)..<Int(offset) + maximumBytes])
            }
            let handle = try FileHandle(forReadingFrom: source.appendingPathComponent(pack.files[file].path))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: maximumBytes) ?? Data()
        }
    }
}
#endif
