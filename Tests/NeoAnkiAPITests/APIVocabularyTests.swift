import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing

private struct VocabularyAPIFixtureFile {
    let id: String
    let path: String
    let bytes: Data
}

private func vocabularyTestDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "neoanki-vocabulary-api-\(label)-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func compileVocabularyAPIFixture(
    in parent: URL,
    name: String,
    packID: String
) throws -> (url: URL, entries: [LexicalEntry], media: Data) {
    let media = Data([0x49, 0x44, 0x33, 1, 2, 3, 4])
    let sourceMedia = parent.appendingPathComponent("\(name)-media", isDirectory: true)
    let speaker = sourceMedia.appendingPathComponent("speaker", isDirectory: true)
    try FileManager.default.createDirectory(at: speaker, withIntermediateDirectories: true)
    try media.write(to: speaker.appendingPathComponent("word.mp3"))

    let targetLocation = "Ми ".unicodeScalars.count
    let first = LexicalEntry(
        id: "uk:застосувати:1",
        language: "uk",
        canonicalForm: LexicalForm(
            text: LocalizedText("застосувати", language: "uk"), kind: "lemma"
        ),
        forms: [
            LexicalForm(
                text: LocalizedText("застосували", language: "uk"),
                kind: "inflected",
                grammaticalFeatures: [.init(name: "tense", value: "past")]
            ),
        ],
        pronunciations: [
            Pronunciation(
                scheme: "recording",
                representations: [
                    .audio(.init(path: "speaker/word.mp3", mimeType: "audio/mpeg")),
                ]
            ),
        ],
        senses: [
            LexicalSense(
                id: "sense-1",
                definitions: [.init(text: LocalizedText("Використати щось.", language: "uk"))],
                examples: [
                    UsageExample(
                        text: LocalizedText("Ми застосували метод.", language: "uk"),
                        target: ExampleTarget(
                            exactText: "застосували",
                            scalarRange: .init(
                                location: targetLocation,
                                length: "застосували".unicodeScalars.count
                            )
                        )
                    ),
                ],
                labels: ["verb"]
            ),
        ],
        frequency: 0.75,
        provenance: .init(
            sourceID: "fixture", sourceName: "Vocabulary API fixture",
            recordID: "record-1", attribution: "Test data", license: "CC0"
        )
    )
    let second = LexicalEntry(
        id: "uk:застава:1",
        language: "uk",
        canonicalForm: LexicalForm(text: LocalizedText("застава", language: "uk"))
    )
    let entries = [first, second]
    let jsonl = parent.appendingPathComponent("\(name).jsonl")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var jsonlBytes = Data()
    for entry in entries {
        jsonlBytes.append(try encoder.encode(entry))
        jsonlBytes.append(0x0A)
    }
    try jsonlBytes.write(to: jsonl)
    let packURL = parent.appendingPathComponent("\(name).neovocab", isDirectory: true)
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(
            id: packID,
            title: "Ukrainian \(name)",
            summary: "Offline test vocabulary",
            languages: ["uk"],
            capabilities: [.lexicon, .pronunciation, .morphology, .corpus],
            provenance: .init(sourceID: "fixture", sourceName: "Vocabulary API fixture")
        ),
        options: .init(mediaDirectoryURL: sourceMedia)
    )
    return (packURL, entries, media)
}

private func vocabularyFixtureFiles(at packURL: URL) throws -> [VocabularyAPIFixtureFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    let enumerator = try #require(FileManager.default.enumerator(
        at: packURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ))
    var result: [VocabularyAPIFixtureFile] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let prefix = packURL.standardizedFileURL.path + "/"
        let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        result.append(.init(
            id: UUID().uuidString.lowercased(),
            path: path,
            bytes: try Data(contentsOf: url)
        ))
    }
    return result.sorted { $0.path < $1.path }
}

private func vocabularyAPI(
    root: URL,
    store: ItemStore? = nil,
    authorization: APIAuthorizationStore? = nil
) async throws -> (NeoAnkiAPIService, ItemStore, APIAuthorizationStore) {
    let actualStore: ItemStore
    if let store {
        actualStore = store
    } else {
        actualStore = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
        try await actualStore.bootstrap()
    }
    let actualAuthorization = authorization ?? APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    return (
        NeoAnkiAPIService(
            store: actualStore,
            authorization: actualAuthorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test",
            vocabularyRootURL: root
        ),
        actualStore,
        actualAuthorization
    )
}

private func vocabularyRequest(
    _ method: APIHTTPMethod,
    _ path: String,
    token: String,
    query: [String: [String]] = [:],
    headers: [String: String] = [:],
    body: Data = Data()
) -> APIRequest {
    var allHeaders = headers
    allHeaders["Host"] = "127.0.0.1:8766"
    allHeaders["Authorization"] = "Bearer \(token)"
    return APIRequest(
        method: method,
        path: path,
        query: query,
        headers: allHeaders,
        body: body
    )
}

