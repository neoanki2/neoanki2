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

@Test func knownWordsAndVocabularySetsUseDedicatedScopesAndReplaySafely() async throws {
    let root = try vocabularyTestDirectory("known-words")
    defer { try? FileManager.default.removeItem(at: root) }
    let (api, store, _) = try await vocabularyAPI(root: root)
    let read = try await pair(api, scopes: ["known-words.read"])
    let write = try await pair(api, scopes: ["known-words.write"])
    let itemWriter = try await pair(api, scopes: ["items.write"])
    let judge = vocabularyRequest(.post, "/v1/known-words/judgments", token: write,
        headers: ["Content-Type": "application/json", "Idempotency-Key": "judge-gift"],
        body: Data(#"{"term":{"language":"de","expression":"Gift"},"judgment":"known"}"#.utf8))
    #expect(await api.handle(judge).status == 200)
    #expect(await api.handle(judge).status == 200)
    #expect(await api.handle(vocabularyRequest(.get, "/v1/known-words", token: write)).status == 403)
    let german = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read, query: ["language": ["de"]]))
    let english = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read, query: ["language": ["en"]]))
    #expect(try (jsonObject(german)["data"] as? [[String: Any]])?.count == 1)
    #expect(try (jsonObject(english)["data"] as? [[String: Any]])?.isEmpty == true)
    #expect(try await store.fetchDueCards().isEmpty)

    let body = Data(#"{"term":{"language":"es","expression":"sí"},"meaning":"yes","meaningLanguage":"en","sentence":"Respondió que sí.","occurrence":0}"#.utf8)
    let create = vocabularyRequest(.post, "/v1/vocabulary-sets", token: itemWriter,
        headers: ["Content-Type": "application/json", "Idempotency-Key": "create-si"], body: body)
    let first = await api.handle(create)
    let replay = await api.handle(create)
    #expect(first.status == 201)
    #expect(replay.status == 201)
    #expect(first.body == replay.body)
    #expect(try await store.countItems(itemTypeID: VocabularySet.typeID) == 1)
    #expect(try await store.vocabularyStatuses(language: "es").first?.hasCards == true)
}

private func knownWordsBody(_ json: String) -> Data { Data(json.utf8) }

private func knownWordsWrite(
    _ path: String, token: String, key: String?, body: String
) -> APIRequest {
    var headers = ["Content-Type": "application/json"]
    if let key { headers["Idempotency-Key"] = key }
    return vocabularyRequest(.post, path, token: token, headers: headers, body: knownWordsBody(body))
}

private func firstProblemPointer(_ response: APIResponse) throws -> String? {
    (try jsonObject(response)["errors"] as? [[String: Any]])?.first?["pointer"] as? String
}