@Test func vocabularyScopesAndInstalledPackReadsAreIndependentAndComplete() async throws {
    let workspace = try vocabularyTestDirectory("reads")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let root = workspace.appendingPathComponent("Vocabulary Packs", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try compileVocabularyAPIFixture(
        in: root, name: "Installed", packID: "fixture.uk"
    )
    _ = try compileVocabularyAPIFixture(
        in: root, name: "Earlier", packID: "fixture.earlier"
    )
    let (api, _, _) = try await vocabularyAPI(root: root)
    let readToken = try await pair(api, scopes: ["vocabulary.read"])
    let writeToken = try await pair(api, scopes: ["vocabulary.write"])

    let deniedMutation = await api.handle(vocabularyRequest(
        .post, "/v1/vocabulary-pack-imports", token: readToken, body: Data(#"{"files":[]}"#.utf8)
    ))
    #expect(deniedMutation.status == 403)
    #expect(try jsonObject(deniedMutation)["code"] as? String == "insufficient_scope")
    let deniedRead = await api.handle(vocabularyRequest(
        .get, "/v1/vocabulary-packs", token: writeToken
    ))
    #expect(deniedRead.status == 403)

    let current = await api.handle(vocabularyRequest(
        .get, "/v1/clients/current", token: readToken
    ))
    #expect(try jsonObject(current)["scopes"] as? [String] == ["vocabulary.read"])

    let listed = await api.handle(vocabularyRequest(
        .get, "/v1/vocabulary-packs", token: readToken
    ))
    #expect(listed.status == 200)
    let listedData = try #require(try jsonObject(listed)["data"] as? [[String: Any]])
    #expect(listedData.count == 2)
    #expect(listedData.map { $0["id"] as? String } == ["fixture.earlier", "fixture.uk"])
    #expect(listedData[1]["entryCount"] as? Int == fixture.entries.count)
    #expect(listedData[1]["mediaFileCount"] as? Int == 1)
    #expect(listedData.allSatisfy { pack in
        pack.keys.allSatisfy { !$0.lowercased().contains("path") }
    })

    let pack = await api.handle(vocabularyRequest(
        .get, "/v1/vocabulary-packs/fixture.uk", token: readToken
    ))
    #expect(pack.status == 200)
    #expect(pack.headers["ETag"] == #""revision-1""#)

    let exact = await api.handle(vocabularyRequest(
        .get,
        "/v1/vocabulary-packs/fixture.uk/entries",
        token: readToken,
        query: ["query": ["ЗАСТОСУВАТИ"], "mode": ["exact"], "language": ["uk"]]
    ))
    #expect(exact.status == 200)
    let exactData = try #require(try jsonObject(exact)["data"] as? [[String: Any]])
    #expect(exactData.map { $0["id"] as? String } == [fixture.entries[0].id])

    let prefix = await api.handle(vocabularyRequest(
        .get,
        "/v1/vocabulary-packs/fixture.uk/entries",
        token: readToken,
        query: ["query": ["заст"], "limit": ["1"]]
    ))
    #expect(prefix.status == 200)
    #expect((try jsonObject(prefix)["data"] as? [[String: Any]])?.count == 1)

    let encodedEntryID = fixture.entries[0].id.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
    )!
    let entry = await api.handle(vocabularyRequest(
        .get,
        "/v1/vocabulary-packs/fixture.uk/entries/\(encodedEntryID)",
        token: readToken
    ))
    #expect(entry.status == 200)
    #expect(try APIJSON.decoder.decode(LexicalEntry.self, from: entry.body) == fixture.entries[0])

    let mediaQuery = ["path": ["speaker/word.mp3"]]
    let media = await api.handle(vocabularyRequest(
        .get, "/v1/vocabulary-packs/fixture.uk/media", token: readToken, query: mediaQuery
    ))
    #expect(media.status == 200)
    #expect(media.body == fixture.media)
    #expect(media.headers["Content-Length"] == String(fixture.media.count))
    let head = await api.handle(vocabularyRequest(
        .head, "/v1/vocabulary-packs/fixture.uk/media", token: readToken, query: mediaQuery
    ))
    #expect(head.status == 200)
    #expect(head.body.isEmpty)
    #expect(head.headers["Digest"] == media.headers["Digest"])
    let range = await api.handle(vocabularyRequest(
        .get,
        "/v1/vocabulary-packs/fixture.uk/media",
        token: readToken,
        query: mediaQuery,
        headers: ["Range": "bytes=0-1"]
    ))
    #expect(range.status == 416)
    let traversal = await api.handle(vocabularyRequest(
        .get,
        "/v1/vocabulary-packs/fixture.uk/media",
        token: readToken,
        query: ["path": ["../manifest.json"]]
    ))
    #expect(traversal.status == 404)
    #expect(!String(decoding: traversal.body, as: UTF8.self).contains(root.path))
}

@Test func vocabularyPackImportIsValidatedDurableIdempotentAndGuarded() async throws {
    let workspace = try vocabularyTestDirectory("imports")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let sourceRoot = workspace.appendingPathComponent("source", isDirectory: true)
    let managedRoot = workspace.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let fixture = try compileVocabularyAPIFixture(
        in: sourceRoot, name: "Import", packID: "import.fixture"
    )
    let files = try vocabularyFixtureFiles(at: fixture.url)
    let (firstAPI, store, authorization) = try await vocabularyAPI(root: managedRoot)
    let token = try await pair(
        firstAPI, scopes: ["vocabulary.read", "vocabulary.write"]
    )

    let invalidDeclaration = try JSONSerialization.data(withJSONObject: [
        "files": [
            [
                "id": UUID().uuidString.lowercased(), "path": "manifest.json",
                "byteSize": 0, "sha256": String(repeating: "0", count: 64),
            ],
            [
                "id": UUID().uuidString.lowercased(), "path": "../lexicon.sqlite",
                "byteSize": 0, "sha256": String(repeating: "0", count: 64),
            ],
        ],
    ])
    let rejectedDeclaration = await firstAPI.handle(vocabularyRequest(
        .post,
        "/v1/vocabulary-pack-imports",
        token: token,
        body: invalidDeclaration
    ))
    #expect(rejectedDeclaration.status == 422)
    #expect(!FileManager.default.fileExists(atPath: managedRoot.path))

    let declarations: [[String: Any]] = files.map {
        [
            "id": $0.id,
            "path": $0.path,
            "byteSize": $0.bytes.count,
            "sha256": APICrypto.sha256Hex($0.bytes),
        ]
    }
    let createBody = try JSONSerialization.data(withJSONObject: ["files": declarations])
    let created = await firstAPI.handle(vocabularyRequest(
        .post, "/v1/vocabulary-pack-imports", token: token, body: createBody
    ))
    #expect(created.status == 201)
    let createdJob = try APIJSON.decoder.decode(APIVocabularyImportJob.self, from: created.body)
    #expect(createdJob.state == "awaitingFiles")
    #expect(created.headers["ETag"] == #""revision-1""#)

    let prematureValidation = await firstAPI.handle(vocabularyRequest(
        .post,
        "/v1/vocabulary-pack-imports/\(createdJob.id)/validations",
        token: token
    ))
    #expect(prematureValidation.status == 422)

    let firstFile = try #require(files.first)
    var wrongBytes = firstFile.bytes
    wrongBytes[wrongBytes.startIndex] ^= 0xFF
    let rejectedUpload = await firstAPI.handle(vocabularyRequest(
        .put,
        "/v1/vocabulary-pack-imports/\(createdJob.id)/files/\(firstFile.id)",
        token: token,
        headers: ["If-Match": #""revision-1""#],
        body: wrongBytes
    ))
    #expect(rejectedUpload.status == 422)
    let unchanged = await firstAPI.handle(vocabularyRequest(
        .get, "/v1/vocabulary-pack-imports/\(createdJob.id)", token: token
    ))
    #expect(unchanged.headers["ETag"] == #""revision-1""#)

    let firstUpload = await firstAPI.handle(vocabularyRequest(
        .put,
        "/v1/vocabulary-pack-imports/\(createdJob.id)/files/\(firstFile.id)",
        token: token,
        headers: ["If-Match": #""revision-1""#],
        body: firstFile.bytes
    ))
    #expect(firstUpload.status == 200)
    var revision = try APIJSON.decoder.decode(
        APIVocabularyImportJob.self, from: firstUpload.body
    ).revision

    let (restartedAPI, _, _) = try await vocabularyAPI(
        root: managedRoot, store: store, authorization: authorization
    )
    let restored = await restartedAPI.handle(vocabularyRequest(
        .get, "/v1/vocabulary-pack-imports/\(createdJob.id)", token: token
    ))
    #expect(restored.status == 200)
    #expect(restored.headers["ETag"] == #""revision-\#(revision)""#)

    for file in files.dropFirst() {
        let uploaded = await restartedAPI.handle(vocabularyRequest(
            .put,
            "/v1/vocabulary-pack-imports/\(createdJob.id)/files/\(file.id)",
            token: token,
            headers: ["If-Match": #""revision-\#(revision)""#],
            body: file.bytes
        ))
        #expect(uploaded.status == 200)
        revision = try APIJSON.decoder.decode(
            APIVocabularyImportJob.self, from: uploaded.body
        ).revision
    }

    let validated = await restartedAPI.handle(vocabularyRequest(
        .post,
        "/v1/vocabulary-pack-imports/\(createdJob.id)/validations",
        token: token
    ))
    #expect(validated.status == 200)
    let validatedJob = try APIJSON.decoder.decode(
        APIVocabularyImportJob.self, from: validated.body
    )
    #expect(validatedJob.state == "validated")
    #expect(validatedJob.pack?.id == "import.fixture")

    let commitPath = "/v1/vocabulary-pack-imports/\(createdJob.id)/commits"
    let noKey = await restartedAPI.handle(vocabularyRequest(
        .post,
        commitPath,
        token: token,
        headers: ["If-Match": #""revision-\#(validatedJob.revision)""#]
    ))
    #expect(noKey.status == 422)
    let commitRequest = vocabularyRequest(
        .post,
        commitPath,
        token: token,
        headers: [
            "If-Match": #""revision-\#(validatedJob.revision)""#,
            "Idempotency-Key": "install-import-fixture",
        ]
    )
    let committed = await restartedAPI.handle(commitRequest)
    #expect(committed.status == 200)
    let completedJob = try APIJSON.decoder.decode(
        APIVocabularyImportJob.self, from: committed.body
    )
    #expect(completedJob.state == "completed")
    let replayed = await restartedAPI.handle(commitRequest)
    #expect(replayed.status == committed.status)
    #expect(replayed.body == committed.body)

    let listed = await restartedAPI.handle(vocabularyRequest(
        .get, "/v1/vocabulary-packs", token: token
    ))
    let installed = try #require(try jsonObject(listed)["data"] as? [[String: Any]])
    #expect(installed.map { $0["id"] as? String } == ["import.fixture"])
    let searched = await restartedAPI.handle(vocabularyRequest(
        .get,
        "/v1/vocabulary-packs/import.fixture/entries",
        token: token,
        query: ["query": ["застосувати"], "mode": ["exact"]]
    ))
    #expect(searched.status == 200)

    let missingPrecondition = await restartedAPI.handle(vocabularyRequest(
        .delete, "/v1/vocabulary-packs/import.fixture", token: token
    ))
    #expect(missingPrecondition.status == 428)
    let stalePrecondition = await restartedAPI.handle(vocabularyRequest(
        .delete,
        "/v1/vocabulary-packs/import.fixture",
        token: token,
        headers: ["If-Match": #""revision-2""#]
    ))
    #expect(stalePrecondition.status == 412)
    let removed = await restartedAPI.handle(vocabularyRequest(
        .delete,
        "/v1/vocabulary-packs/import.fixture",
        token: token,
        headers: ["If-Match": #""revision-1""#]
    ))
    #expect(removed.status == 204)
    #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    let absent = await restartedAPI.handle(vocabularyRequest(
        .get, "/v1/vocabulary-packs/import.fixture", token: token
    ))
    #expect(absent.status == 404)
}

private actor VocabularyPackOpenCounter {
    private(set) var count = 0

    func open(_ url: URL) async throws -> VocabularyPack {
        count += 1
        return try await VocabularyPack.open(at: url)
    }
}

@Test func validatedVocabularyPackCacheAvoidsRepeatedFullHashingAndInvalidatesOnChange() async throws {
    let workspace = try vocabularyTestDirectory("validation-cache")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let root = workspace.appendingPathComponent("Vocabulary Packs", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try compileVocabularyAPIFixture(
        in: root, name: "Cached", packID: "cache.fixture"
    )
    let counter = VocabularyPackOpenCounter()
    let library = APIVocabularyLibrary(
        rootURL: root,
        openPack: { url in try await counter.open(url) }
    )

    #expect(try await library.listPacks().map(\.id) == ["cache.fixture"])
    #expect(try await library.search(
        packID: "cache.fixture", query: "заст", mode: .prefix, limit: 50, language: "uk"
    ).count == 2)
    #expect(try await library.entry(
        packID: "cache.fixture", entryID: fixture.entries[0].id
    ) == fixture.entries[0])
    #expect(try await library.listPacks().count == 1)
    #expect(await counter.count == 1)

    let manifestURL = fixture.url.appendingPathComponent("manifest.json")
    let unchangedManifest = try Data(contentsOf: manifestURL)
    try unchangedManifest.write(to: manifestURL, options: .atomic)
    #expect(try await library.search(
        packID: "cache.fixture", query: "застосувати", mode: .exact, limit: 50, language: nil
    ).map(\.id) == [fixture.entries[0].id])
    #expect(await counter.count == 2)

    let databaseURL = fixture.url.appendingPathComponent("lexicon.sqlite")
    let handle = try FileHandle(forWritingTo: databaseURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    await #expect(throws: APIServiceError.self) {
        try await library.search(
            packID: "cache.fixture", query: "заст", mode: .prefix, limit: 50, language: nil
        )
    }
    #expect(await counter.count == 3)
}