/// Every key the response writes is declared by its schema, and every required key is present.
private func expectMatchesSchema(_ object: [String: Any], schema name: String) throws {
    let root = try #require(JSONSerialization.jsonObject(with: APIOpenAPI.document) as? [String: Any])
    let schemas = try #require((root["components"] as? [String: Any])?["schemas"] as? [String: Any])
    let schema = try #require(schemas[name] as? [String: Any])
    let properties = Set(try #require((schema["properties"] as? [String: Any])?.keys))
    let required = Set(schema["required"] as? [String] ?? [])
    #expect(Set(object.keys).isSubset(of: properties), "\(name): \(object.keys.sorted())")
    #expect(required.isSubset(of: Set(object.keys)), "\(name): \(object.keys.sorted())")
}

@Test func knownWordsFilterByExpressionAndServeVersionedSnapshots() async throws {
    let root = try vocabularyTestDirectory("known-words-snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    let (api, _, _) = try await vocabularyAPI(root: root)
    let read = try await pair(api, scopes: ["known-words.read"])
    let write = try await pair(api, scopes: ["known-words.write"])

    let book = await api.handle(knownWordsWrite("/v1/known-words/judgments", token: write, key: "judge-book",
        body: #"{"term":{"language":"uk","expression":"кни́жку","lemma":"кни́жка"},"judgment":"known"}"#))
    #expect(book.status == 200)
    try expectMatchesSchema(try jsonObject(book), schema: "VocabularyJudgmentChange")
    #expect((try jsonObject(book)["term"] as? [String: Any])?["lemma"] as? String == "кни́жка")
    #expect(await api.handle(knownWordsWrite("/v1/known-words/judgments", token: write, key: "judge-cat",
        body: #"{"term":{"language":"uk","expression":"кіт"},"judgment":"unfamiliar"}"#)).status == 200)

    let filtered = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read,
        query: ["language": ["uk"], "expression": ["  КНИЖКУ "]]))
    #expect(filtered.status == 200)
    let rows = try #require(try jsonObject(filtered)["data"] as? [[String: Any]])
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    try expectMatchesSchema(row, schema: "KnownWord")
    #expect(row["judgment"] as? String == "known")
    #expect(row["state"] as? String == "known")
    #expect(row["expressionState"] as? String == "known")
    #expect(row["judgedAt"] is String)
    let other = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read,
        query: ["language": ["uk"], "expression": ["пес"]]))
    #expect(try (jsonObject(other)["data"] as? [[String: Any]])?.isEmpty == true)
    let all = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read, query: ["language": ["uk"]]))
    #expect(try (jsonObject(all)["data"] as? [[String: Any]])?.count == 2)
    let withoutLanguage = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read,
        query: ["expression": ["книжку"]]))
    #expect(withoutLanguage.status == 422)
    #expect(try firstProblemPointer(withoutLanguage) == "/query/language")

    let snapshot = await api.handle(vocabularyRequest(.get, "/v1/known-words/snapshot", token: read,
        query: ["language": ["UK"]]))
    #expect(snapshot.status == 200)
    let full = try jsonObject(snapshot)
    try expectMatchesSchema(full, schema: "KnownWordsSnapshot")
    let version = try #require(full["version"] as? String)
    #expect(!version.isEmpty)
    #expect(full["language"] as? String == "uk")
    #expect(full["unchanged"] == nil)
    #expect((full["expressions"] as? [String: String])?["книжку"] == "known")
    #expect((full["expressions"] as? [String: String])?["кіт"] == "unfamiliar")
    #expect((full["lemmas"] as? [String: String])?["книжка"] == "known")

    let current = await api.handle(vocabularyRequest(.get, "/v1/known-words/snapshot", token: read,
        query: ["language": ["uk"], "since": [version]]))
    #expect(current.status == 200)
    let unchanged = try jsonObject(current)
    try expectMatchesSchema(unchanged, schema: "KnownWordsSnapshot")
    #expect(unchanged["unchanged"] as? Bool == true)
    #expect(unchanged["version"] as? String == version)
    #expect(unchanged["expressions"] == nil && unchanged["lemmas"] == nil)

    #expect(await api.handle(knownWordsWrite("/v1/known-words/judgments", token: write, key: "judge-kyiv",
        body: #"{"term":{"language":"uk","expression":"Київ"},"judgment":"ignored"}"#)).status == 200)
    let changed = try jsonObject(await api.handle(vocabularyRequest(.get, "/v1/known-words/snapshot", token: read,
        query: ["language": ["uk"], "since": [version]])))
    #expect(changed["version"] as? String != version)
    #expect(changed["unchanged"] == nil)
    #expect((changed["expressions"] as? [String: String])?["київ"] == "ignored")

    let missingLanguage = await api.handle(vocabularyRequest(.get, "/v1/known-words/snapshot", token: read))
    #expect(missingLanguage.status == 422)
    #expect(try firstProblemPointer(missingLanguage) == "/query/language")
    let unknownQuery = await api.handle(vocabularyRequest(.get, "/v1/known-words/snapshot", token: read,
        query: ["language": ["uk"], "cursor": ["x"]]))
    #expect(unknownQuery.status == 422)
    let denied = await api.handle(vocabularyRequest(.get, "/v1/known-words/snapshot", token: write,
        query: ["language": ["uk"]]))
    #expect(denied.status == 403)
    #expect(try jsonObject(denied)["requiredScope"] as? String == "known-words.read")
}

@Test func knownWordsRecordIgnoredAndRejectJudgmentsFromNewerReleases() async throws {
    let root = try vocabularyTestDirectory("known-words-ignored")
    defer { try? FileManager.default.removeItem(at: root) }
    let (api, store, _) = try await vocabularyAPI(root: root)
    let read = try await pair(api, scopes: ["known-words.read"])
    let write = try await pair(api, scopes: ["known-words.write"])

    let ignored = await api.handle(knownWordsWrite("/v1/known-words/judgments", token: write, key: "ignore-acme",
        body: #"{"term":{"language":"en","expression":"Acme"},"judgment":"ignored"}"#))
    #expect(ignored.status == 200)
    let receipt = try jsonObject(ignored)
    #expect(receipt["judgment"] as? String == "ignored")
    #expect(receipt["ignored"] == nil)
    try expectMatchesSchema(receipt, schema: "VocabularyJudgmentChange")
    let replay = await api.handle(knownWordsWrite("/v1/known-words/judgments", token: write, key: "ignore-acme",
        body: #"{"term":{"language":"en","expression":"Acme"},"judgment":"ignored"}"#))
    #expect(replay.body == ignored.body)
    #expect(try await store.vocabularyStatuses(language: "en").first?.state == .ignored)
    let listed = await api.handle(vocabularyRequest(.get, "/v1/known-words", token: read, query: ["language": ["en"]]))
    let row = try #require((try jsonObject(listed)["data"] as? [[String: Any]])?.first)
    #expect(row["judgment"] as? String == "ignored")
    #expect(row["state"] as? String == "ignored")

    for value in ["maybe", "unrecognized"] {
        let rejected = await api.handle(knownWordsWrite("/v1/known-words/judgments", token: write, key: "judge-\(value)",
            body: #"{"term":{"language":"en","expression":"Acme"},"judgment":"\#(value)"}"#))
        #expect(rejected.status == 422)
        #expect(try jsonObject(rejected)["code"] as? String == "validation_failed")
        #expect(try firstProblemPointer(rejected) == "/judgment")
    }
    #expect(try await store.vocabularyStatuses(language: "en").first?.state == .ignored)
    let unauthorized = await api.handle(knownWordsWrite("/v1/known-words/judgments", token: read, key: "denied",
        body: #"{"term":{"language":"en","expression":"Acme"},"judgment":"known"}"#))
    #expect(unauthorized.status == 403)
}

@Test func knownWordsJudgmentBatchesReplayByIdempotencyKeyAndUndo() async throws {
    let root = try vocabularyTestDirectory("known-words-batches")
    defer { try? FileManager.default.removeItem(at: root) }
    let (api, store, _) = try await vocabularyAPI(root: root)
    let read = try await pair(api, scopes: ["known-words.read"])
    let write = try await pair(api, scopes: ["known-words.write"])
    let path = "/v1/known-words/judgment-batches"
    let body = #"{"entries":[{"term":{"language":"uk","expression":"кіт"},"judgment":"known"},{"term":{"language":"uk","expression":"Пес","lemma":"пес"},"judgment":"ignored"},{"term":{"language":"uk","expression":"кіт"},"judgment":"known"}]}"#

    let first = await api.handle(knownWordsWrite(path, token: write, key: "import-1", body: body))
    #expect(first.status == 201)
    let receipt = try jsonObject(first)
    try expectMatchesSchema(receipt, schema: "VocabularyJudgmentBatchReceipt")
    let batchID = try #require(receipt["batchId"] as? String)
    #expect(UUID(uuidString: batchID) != nil && batchID == batchID.lowercased())
    #expect(receipt["recorded"] as? Int == 2)
    #expect(receipt["unchanged"] as? Int == 1)
    let changes = try #require(receipt["changes"] as? [[String: Any]])
    #expect(changes.count == 2)
    for change in changes { try expectMatchesSchema(change, schema: "VocabularyJudgmentChange") }
    #expect(changes.allSatisfy { $0["batchId"] as? String == batchID && $0["ignored"] == nil })
    #expect(changes.compactMap { $0["judgment"] as? String }.sorted() == ["ignored", "known"])

    let retry = await api.handle(knownWordsWrite(path, token: write, key: "import-1", body: body))
    #expect(retry.status == 201)
    #expect(retry.body == first.body)
    let conflicting = await api.handle(knownWordsWrite(path, token: write, key: "import-1",
        body: #"{"entries":[{"term":{"language":"uk","expression":"кіт"},"judgment":"unfamiliar"}]}"#))
    #expect(conflicting.status == 409)
    #expect(try await store.vocabularyStatuses(language: "uk").count == 2)

    let missingKey = await api.handle(knownWordsWrite(path, token: write, key: nil, body: body))
    #expect(missingKey.status == 422)
    let empty = await api.handle(knownWordsWrite(path, token: write, key: "import-empty", body: #"{"entries":[]}"#))
    #expect(empty.status == 422)
    #expect(try firstProblemPointer(empty) == "/entries")
    let invalid = await api.handle(knownWordsWrite(path, token: write, key: "import-invalid",
        body: #"{"entries":[{"term":{"language":"uk","expression":"кіт"},"judgment":"known"},{"term":{"language":"uk","expression":"пес"},"judgment":"later"}]}"#))
    #expect(invalid.status == 422)
    #expect(try firstProblemPointer(invalid) == "/entries/1/judgment")
    let tooMany = "{\"entries\":[" + Array(repeating: #"{"term":{"language":"uk","expression":"кіт"},"judgment":"known"}"#,
                                           count: maximumVocabularyBatchSize + 1).joined(separator: ",") + "]}"
    let oversized = await api.handle(knownWordsWrite(path, token: write, key: "import-large", body: tooMany))
    #expect(oversized.status == 422)
    #expect(try firstProblemPointer(oversized) == "/entries")
    #expect(await api.handle(knownWordsWrite(path, token: read, key: "import-read", body: body)).status == 403)

    let undoPath = "\(path)/\(batchID)/undo"
    let undo = await api.handle(vocabularyRequest(.post, undoPath, token: write, headers: ["Idempotency-Key": "undo-1"]))
    #expect(undo.status == 200)
    let undone = try jsonObject(undo)
    try expectMatchesSchema(undone, schema: "VocabularyJudgmentBatchReceipt")
    let undoID = try #require(undone["batchId"] as? String)
    #expect(undoID != batchID)
    #expect(undone["recorded"] as? Int == 2)
    #expect((undone["changes"] as? [[String: Any]])?.allSatisfy {
        $0["judgment"] as? String == "reviewHistory" && $0["batchId"] as? String == undoID
    } == true)
    let undoRetry = await api.handle(vocabularyRequest(.post, undoPath, token: write, headers: ["Idempotency-Key": "undo-1"]))
    #expect(undoRetry.status == 200)
    #expect(undoRetry.body == undo.body)
    #expect(try await store.vocabularyStatuses(language: "uk").allSatisfy { $0.explicitJudgment == nil })

    let unknownBatch = UUID().uuidString.lowercased()
    let missing = await api.handle(vocabularyRequest(.post, "\(path)/\(unknownBatch)/undo", token: write,
        headers: ["Idempotency-Key": "undo-missing"]))
    #expect(missing.status == 404)
    #expect(try jsonObject(missing)["code"] as? String == "resource_not_found")
    let malformed = await api.handle(vocabularyRequest(.post, "\(path)/\(batchID.uppercased())/undo", token: write,
        headers: ["Idempotency-Key": "undo-malformed"]))
    #expect(malformed.status == 422)
    let undoWithoutKey = await api.handle(vocabularyRequest(.post, undoPath, token: write))
    #expect(undoWithoutKey.status == 422)
    let undoDenied = await api.handle(vocabularyRequest(.post, undoPath, token: read, headers: ["Idempotency-Key": "undo-read"]))
    #expect(undoDenied.status == 403)
}

@Test func vocabularyPacksResolveDictionaryFormsAndListFrequencyBands() async throws {
    let workspace = try vocabularyTestDirectory("dictionary-forms")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let root = workspace.appendingPathComponent("Vocabulary Packs", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try compileVocabularyAPIFixture(in: root, name: "Forms", packID: "fixture.uk")
    let (api, _, _) = try await vocabularyAPI(root: root)
    let readToken = try await pair(api, scopes: ["vocabulary.read"])
    let knownWordsToken = try await pair(api, scopes: ["known-words.read", "known-words.write"])
    let formsPath = "/v1/vocabulary-packs/fixture.uk/dictionary-forms"
    func forms(_ body: String, token: String? = nil, path: String? = nil) async -> APIResponse {
        await api.handle(vocabularyRequest(.post, path ?? formsPath, token: token ?? readToken,
            headers: ["Content-Type": "application/json"], body: Data(body.utf8)))
    }

    let resolved = await forms(#"{"language":"uk","words":["Застосували","застава","невідоме"]}"#)
    #expect(resolved.status == 200)
    try expectMatchesSchema(try jsonObject(resolved), schema: "DictionaryForms")
    let data = try #require(try jsonObject(resolved)["data"] as? [String: [String]])
    #expect(data["Застосували"] == [fixture.entries[0].canonicalForm.text.value])
    #expect(data["застава"] == ["застава"])
    #expect(data["невідоме"] == nil)
    #expect(try (jsonObject(await forms(#"{"language":"en","words":["застава"]}"#))["data"] as? [String: [String]])?.isEmpty == true)

    #expect(try firstProblemPointer(await forms(#"{"language":"uk","words":["застава"],"limit":1}"#)) == "/limit")
    #expect(try firstProblemPointer(await forms(#"{"language":"uk","words":[]}"#)) == "/words")
    let tooMany = try String(decoding: JSONSerialization.data(withJSONObject: [
        "language": "uk", "words": (0 ... VocabularyPack.maximumResolvedWords).map { "слово\($0)" },
    ] as [String: Any]), as: UTF8.self)
    let oversized = await forms(tooMany)
    #expect(oversized.status == 422)
    #expect(try firstProblemPointer(oversized) == "/words")
    let longWord = String(repeating: "я", count: 129)
    #expect(try firstProblemPointer(await forms(#"{"language":"uk","words":["кіт","\#(longWord)"]}"#)) == "/words/1")
    #expect(try firstProblemPointer(await forms(#"{"language":"","words":["кіт"]}"#)) == "/language")
    #expect(await forms("not json").status == 422)
    #expect(await forms(#"{"language":"uk","words":["кіт"]}"#,
                        path: "/v1/vocabulary-packs/missing/dictionary-forms").status == 404)
    let deniedForms = await forms(#"{"language":"uk","words":["кіт"]}"#, token: knownWordsToken)
    #expect(deniedForms.status == 403)
    #expect(try jsonObject(deniedForms)["requiredScope"] as? String == "vocabulary.read")

    let bandPath = "/v1/vocabulary-packs/fixture.uk/frequency-band"
    func band(_ query: [String: [String]], token: String? = nil, path: String? = nil) async -> APIResponse {
        await api.handle(vocabularyRequest(.get, path ?? bandPath, token: token ?? readToken, query: query))
    }
    let ranked = await band(["language": ["uk"]])
    #expect(ranked.status == 200)
    let rankedObject = try jsonObject(ranked)
    try expectMatchesSchema(rankedObject, schema: "VocabularyFrequencyBand")
    #expect(rankedObject["words"] as? [String] == [fixture.entries[0].canonicalForm.text.value])
    #expect(rankedObject["total"] as? Int == 1)
    let past = try jsonObject(await band(["language": ["uk"], "offset": ["1"], "limit": ["5"], "sample": ["2"]]))
    #expect(past["words"] as? [String] == [])
    #expect(past["total"] as? Int == 1)
    #expect(try jsonObject(await band(["language": ["en"]]))["total"] as? Int == 0)
    for (name, value) in [("limit", "0"), ("limit", "20001"), ("offset", "-1"), ("sample", "0"), ("limit", "many")] {
        let rejected = await band(["language": ["uk"], name: [value]])
        #expect(rejected.status == 422)
        #expect(try firstProblemPointer(rejected) == "/query/\(name)")
    }
    #expect(try firstProblemPointer(await band([:])) == "/query/language")
    #expect(await band(["language": ["uk"], "cursor": ["x"]]).status == 422)
    #expect(await band(["language": ["uk"]], path: "/v1/vocabulary-packs/missing/frequency-band").status == 404)
    #expect(await band(["language": ["uk"]], token: knownWordsToken).status == 403)
}

@Test func knownWordsAndLookupEndpointsAreRegisteredWithTheirScopesAndKeys() throws {
    let root = try #require(JSONSerialization.jsonObject(with: APIOpenAPI.document) as? [String: Any])
    let paths = try #require(root["paths"] as? [String: [String: Any]])
    let expected: [(String, String, String, Bool?)] = [
        ("/v1/known-words/snapshot", "get", "known-words.read", nil),
        ("/v1/known-words/judgment-batches", "post", "known-words.write", true),
        ("/v1/known-words/judgment-batches/{id}/undo", "post", "known-words.write", true),
        ("/v1/vocabulary-packs/{id}/dictionary-forms", "post", "vocabulary.read", false),
        ("/v1/vocabulary-packs/{id}/frequency-band", "get", "vocabulary.read", nil),
    ]
    for (path, method, scope, keyRequired) in expected {
        let operation = try #require(paths[path]?[method] as? [String: Any], "\(method) \(path)")
        #expect(operation["x-required-scope"] as? String == scope)
        #expect((operation["tags"] as? [String]) == [APIEndpointGroup.vocabulary.rawValue])
        let parameters = operation["parameters"] as? [[String: Any]] ?? []
        let key = parameters.first { $0["name"] as? String == "Idempotency-Key" }
        #expect(key?["required"] as? Bool == keyRequired, "\(method) \(path)")
    }
    let list = try #require(paths["/v1/known-words"]?["get"] as? [String: Any])
    #expect((list["parameters"] as? [[String: Any]])?.contains { $0["name"] as? String == "expression" } == true)
    let schemas = try #require((root["components"] as? [String: Any])?["schemas"] as? [String: Any])
    let judgments = (schemas["VocabularyJudgment"] as? [String: Any])?["enum"] as? [String]
    #expect(judgments == ["known", "unfamiliar", "ignored", "reviewHistory"])
    let states = (schemas["VocabularyReadingState"] as? [String: Any])?["enum"] as? [String]
    #expect(Set(states ?? []) == Set(VocabularyReadingState.allCases.map(\.rawValue)))
}
