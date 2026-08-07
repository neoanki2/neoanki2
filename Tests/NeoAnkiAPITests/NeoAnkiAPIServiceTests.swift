import Foundation
import Network
@testable import NeoAnkiAPI
import NeoAnkiCore
import NeoAnkiTestSupport
import NeoAnkiVocabularyKit
import Testing

private struct ApproveAllPairings: APIPairingApprover {
    func approve(_ request: APIPairingRequest) async -> Bool { true }
}

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

private actor BlockingPairingApprover: APIPairingApprover {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var started = false

    func approve(_ request: APIPairingRequest) async -> Bool {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func cancel(_ request: APIPairingRequest) {
        continuation?.resume(returning: false)
        continuation = nil
    }

    func resolve(_ approved: Bool) {
        continuation?.resume(returning: approved)
        continuation = nil
    }
}

private struct SlowPairingApprover: APIPairingApprover {
    func approve(_ request: APIPairingRequest) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(10))
            return true
        } catch {
            return false
        }
    }
}

private struct ConfiguredAPIFaultInjector: APIFaultInjector {
    let point: APIFaultPoint

    func simulatesProcessExit(at candidate: APIFaultPoint) -> Bool {
        switch (point, candidate) {
        case (.mediaAfterReservation, .mediaAfterReservation),
             (.importBeforeDomainCommit, .importBeforeDomainCommit),
             (.importAfterDomainCommit, .importAfterDomainCommit),
             (.importAfterCompletedJobPersisted, .importAfterCompletedJobPersisted),
             (.exportAfterPendingJobPersisted, .exportAfterPendingJobPersisted),
             (.exportAfterOutputGenerated, .exportAfterOutputGenerated),
             (.exportAfterCompletedJobPersisted, .exportAfterCompletedJobPersisted):
            true
        default:
            false
        }
    }
}

private func apiTestDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-api-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("library.sqlite")
}

private func makeAPI(authority: String = "127.0.0.1:8766") async throws -> NeoAnkiAPIService {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await store.bootstrap()
    let credentials = InMemoryAPICredentialPersistence()
    let authorization = APIAuthorizationStore(persistence: credentials)
    return NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test",
        authority: authority
    )
}

private func makeAPIAndStore() async throws -> (NeoAnkiAPIService, ItemStore) {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    return (
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        ),
        store
    )
}

@Test func strictHTTPParserRejectsAmbiguityAndParsesQuerySeparately() throws {
    let valid = Data(
        "GET /v1/decks?limit=2&tag=a&tag=b HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nContent-Length: 0\r\n\r\n".utf8
    )
    #expect(try HTTP1RequestParser.expectedTotalBytes(in: valid) == valid.count)
    let parsed = try HTTP1RequestParser.parse(
        valid,
        remoteEndpoint: .hostPort(host: "127.0.0.1", port: 12345)
    )
    #expect(parsed.path == "/v1/decks")
    #expect(parsed.query["limit"] == ["2"])
    #expect(parsed.query["tag"] == ["a", "b"])
    #expect(parsed.isLoopback)

    let duplicateHost = Data(
        "GET /health HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n".utf8
    )
    #expect(throws: HTTP1ParseError.duplicateCriticalHeader) {
        try HTTP1RequestParser.expectedTotalBytes(in: duplicateHost)
    }
    let chunked = Data(
        "POST /v1/decks HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
    )
    #expect(throws: HTTP1ParseError.unsupportedTransferEncoding) {
        try HTTP1RequestParser.expectedTotalBytes(in: chunked)
    }
    let absolute = Data(
        "GET http://attacker.invalid/ HTTP/1.1\r\nHost: local\r\n\r\n".utf8
    )
    #expect(try HTTP1RequestParser.expectedTotalBytes(in: absolute) == absolute.count)
    #expect(throws: HTTP1ParseError.absoluteRequestTarget) {
        try HTTP1RequestParser.parse(
            absolute,
            remoteEndpoint: .hostPort(host: "127.0.0.1", port: 12345)
        )
    }
    #expect(HTTP1ParseError.unexpectedTrailingBytes.status == 400)
}

@Test func bulkTransferLimitsDoNotReintroduceTheOldTransportCeiling() throws {
    let configuration = NeoAnkiLocalAPIServer.Configuration()
    #expect(configuration.maximumRequestBytes == .max)

    let sum11ByteCount = 627_000_000
    let requestHead = Data(
        "PUT /v1/vocabulary-pack-imports/job/files/file HTTP/1.1\r\n"
            .appending("Host: 127.0.0.1:8766\r\n")
            .appending("Content-Length: \(sum11ByteCount)\r\n\r\n")
            .utf8
    )
    #expect(
        try HTTP1RequestParser.expectedTotalBytes(in: requestHead)
            == requestHead.count + sum11ByteCount
    )
    #expect(NeoAnkiAPIService.maximumStagedImportBytes == 4_000_000_000)
    #expect(APIVocabularyLibrary.maximumFileBytes == VocabularyPackLimits.default.maximumPackBytes)
}

@Test func loopbackServerServesHTTPAndStopsCleanly() async throws {
    let portValue = UInt16.random(in: 30_000 ... 50_000)
    let port = try #require(NWEndpoint.Port(rawValue: portValue))
    let authority = "127.0.0.1:\(portValue)"
    let api = try await makeAPI(authority: authority)
    let unsafeServer = NeoAnkiLocalAPIServer(
        service: api,
        configuration: .init(host: "0.0.0.0", port: port)
    )
    var rejectedUnsafeBinding = false
    do {
        try await unsafeServer.start()
        await unsafeServer.stop()
    } catch {
        rejectedUnsafeBinding = true
    }
    #expect(rejectedUnsafeBinding)
    #expect(await !unsafeServer.isRunning)

    let server = NeoAnkiLocalAPIServer(
        service: api,
        configuration: .init(port: port)
    )

    try await server.start()
    #expect(await server.isRunning)
    let url = try #require(URL(string: "http://\(authority)/health"))
    let (data, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(body == ["status": "ok"])

    await server.stop()
    #expect(await !server.isRunning)
}

@Test func openEventStreamClosesAfterClientRevocation() async throws {
    let portValue = UInt16.random(in: 30_000 ... 50_000)
    let port = try #require(NWEndpoint.Port(rawValue: portValue))
    let authority = "127.0.0.1:\(portValue)"
    let store = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    let api = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test",
        authority: authority
    )
    let token = try await pairWithAuthority(
        api,
        authority: authority,
        scopes: ["library.read"]
    )
    let server = NeoAnkiLocalAPIServer(
        service: api,
        configuration: .init(port: port)
    )
    try await server.start()

    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                continuation.resume()
            case let .failed(error):
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "neoanki-api-stream-test"))
    }
    let requestBytes = Data((
        "GET /v1/events HTTP/1.1\r\n"
            + "Host: \(authority)\r\n"
            + "Authorization: Bearer \(token)\r\n"
            + "\r\n"
    ).utf8)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: requestBytes, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        })
    }
    let initial = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            data, _, _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: data ?? Data()) }
        }
    }
    #expect(String(decoding: initial, as: UTF8.self).contains("text/event-stream"))
    #expect(await server.activeConnectionCount == 1)

    let current = await api.handle(APIRequest(
        method: .get,
        path: "/v1/clients/current",
        headers: [
            "Host": authority,
            "Authorization": "Bearer \(token)",
        ]
    ))
    let revoked = await api.handle(APIRequest(
        method: .delete,
        path: "/v1/clients/current",
        headers: [
            "Host": authority,
            "Authorization": "Bearer \(token)",
            "If-Match": try #require(current.headers["ETag"]),
        ]
    ))
    #expect(revoked.status == 204)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await server.activeConnectionCount != 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(await server.activeConnectionCount == 0)
    connection.cancel()
    await server.stop()
}

private func request(
    _ method: APIHTTPMethod,
    _ path: String,
    headers: [String: String] = [:],
    body: String = ""
) -> APIRequest {
    var allHeaders = headers
    allHeaders["Host"] = allHeaders["Host"] ?? "127.0.0.1:8766"
    return APIRequest(
        method: method,
        path: path,
        headers: allHeaders,
        body: Data(body.utf8)
    )
}

private func jsonObject(_ response: APIResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private func pair(
    _ api: NeoAnkiAPIService,
    scopes: [String],
    origin: String? = nil
) async throws -> String {
    var payload: [String: Any] = [
        "displayName": "Contract Test",
        "requestedScopes": scopes,
    ]
    if let origin { payload["origin"] = origin }
    let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    var headers: [String: String] = ["Host": "127.0.0.1:8766"]
    if let origin { headers["Origin"] = origin }
    let response = await api.handle(
        APIRequest(method: .post, path: "/v1/pairings", headers: headers, body: body)
    )
    #expect(response.status == 201)
    return try #require(try jsonObject(response)["token"] as? String)
}

private func pairWithAuthority(
    _ api: NeoAnkiAPIService,
    authority: String,
    scopes: [String]
) async throws -> String {
    let body = try JSONSerialization.data(withJSONObject: [
        "displayName": "Stream Contract Test",
        "requestedScopes": scopes,
    ], options: [.sortedKeys])
    let response = await api.handle(APIRequest(
        method: .post,
        path: "/v1/pairings",
        headers: ["Host": authority],
        body: body
    ))
    #expect(response.status == 201)
    return try #require(try jsonObject(response)["token"] as? String)
}

@Test func discoveryIsBoundedAndProtectedRoutesRequireAuthentication() async throws {
    let api = try await makeAPI()

    let health = await api.handle(request(.get, "/health"))
    #expect(health.status == 200)
    #expect(try jsonObject(health)["status"] as? String == "ok")
    #expect(health.headers["Cache-Control"] == "no-store")

    let metadata = await api.handle(request(.get, "/v1/meta"))
    #expect(metadata.status == 200)
    #expect(try jsonObject(metadata)["apiVersion"] as? Int == 1)

    let denied = await api.handle(request(.get, "/v1/decks"))
    #expect(denied.status == 401)
    #expect(try jsonObject(denied)["code"] as? String == "unauthorized")

    let foreignHost = await api.handle(
        request(.get, "/health", headers: ["Host": "attacker.invalid"])
    )
    #expect(foreignHost.status == 403)
    #expect(try jsonObject(foreignHost)["code"] as? String == "invalid_host")

    let credentialQuery = await api.handle(APIRequest(
        method: .get,
        path: "/health",
        query: ["access_token": ["must-not-be-accepted"]],
        headers: ["Host": "127.0.0.1:8766"]
    ))
    #expect(credentialQuery.status == 422)
    #expect(try jsonObject(credentialQuery)["code"] as? String == "validation_failed")

    let readToken = try await pair(api, scopes: ["library.read"])
    let duplicateScalarQuery = await api.handle(APIRequest(
        method: .get,
        path: "/v1/decks",
        query: ["limit": ["1", "2"]],
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(readToken)",
        ]
    ))
    #expect(duplicateScalarQuery.status == 422)

    let bodyOnBodylessRoute = await api.handle(request(
        .get, "/v1/meta", body: #"{"ignored":true}"#
    ))
    #expect(bodyOnBodylessRoute.status == 422)
}

@Test func openAPIDocumentDeclaresTheCompleteVersionOneRouteInventory() throws {
    let root = try #require(
        JSONSerialization.jsonObject(with: APIOpenAPI.document) as? [String: Any]
    )
    #expect(root["openapi"] as? String == "3.1.0")
    let paths = try #require(root["paths"] as? [String: [String: Any]])
    let actual = Set(paths.flatMap { path, item in
        item.keys.map { "\($0.uppercased()) \(path)" }
    })
    let expected: Set<String> = [
        "GET /health", "GET /v1/meta", "GET /v1/openapi.json", "POST /v1/pairings",
        "GET /v1/clients/current", "DELETE /v1/clients/current",
        "GET /v1/decks", "POST /v1/decks", "GET /v1/decks/{id}", "PATCH /v1/decks/{id}",
        "POST /v1/deck-deletion-plans", "POST /v1/deck-deletion-plans/{id}/commits",
        "POST /v1/deck-reset-plans", "POST /v1/deck-reset-plans/{id}/commits",
        "GET /v1/decks/{id}/item-type-policy",
        "GET /v1/item-types", "POST /v1/item-types", "POST /v1/item-types/validate",
        "GET /v1/item-types/{id}", "PUT /v1/item-types/{id}", "DELETE /v1/item-types/{id}",
        "POST /v1/item-types/{id}/duplicate",
        "GET /v1/items", "POST /v1/items", "POST /v1/items/validate", "POST /v1/items/bulk",
        "GET /v1/items/{id}", "PUT /v1/items/{id}", "DELETE /v1/items/{id}",
        "POST /v1/items/{id}/duplicate-checks", "GET /v1/tags", "POST /v1/tag-renames",
        "DELETE /v1/tags/{encodedTag}",
        "GET /v1/cards", "GET /v1/cards/{id}", "PATCH /v1/cards/{id}",
        "GET /v1/cards/{id}/content", "GET /v1/cards/{id}/review-preview",
        "POST /v1/cards/{id}/resets",
        "POST /v1/study-sessions", "GET /v1/study-sessions/{id}",
        "DELETE /v1/study-sessions/{id}", "POST /v1/study-sessions/{id}/next",
        "POST /v1/study-sessions/{id}/skips", "POST /v1/reviews",
        "POST /v1/reviews/{reviewLogId}/reverts",
        "POST /v1/media", "HEAD /v1/media/{sha256}", "GET /v1/media/{sha256}",
        "GET /v1/media/{sha256}/metadata",
        "GET /v1/vocabulary-packs", "GET /v1/vocabulary-packs/{id}",
        "DELETE /v1/vocabulary-packs/{id}",
        "GET /v1/vocabulary-packs/{id}/entries",
        "GET /v1/vocabulary-packs/{id}/entries/{entryId}",
        "GET /v1/vocabulary-packs/{id}/media", "HEAD /v1/vocabulary-packs/{id}/media",
        "POST /v1/vocabulary-pack-imports", "GET /v1/vocabulary-pack-imports/{id}",
        "DELETE /v1/vocabulary-pack-imports/{id}",
        "PUT /v1/vocabulary-pack-imports/{id}/files/{fileId}",
        "POST /v1/vocabulary-pack-imports/{id}/validations",
        "POST /v1/vocabulary-pack-imports/{id}/commits",
        "POST /v1/imports", "GET /v1/imports/{id}", "DELETE /v1/imports/{id}",
        "PUT /v1/imports/{id}/files/{fileId}", "POST /v1/imports/{id}/validations",
        "POST /v1/imports/{id}/commits", "POST /v1/exports", "GET /v1/exports/{id}",
        "DELETE /v1/exports/{id}", "GET /v1/exports/{id}/content",
        "GET /v1/changes", "GET /v1/events",
    ]
    #expect(actual == expected)

    let vocabularySearchPath = try #require(
        paths["/v1/vocabulary-packs/{id}/entries"]
    )
    let vocabularySearch = try #require(vocabularySearchPath["get"] as? [String: Any])
    #expect(vocabularySearch["x-required-scope"] as? String == "vocabulary.read")
    let searchParameters = try #require(
        vocabularySearch["parameters"] as? [[String: Any]]
    )
    let queryParameter = try #require(searchParameters.first {
        $0["name"] as? String == "query"
    })
    #expect(queryParameter["required"] as? Bool == true)

    let commitPath = try #require(
        paths["/v1/vocabulary-pack-imports/{id}/commits"]
    )
    let commit = try #require(commitPath["post"] as? [String: Any])
    #expect(commit["x-required-scope"] as? String == "vocabulary.write")
    let commitParameters = try #require(commit["parameters"] as? [[String: Any]])
    #expect(commitParameters.contains {
        $0["name"] as? String == "If-Match" && $0["required"] as? Bool == true
    })
    #expect(commitParameters.contains {
        $0["name"] as? String == "Idempotency-Key" && $0["required"] as? Bool == true
    })

    let components = try #require(root["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])
    #expect(schemas["Object"] == nil)
    #expect(schemas["Resource"] == nil)
    #expect(schemas["VocabularyPack"] != nil)
    #expect(schemas["LexicalEntry"] != nil)
    #expect(schemas["VocabularyPackImport"] != nil)

    var references: [String] = []
    func collectReferences(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            if let reference = dictionary["$ref"] as? String {
                references.append(reference)
            }
            dictionary.values.forEach(collectReferences)
        } else if let values = value as? [Any] {
            values.forEach(collectReferences)
        }
    }
    collectReferences(root)
    for reference in references {
        let prefix = "#/components/schemas/"
        #expect(reference.hasPrefix(prefix))
        #expect(schemas[String(reference.dropFirst(prefix.count))] != nil)
    }

    for (_, pathItem) in paths {
        for (_, rawOperation) in pathItem {
            let operation = try #require(rawOperation as? [String: Any])
            let responses = try #require(operation["responses"] as? [String: Any])
            #expect(responses["default"] != nil)
            #expect(responses.keys.contains { Int($0).map { (200 ..< 300).contains($0) } == true })
        }
    }
}

@Test func corsOnlyReflectsApprovedOrigins() async throws {
    let api = try await makeAPI()
    let origin = "https://approved.example"
    let token = try await pair(api, scopes: ["library.read"], origin: origin)
    let approved = await api.handle(request(
        .get,
        "/v1/decks",
        headers: ["Authorization": "Bearer \(token)", "Origin": origin]
    ))
    #expect(approved.status == 200)
    #expect(approved.headers["Access-Control-Allow-Origin"] == origin)

    let hostileOrigin = "https://hostile.example"
    let denied = await api.handle(request(
        .get,
        "/v1/decks",
        headers: ["Authorization": "Bearer \(token)", "Origin": hostileOrigin]
    ))
    #expect(denied.status == 403)
    #expect(denied.headers["Access-Control-Allow-Origin"] == nil)

    let discovery = await api.handle(request(
        .get,
        "/health",
        headers: ["Origin": hostileOrigin]
    ))
    #expect(discovery.status == 200)
    #expect(discovery.headers["Access-Control-Allow-Origin"] == nil)

    let preflight = await api.handle(request(
        .options,
        "/v1/decks",
        headers: [
            "Origin": origin,
            "Access-Control-Request-Method": "GET",
        ]
    ))
    #expect(preflight.status == 204)
    #expect(preflight.headers["Access-Control-Allow-Methods"] == "GET")
    #expect(preflight.headers["Access-Control-Allow-Headers"] == "Content-Type, Authorization")

    let undocumentedMethod = await api.handle(request(
        .options,
        "/v1/decks",
        headers: [
            "Origin": origin,
            "Access-Control-Request-Method": "PUT",
        ]
    ))
    #expect(undocumentedMethod.status == 404)
    #expect(try jsonObject(undocumentedMethod)["code"] as? String == "resource_not_found")

    let undocumentedPath = await api.handle(request(
        .options,
        "/v1/not-a-route",
        headers: [
            "Origin": origin,
            "Access-Control-Request-Method": "GET",
        ]
    ))
    #expect(undocumentedPath.status == 404)
}

@Test func changesAndSSEReconnectWithoutDuplicatesAndExpirePrunedCursors() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "decks.write"])
    let cursor = try await store.currentChangeCursor()
    let headers = [
        "Host": "127.0.0.1:8766",
        "Authorization": "Bearer \(token)",
    ]
    let created = await api.handle(APIRequest(
        method: .post,
        path: "/v1/decks",
        headers: headers,
        body: Data(#"{"name":"SSE deck"}"#.utf8)
    ))
    let deckID = try #require(try jsonObject(created)["id"] as? String)
    let latest = try #require(
        created.headers["X-NeoAnki-Change-Cursor"].flatMap(Int64.init)
    )
    #expect(latest > cursor)
    #expect(try await store.currentChangeCursor() == latest)
    let plan = await api.handle(APIRequest(
        method: .post,
        path: "/v1/deck-deletion-plans",
        headers: headers,
        body: Data(#"{"deckId":"\#(deckID)","policy":"rejectIfNonempty"}"#.utf8)
    ))
    #expect(plan.status == 201)
    #expect(plan.headers["X-NeoAnki-Change-Cursor"] == nil)
    #expect(try await store.currentChangeCursor() == latest)
    let first = await api.handle(APIRequest(
        method: .get,
        path: "/v1/events",
        query: ["after": [String(cursor)]],
        headers: headers
    ))
    #expect(first.status == 200)
    #expect(first.headers["Content-Type"] == "text/event-stream; charset=utf-8")
    let stream = String(decoding: first.body, as: UTF8.self)
    #expect(stream.contains("id: \(latest)"))
    #expect(stream.contains(deckID))

    let changes = await api.handle(APIRequest(
        method: .get,
        path: "/v1/changes",
        query: ["after": [String(cursor)]],
        headers: headers
    ))
    let changeObject = try #require(
        (try jsonObject(changes)["data"] as? [[String: Any]])?.first
    )
    let dataLine = try #require(
        stream.split(separator: "\n").first { $0.hasPrefix("data: ") }
    )
    let streamedObject = try #require(
        JSONSerialization.jsonObject(with: Data(dataLine.dropFirst(6).utf8))
            as? [String: Any]
    )
    #expect(NSDictionary(dictionary: streamedObject).isEqual(to: changeObject))

    let reconnect = await api.handle(APIRequest(
        method: .get,
        path: "/v1/events",
        headers: headers.merging(["Last-Event-ID": String(latest)]) { _, new in new }
    ))
    #expect(reconnect.status == 200)
    #expect(String(decoding: reconnect.body, as: UTF8.self) == ": keep-alive\n\n")

    _ = try await store.pruneLibraryChanges(
        asOf: Date.now.addingTimeInterval(1),
        retentionInterval: 0,
        minimumRetained: 1
    )
    let expired = await api.handle(APIRequest(
        method: .get,
        path: "/v1/changes",
        query: ["after": ["0"]],
        headers: headers
    ))
    #expect(expired.status == 410)
    #expect(try jsonObject(expired)["code"] as? String == "cursor_expired")
}

@Test func pairingIssuesOneScopedTokenAndCurrentClientCanRevokeIt() async throws {
    let api = try await makeAPI()
    let token = try await pair(api, scopes: ["library.read"])
    #expect(token.count >= 43)

    let current = await api.handle(
        request(
            .get,
            "/v1/clients/current",
            headers: ["Authorization": "Bearer \(token)"]
        )
    )
    #expect(current.status == 200)
    let client = try jsonObject(current)
    #expect((client["id"] as? String)?.lowercased() == client["id"] as? String)
    #expect(client["scopes"] as? [String] == ["library.read"])

    let insufficient = await api.handle(
        request(
            .post,
            "/v1/decks",
            headers: [
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": "one",
            ],
            body: "{\"name\":\"Test\"}"
        )
    )
    #expect(insufficient.status == 403)
    #expect(try jsonObject(insufficient)["code"] as? String == "insufficient_scope")

    let revoke = await api.handle(
        request(
            .delete,
            "/v1/clients/current",
            headers: [
                "Authorization": "Bearer \(token)",
                "If-Match": "\"revision-1\"",
            ]
        )
    )
    #expect(revoke.status == 204)
    let after = await api.handle(
        request(
            .get,
            "/v1/clients/current",
            headers: ["Authorization": "Bearer \(token)"]
        )
    )
    #expect(after.status == 401)
}

@Test func pairingLimitsExpiryValidationAndCredentialRedactionAreEnforced() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await store.bootstrap()
    let persistence = InMemoryAPICredentialPersistence()
    let authorization = APIAuthorizationStore(persistence: persistence)
    let blocker = BlockingPairingApprover()
    let blockedAPI = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: blocker,
        applicationVersion: "test"
    )
    let pairingBody = #"{"displayName":"Browser","requestedScopes":["library.read","items.write","media.write"],"origin":"https://approved.example"}"#
    let firstTask = Task {
        await blockedAPI.handle(request(
            .post,
            "/v1/pairings",
            headers: ["Origin": "https://approved.example"],
            body: pairingBody
        ))
    }
    while !(await blocker.started) { await Task.yield() }
    let overlapping = await blockedAPI.handle(request(
        .post,
        "/v1/pairings",
        headers: ["Origin": "https://approved.example"],
        body: pairingBody
    ))
    #expect(overlapping.status == 429)
    await blocker.resolve(true)
    let approved = await firstTask.value
    #expect(approved.status == 201)
    let approvedObject = try jsonObject(approved)
    let token = try #require(approvedObject["token"] as? String)
    var base64Token = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64Token += String(repeating: "=", count: (4 - base64Token.count % 4) % 4)
    #expect(Data(base64Encoded: base64Token)?.count == 32)
    let client = try #require(approvedObject["client"] as? [String: Any])
    #expect(Set(client["scopes"] as? [String] ?? []) == Set([
        "library.read", "items.write", "media.write",
    ]))
    let persistedCredentials = try #require(await persistence.load())
    #expect(!String(decoding: persistedCredentials, as: UTF8.self).contains(token))
    #expect(String(decoding: persistedCredentials, as: UTF8.self).contains(APICrypto.sha256Hex(Data(token.utf8))))

    let invalidName = await blockedAPI.handle(request(
        .post,
        "/v1/pairings",
        body: #"{"displayName":"bad\u0000name","requestedScopes":["library.read"]}"#
    ))
    #expect(invalidName.status == 422)
    let overlongName = String(repeating: "é", count: 129)
    let overlongBody = try JSONSerialization.data(withJSONObject: [
        "displayName": overlongName,
        "requestedScopes": ["library.read"],
    ])
    let overlong = await blockedAPI.handle(APIRequest(
        method: .post,
        path: "/v1/pairings",
        headers: ["Host": "127.0.0.1:8766"],
        body: overlongBody
    ))
    #expect(overlong.status == 422)

    let rateAPI = try await makeAPI()
    for index in 0 ..< 5 {
        let result = await rateAPI.handle(request(
            .post,
            "/v1/pairings",
            body: #"{"displayName":"Client \#(index)","requestedScopes":["library.read"]}"#
        ))
        #expect(result.status == 201)
    }
    let sixth = await rateAPI.handle(request(
        .post,
        "/v1/pairings",
        body: #"{"displayName":"Sixth","requestedScopes":["library.read"]}"#
    ))
    #expect(sixth.status == 429)

    let expiringStore = try ItemStore(databaseURL: apiTestDatabaseURL(), starterItemTypes: [])
    try await expiringStore.bootstrap()
    let expiringAPI = NeoAnkiAPIService(
        store: expiringStore,
        authorization: APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        ),
        pairingApprover: SlowPairingApprover(),
        applicationVersion: "test",
        pairingRequestLifetime: 0.01
    )
    let startedAt = ContinuousClock.now
    let expired = await expiringAPI.handle(request(
        .post,
        "/v1/pairings",
        body: #"{"displayName":"Expires","requestedScopes":["library.read"]}"#
    ))
    #expect(expired.status == 403)
    #expect(try jsonObject(expired)["code"] as? String == "pairing_denied")
    #expect(startedAt.duration(to: .now) < .seconds(1))
}

@Test func verifierFilePersistsOnlyTokenHashesWithPrivatePermissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "neoanki-api-verifiers-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory
        .appendingPathComponent(".neoanki-api", isDirectory: true)
        .appendingPathComponent(VerifierFileAPICredentialPersistence.fileName)
    let authorization = APIAuthorizationStore(
        persistence: VerifierFileAPICredentialPersistence(fileURL: fileURL)
    )

    let issued = try await authorization.issueGrant(
        displayName: "Durable client",
        origin: "https://approved.example",
        scopes: [.libraryRead, .itemsWrite]
    )
    let persisted = try Data(contentsOf: fileURL)
    let persistedText = String(decoding: persisted, as: UTF8.self)
    #expect(!persistedText.contains(issued.token))
    #expect(persistedText.contains(APICrypto.sha256Hex(Data(issued.token.utf8))))

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

    let reopened = APIAuthorizationStore(
        persistence: VerifierFileAPICredentialPersistence(fileURL: fileURL)
    )
    let restoredGrant = try #require(try await reopened.authenticate(token: issued.token))
    #expect(restoredGrant.id == issued.grant.id)
    #expect(restoredGrant.displayName == issued.grant.displayName)
    #expect(restoredGrant.origin == issued.grant.origin)
    #expect(restoredGrant.scopes == issued.grant.scopes)
    #expect(try await reopened.revoke(clientID: issued.grant.id))

    let afterRevocation = APIAuthorizationStore(
        persistence: VerifierFileAPICredentialPersistence(fileURL: fileURL)
    )
    #expect(try await afterRevocation.authenticate(token: issued.token) == nil)
}

@Test func verifierFileRejectsInsecureOrUnexpectedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "neoanki-api-verifier-security-\(UUID().uuidString)", isDirectory: true
    )
    let directory = root.appendingPathComponent(".neoanki-api", isDirectory: true)
    let fileURL = directory.appendingPathComponent(
        VerifierFileAPICredentialPersistence.fileName,
        isDirectory: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try Data("[]".utf8).write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fileURL.path
    )
    let insecure = VerifierFileAPICredentialPersistence(fileURL: fileURL)
    await #expect(throws: APIAuthorizationError.self) {
        try await insecure.load()
    }

    try FileManager.default.removeItem(at: fileURL)
    let targetURL = root.appendingPathComponent("target.json")
    try Data("[]".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: targetURL)
    let symbolicLink = VerifierFileAPICredentialPersistence(fileURL: fileURL)
    await #expect(throws: APIAuthorizationError.self) {
        try await symbolicLink.load()
    }
}

@Test func deckCreateReplayPaginationAndOptimisticUpdateAreStable() async throws {
    let api = try await makeAPI()
    let token = try await pair(api, scopes: ["library.read", "decks.write"])
    let authorization = ["Authorization": "Bearer \(token)"]
    let deckID = UUID().uuidString.lowercased()
    let createBody = "{\"id\":\"\(deckID)\",\"name\":\"Geography\",\"newCardsPerDay\":10}"
    var createHeaders = authorization
    createHeaders["Idempotency-Key"] = "create-geography"

    let created = await api.handle(
        request(.post, "/v1/decks", headers: createHeaders, body: createBody)
    )
    let replayed = await api.handle(
        request(.post, "/v1/decks", headers: createHeaders, body: createBody)
    )
    #expect(created.status == 201)
    #expect(replayed.status == 201)
    #expect(created.body == replayed.body)
    #expect(created.headers["ETag"] == "\"revision-1\"")
    #expect(try jsonObject(created)["id"] as? String == deckID)

    let listed = await api.handle(
        request(.get, "/v1/decks", headers: authorization)
    )
    #expect(listed.status == 200)
    let data = try #require(try jsonObject(listed)["data"] as? [[String: Any]])
    #expect(data.count == 1)

    let withoutIdempotency = await api.handle(request(
        .post,
        "/v1/decks",
        headers: authorization,
        body: #"{"name":"No idempotency required"}"#
    ))
    #expect(withoutIdempotency.status == 201)
    let collision = await api.handle(request(
        .post,
        "/v1/decks",
        headers: authorization,
        body: #"{"id":"\#(deckID)","name":"Collision"}"#
    ))
    #expect(collision.status == 409)
    #expect(try jsonObject(collision)["code"] as? String == "resource_id_conflict")

    var staleHeaders = authorization
    staleHeaders["If-Match"] = "\"revision-0\""
    let stale = await api.handle(
        request(
            .patch,
            "/v1/decks/\(deckID)",
            headers: staleHeaders,
            body: "{\"name\":\"World Geography\"}"
        )
    )
    #expect(stale.status == 412)

    var updateHeaders = authorization
    updateHeaders["If-Match"] = "\"revision-1\""
    let updated = await api.handle(
        request(
            .patch,
            "/v1/decks/\(deckID)",
            headers: updateHeaders,
            body: "{\"name\":\"World Geography\",\"newCardsPerDay\":null}"
        )
    )
    #expect(updated.status == 200)
    #expect(updated.headers["ETag"] == "\"revision-2\"")
    #expect(try jsonObject(updated)["name"] as? String == "World Geography")

    let changes = await api.handle(
        request(.get, "/v1/changes?unused", headers: authorization)
    )
    // The transport parser owns query splitting; the service rejects a literal
    // path not present in the versioned router.
    #expect(changes.status == 404)
}

@Test func strictInputRejectsUnknownMembersUppercaseUUIDAndOversizedJSON() async throws {
    let api = try await makeAPI()
    let token = try await pair(api, scopes: ["decks.write"])
    let headers = [
        "Authorization": "Bearer \(token)",
        "Idempotency-Key": "strict",
    ]
    let unknown = await api.handle(
        request(.post, "/v1/decks", headers: headers, body: "{\"name\":\"X\",\"naem\":\"Y\"}")
    )
    #expect(unknown.status == 422)
    #expect(try jsonObject(unknown)["code"] as? String == "validation_failed")

    let uppercase = UUID().uuidString
    let invalidID = await api.handle(
        request(
            .post,
            "/v1/decks",
            headers: headers.merging(["Idempotency-Key": "uuid"]) { _, new in new },
            body: "{\"id\":\"\(uppercase)\",\"name\":\"X\"}"
        )
    )
    #expect(invalidID.status == 422)

    let oversized = await api.handle(
        APIRequest(
            method: .post,
            path: "/v1/decks",
            headers: ["Host": "127.0.0.1:8766"],
            body: Data(repeating: 0x20, count: NeoAnkiAPIService.maximumJSONBodyBytes + 1)
        )
    )
    #expect(oversized.status == 413)

    let writeToken = try await pair(api, scopes: ["items.write", "library.import"])
    let nestedItem = await api.handle(request(
        .post,
        "/v1/items",
        headers: [
            "Authorization": "Bearer \(writeToken)",
            "Idempotency-Key": "nested-item",
        ],
        body: """
        {"itemTypeId":"\(UUID().uuidString.lowercased())","deckId":null,
         "fields":[{"fieldId":"\(UUID().uuidString.lowercased())",
         "value":{"type":"text","text":"x","typo":true}}],"tags":[]}
        """
    ))
    #expect(nestedItem.status == 422)
    let itemErrors = try #require(try jsonObject(nestedItem)["errors"] as? [[String: Any]])
    #expect(itemErrors.first?["pointer"] as? String == "/fields/0/value/typo")

    let nestedManifest = await api.handle(request(
        .post,
        "/v1/imports",
        headers: ["Authorization": "Bearer \(writeToken)"],
        body: #"{"format":"json","files":[{"relativePath":"x.json","byteSize":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","typo":true}]}"#
    ))
    #expect(nestedManifest.status == 422)
    let manifestErrors = try #require(
        try jsonObject(nestedManifest)["errors"] as? [[String: Any]]
    )
    #expect(manifestErrors.first?["pointer"] as? String == "/files/0/typo")

    let oversizedImportControl = await api.handle(APIRequest(
        method: .post,
        path: "/v1/imports/\(UUID().uuidString.lowercased())/validations",
        headers: ["Host": "127.0.0.1:8766"],
        body: Data(repeating: 0x20, count: NeoAnkiAPIService.maximumJSONBodyBytes + 1)
    ))
    #expect(oversizedImportControl.status == 413)
}

@Test func studySessionReservesGradesReplaysAndEndsSafely() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["study.review"])
    let auth = ["Authorization": "Bearer \(token)"]
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )
    _ = try await store.createItem(item)

    let created = await api.handle(
        request(
            .post,
            "/v1/study-sessions",
            headers: auth,
            body: #"{"scope":{"kind":"allDecks"}}"#
        )
    )
    #expect(created.status == 201)
    #expect(created.headers["ETag"] == "\"revision-1\"")
    let sessionID = try #require(try jsonObject(created)["id"] as? String)

    let next = await api.handle(
        request(.post, "/v1/study-sessions/\(sessionID)/next", headers: auth)
    )
    #expect(next.status == 200)
    let nextBody = try jsonObject(next)
    let cardID = try #require(nextBody["id"] as? String)
    #expect((nextBody["prompt"] as? [Any])?.isEmpty == false)
    let memoryBeforeReview = try await store.card(id: UUID(uuidString: cardID)!).memory
    let retryNext = await api.handle(
        request(.post, "/v1/study-sessions/\(sessionID)/next", headers: auth)
    )
    #expect(try jsonObject(retryNext)["id"] as? String == cardID)

    let reviewBody = """
        {"sessionId":"\(sessionID)","cardId":"\(cardID)","rating":"good","durationMs":125}
        """
    var reviewHeaders = auth
    reviewHeaders["Idempotency-Key"] = "grade-once"
    let reviewed = await api.handle(
        request(.post, "/v1/reviews", headers: reviewHeaders, body: reviewBody)
    )
    let replayed = await api.handle(
        request(.post, "/v1/reviews", headers: reviewHeaders, body: reviewBody)
    )
    #expect(reviewed.status == 201)
    #expect(replayed.status == 201)
    #expect(reviewed.body == replayed.body)
    let reviewLogID = try #require(try jsonObject(reviewed)["reviewLogId"] as? String)
    #expect(try await store.activeReviewLogCount(for: UUID(uuidString: cardID)!) == 1)
    #expect(!reviewLogID.isEmpty)

    let duplicate = await api.handle(
        request(
            .post,
            "/v1/reviews",
            headers: auth.merging(["Idempotency-Key": "different-attempt"]) { _, new in new },
            body: reviewBody
        )
    )
    #expect(duplicate.status == 409)
    #expect(try jsonObject(duplicate)["code"] as? String == "study_conflict")

    let reverted = await api.handle(request(
        .post,
        "/v1/reviews/\(reviewLogID)/reverts",
        headers: auth.merging([
            "If-Match": try #require(reviewed.headers["ETag"]),
            "Idempotency-Key": "revert-once",
        ]) { _, new in new }
    ))
    #expect(reverted.status == 204)
    #expect(try await store.card(id: UUID(uuidString: cardID)!).memory == memoryBeforeReview)
    #expect(try await store.activeReviewLogCount(for: UUID(uuidString: cardID)!) == 0)
    let repeatedRevert = await api.handle(request(
        .post,
        "/v1/reviews/\(reviewLogID)/reverts",
        headers: auth.merging([
            "If-Match": try #require(reviewed.headers["ETag"]),
            "Idempotency-Key": "different-revert",
        ]) { _, new in new }
    ))
    #expect([404, 412].contains(repeatedRevert.status))
    #expect(try await store.card(id: UUID(uuidString: cardID)!).memory == memoryBeforeReview)

    let session = await api.handle(
        request(.get, "/v1/study-sessions/\(sessionID)", headers: auth)
    )
    let etag = try #require(session.headers["ETag"])
    let ended = await api.handle(
        request(
            .delete,
            "/v1/study-sessions/\(sessionID)",
            headers: auth.merging(["If-Match": etag]) { _, new in new }
        )
    )
    #expect(ended.status == 204)
}

@Test func concurrentRevisionsAndOneHundredIdempotentReviewReplaysAreLinearizable() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service() -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
    }
    let api = service()
    let secondAPIAdapter = service()
    let token = try await pair(
        api,
        scopes: ["library.read", "decks.write", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]

    let deck = await api.handle(request(
        .post,
        "/v1/decks",
        headers: auth.merging(["Idempotency-Key": "concurrent-deck"]) { _, new in new },
        body: #"{"name":"Initial"}"#
    ))
    let deckID = try #require(try jsonObject(deck)["id"] as? String)
    let deckETag = try #require(deck.headers["ETag"])
    let updateResults = await withTaskGroup(of: APIResponse.self) { group in
        for (adapter, name) in [
            (api, "First winner"),
            (secondAPIAdapter, "Second winner"),
        ] {
            group.addTask {
                await adapter.handle(request(
                    .patch,
                    "/v1/decks/\(deckID)",
                    headers: auth.merging(["If-Match": deckETag]) { _, new in new },
                    body: #"{"name":"\#(name)"}"#
                ))
            }
        }
        var values: [APIResponse] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(updateResults.map(\.status).sorted() == [200, 412])
    let winningResponse = try #require(updateResults.first { $0.status == 200 })
    let winningName = try #require(try jsonObject(winningResponse)["name"] as? String)
    let persistedDeck = await api.handle(request(
        .get, "/v1/decks/\(deckID)", headers: auth
    ))
    #expect(try jsonObject(persistedDeck)["name"] as? String == winningName)

    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Replay")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Exactly once")),
        ]
    ))
    let session = await api.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(session)["id"] as? String)
    let next = await api.handle(request(
        .post, "/v1/study-sessions/\(sessionID)/next", headers: auth
    ))
    let cardID = try #require(try jsonObject(next)["id"] as? String)
    let reviewBody = #"{"sessionId":"\#(sessionID)","cardId":"\#(cardID)","rating":"good","durationMs":42}"#
    let reviewHeaders = auth.merging(["Idempotency-Key": "one-hundred-replays"]) {
        _, new in new
    }
    let responses = await withTaskGroup(of: APIResponse.self) { group in
        for _ in 0 ..< 100 {
            group.addTask {
                await api.handle(request(
                    .post, "/v1/reviews", headers: reviewHeaders, body: reviewBody
                ))
            }
        }
        var values: [APIResponse] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(responses.count == 100)
    #expect(responses.allSatisfy { $0.status == 201 })
    #expect(Set(responses.map(\.body)).count == 1)
    let reviewID = try #require(try jsonObject(responses[0])["reviewLogId"] as? String)
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)
    let reviewChanges = try await store.libraryChanges(after: 0).filter {
        $0.resourceID.lowercased() == reviewID
    }
    #expect(reviewChanges.count == 1)
}

@Test func studySessionsArePrivateToTheirOwningClientAndValidateNestedInput() async throws {
    let (api, _) = try await makeAPIAndStore()
    let firstToken = try await pair(api, scopes: ["study.review"])
    let secondToken = try await pair(api, scopes: ["study.review"])
    let firstAuth = ["Authorization": "Bearer \(firstToken)"]
    let created = await api.handle(
        request(
            .post,
            "/v1/study-sessions",
            headers: firstAuth,
            body: #"{"scope":{"kind":"unassigned"}}"#
        )
    )
    let sessionID = try #require(try jsonObject(created)["id"] as? String)

    let hidden = await api.handle(
        request(
            .get,
            "/v1/study-sessions/\(sessionID)",
            headers: ["Authorization": "Bearer \(secondToken)"]
        )
    )
    #expect(hidden.status == 404)

    let unknown = await api.handle(
        request(
            .post,
            "/v1/study-sessions",
            headers: firstAuth,
            body: #"{"scope":{"kind":"allDecks","typo":true}}"#
        )
    )
    #expect(unknown.status == 422)
    #expect(try jsonObject(unknown)["code"] as? String == "validation_failed")
}

@Test func itemAndCardAuthoringRoutesPreserveIdentityAndEnforceRevisions() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "items.write", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let itemID = UUID().uuidString.lowercased()
    let createBody = """
        {
          "id":"\(itemID)",
          "itemTypeId":"\(BuiltInItemTypes.basicID.uuidString.lowercased())",
          "deckId":null,
          "fields":[
            {"fieldId":"\(BuiltInItemTypes.frontFieldID.uuidString.lowercased())","value":{"type":"text","text":"Front"}},
            {"fieldId":"\(BuiltInItemTypes.backFieldID.uuidString.lowercased())","value":{"type":"text","text":"Back"}}
          ],
          "tags":[" alpha ","alpha","beta"]
        }
        """
    var createHeaders = auth
    createHeaders["Idempotency-Key"] = "create-item"
    let created = await api.handle(
        request(.post, "/v1/items", headers: createHeaders, body: createBody)
    )
    let replay = await api.handle(
        request(.post, "/v1/items", headers: createHeaders, body: createBody)
    )
    #expect(created.status == 201)
    #expect(created.body == replay.body)
    #expect(try jsonObject(created)["tags"] as? [String] == ["alpha", "beta"])
    let cardIDs = try #require(try jsonObject(created)["cardIds"] as? [String])
    let cardID = try #require(cardIDs.first)

    let cards = await api.handle(request(.get, "/v1/cards", headers: auth))
    let cardData = try #require(try jsonObject(cards)["data"] as? [[String: Any]])
    #expect(cardData.map { $0["id"] as? String }.contains(cardID))

    let content = await api.handle(request(.get, "/v1/cards/\(cardID)/content", headers: auth))
    #expect(content.status == 200)
    #expect((try jsonObject(content)["prompt"] as? [Any])?.isEmpty == false)

    let cursorBefore = try await api.handle(
        request(.get, "/v1/changes", headers: auth)
    ).body
    let preview = await api.handle(
        request(.get, "/v1/cards/\(cardID)/review-preview", headers: auth)
    )
    #expect(preview.status == 200)
    let cursorAfter = try await api.handle(
        request(.get, "/v1/changes", headers: auth)
    ).body
    #expect(cursorBefore == cursorAfter)

    var suspendHeaders = auth
    suspendHeaders["If-Match"] = try #require(content.headers["ETag"])
    let suspended = await api.handle(
        request(
            .patch,
            "/v1/cards/\(cardID)",
            headers: suspendHeaders,
            body: #"{"isSuspended":true}"#
        )
    )
    #expect(suspended.status == 200)
    #expect(try jsonObject(suspended)["isSuspended"] as? Bool == true)

    let updateBody = createBody
        .replacingOccurrences(of: "\"id\":\"\(itemID)\",", with: "")
        .replacingOccurrences(of: "\"Front\"", with: "\"Updated front\"")
    var updateHeaders = auth
    updateHeaders["If-Match"] = try #require(created.headers["ETag"])
    let updated = await api.handle(
        request(.put, "/v1/items/\(itemID)", headers: updateHeaders, body: updateBody)
    )
    #expect(updated.status == 200)
    #expect(try jsonObject(updated)["cardIds"] as? [String] == cardIDs)

    let tags = await api.handle(request(.get, "/v1/tags", headers: auth))
    let tagData = try #require(try jsonObject(tags)["data"] as? [[String: Any]])
    #expect(tagData.map { $0["name"] as? String }.contains("alpha"))
    let renamed = await api.handle(
        request(
            .post,
            "/v1/tag-renames",
            headers: auth.merging(["If-Match": tags.headers["ETag"]!]) { _, new in new },
            body: #"{"from":"alpha","to":"beta"}"#
        )
    )
    #expect(renamed.status == 200)
    let afterRename = await api.handle(request(.get, "/v1/items/\(itemID)", headers: auth))
    #expect(try jsonObject(afterRename)["tags"] as? [String] == ["beta"])

    let itemBeforeTagRemoval = try await store.itemRecord(id: UUID(uuidString: itemID)!).item
    let cardBeforeTagRemoval = try await store.card(id: UUID(uuidString: cardID)!)
    let tagsAfterRename = await api.handle(request(.get, "/v1/tags", headers: auth))
    let removedTag = await api.handle(request(
        .delete,
        "/v1/tags/beta",
        headers: auth.merging([
            "If-Match": tagsAfterRename.headers["ETag"]!,
        ]) { _, new in new }
    ))
    #expect(removedTag.status == 204)
    let afterTagRemoval = await api.handle(request(
        .get, "/v1/items/\(itemID)", headers: auth
    ))
    #expect(try jsonObject(afterTagRemoval)["tags"] as? [String] == [])
    let itemAfterTagRemoval = try await store.itemRecord(id: UUID(uuidString: itemID)!).item
    let cardAfterTagRemoval = try await store.card(id: UUID(uuidString: cardID)!)
    #expect(itemAfterTagRemoval.fields == itemBeforeTagRemoval.fields)
    #expect(cardAfterTagRemoval == cardBeforeTagRemoval)

    var deleteHeaders = auth
    deleteHeaders["If-Match"] = try #require(afterTagRemoval.headers["ETag"])
    let deleted = await api.handle(
        request(.delete, "/v1/items/\(itemID)", headers: deleteHeaders)
    )
    #expect(deleted.status == 204)
    #expect(await api.handle(request(.get, "/v1/cards/\(cardID)", headers: auth)).status == 404)
}

@Test func resolvedCardContentMatchesCoreForEveryInteraction() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read"])
    let auth = ["Authorization": "Bearer \(token)"]

    for (index, interaction) in Interaction.allCases.enumerated() {
        let promptField = FieldDef(
            name: "Prompt",
            type: interaction == .cloze ? .cloze : .text,
            isRequired: true
        )
        let answerField = FieldDef(name: "Answer", type: .text, isRequired: true)
        let template = Template(
            name: interaction.rawValue,
            prompt: Side(slots: [Slot(
                source: .field(promptField.id),
                presentation: Presentation(reveal: .blurred)
            )]),
            answer: Side(slots: [
                Slot(source: .literal("Answer:")),
                Slot(
                    source: .field(answerField.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ]),
            interaction: interaction,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )
        let type = ItemType(
            name: "Interaction \(index)",
            fields: [promptField, answerField],
            templates: [template]
        )
        _ = try await store.createItemType(type)
        let promptValue: ContentValue = interaction == .cloze
            ? .cloze("One two", blanks: [ClozeSpan(group: 1, start: 4, length: 3)])
            : .text("Prompt \(index)")
        let item = Item(
            itemTypeID: type.id,
            fields: [
                FieldValue(fieldID: promptField.id, value: promptValue),
                FieldValue(fieldID: answerField.id, value: .text("Answer \(index)")),
            ]
        )
        _ = try await store.createItem(item)
        let card = try #require(try await store.cards().first { $0.itemID == item.id })
        let response = await api.handle(request(
            .get,
            "/v1/cards/\(card.id.uuidString.lowercased())/content",
            headers: auth
        ))
        #expect(response.status == 200)
        let representation = try APIJSON.decoder.decode(APIStudyCard.self, from: response.body)
        let expectedPrompt = SideContent.resolvedSlots(for: template.prompt, from: item)
        let expectedAnswer = SideContent.resolvedSlots(for: template.answer, from: item)
        #expect(representation.interaction == interaction.rawValue)
        #expect(representation.prompt.map(\.value) == expectedPrompt.map(\.value))
        #expect(representation.prompt.map(\.presentation) == expectedPrompt.map(\.presentation))
        #expect(representation.answer.map(\.value) == expectedAnswer.map(\.value))
        #expect(representation.answer.map(\.presentation) == expectedAnswer.map(\.presentation))
    }
}

@Test func itemValidationRejectsDuplicateFieldsWithoutWritingChanges() async throws {
    let (api, _) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let auth = ["Authorization": "Bearer \(token)"]
    let fieldID = BuiltInItemTypes.frontFieldID.uuidString.lowercased()
    let body = """
        {
          "itemTypeId":"\(BuiltInItemTypes.basicID.uuidString.lowercased())",
          "deckId":null,
          "fields":[
            {"fieldId":"\(fieldID)","value":{"type":"text","text":"One"}},
            {"fieldId":"\(fieldID)","value":{"type":"text","text":"Two"}}
          ],
          "tags":[]
        }
        """
    let before = await api.handle(request(.get, "/v1/changes", headers: auth))
    let invalid = await api.handle(
        request(.post, "/v1/items/validate", headers: auth, body: body)
    )
    let after = await api.handle(request(.get, "/v1/changes", headers: auth))
    #expect(invalid.status == 422)
    #expect(before.body == after.body)
}

@Test func itemTypeRoutesRequireImpactConfirmationAndPreserveStableTemplateCards() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "schemas.write"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    _ = try await store.itemType(id: BuiltInItemTypes.basicID)
    let duplicate = await api.handle(
        request(
            .post,
            "/v1/item-types/\(BuiltInItemTypes.basicID.uuidString.lowercased())/duplicate",
            headers: auth,
            body: #"{"name":"Impact Test"}"#
        )
    )
    #expect(duplicate.status == 201, Comment(rawValue: String(data: duplicate.body, encoding: .utf8) ?? ""))
    let duplicated = try jsonObject(duplicate)
    let typeID = try #require(duplicated["id"] as? String)
    let originalFields = try #require(duplicated["fields"] as? [[String: Any]])
    #expect(!Set(originalFields.compactMap { $0["id"] as? String }).contains(
        BuiltInItemTypes.frontFieldID.uuidString.lowercased()
    ))

    var updateObject: [String: Any] = [
        "id": typeID,
        "name": "Impact Test",
        "fields": originalFields,
        "templates": try #require(duplicated["templates"] as? [[String: Any]]),
    ]
    var templates = try #require(updateObject["templates"] as? [[String: Any]])
    var second = try #require(templates.first)
    let secondTemplateID = UUID().uuidString.lowercased()
    second["id"] = secondTemplateID
    second["name"] = "Second"
    templates.append(second)
    updateObject["templates"] = templates
    let addTemplateBody = String(
        data: try JSONSerialization.data(withJSONObject: updateObject, options: [.sortedKeys]),
        encoding: .utf8
    )!
    var updateHeaders = auth
    updateHeaders["If-Match"] = try #require(duplicate.headers["ETag"])
    let added = await api.handle(
        request(.put, "/v1/item-types/\(typeID)", headers: updateHeaders, body: addTemplateBody)
    )
    #expect(added.status == 200, Comment(rawValue: String(data: added.body, encoding: .utf8) ?? ""))

    let typeUUID = try #require(UUID(uuidString: typeID))
    let domainType = try await store.itemType(id: typeUUID)
    let item = Item(
        itemTypeID: typeUUID,
        fields: domainType.fields.map { field in
            FieldValue(fieldID: field.id, value: .text(field.name))
        }
    )
    let saved = try await store.createItem(item)
    #expect(saved.cardCount == 2)

    templates.removeAll { $0["id"] as? String == secondTemplateID }
    updateObject["templates"] = templates
    let removeTemplateBody = String(
        data: try JSONSerialization.data(withJSONObject: updateObject, options: [.sortedKeys]),
        encoding: .utf8
    )!
    var impactHeaders = auth
    impactHeaders["If-Match"] = try #require(added.headers["ETag"])
    let needsConfirmation = await api.handle(
        request(
            .put,
            "/v1/item-types/\(typeID)",
            headers: impactHeaders,
            body: removeTemplateBody
        )
    )
    #expect(needsConfirmation.status == 409)
    let problem = try jsonObject(needsConfirmation)
    #expect(problem["code"] as? String == "impact_confirmation_required")
    let impact = try #require(problem["impact"] as? [String: Any])
    #expect(impact["affectedCardCount"] as? Int == 1)
    impactHeaders["NeoAnki-Impact-Token"] = try #require(problem["impactToken"] as? String)
    let confirmed = await api.handle(
        request(
            .put,
            "/v1/item-types/\(typeID)",
            headers: impactHeaders,
            body: removeTemplateBody
        )
    )
    #expect(confirmed.status == 200)
    #expect(try await store.itemRecord(id: item.id).cardIDs.count == 1)

    var deleteHeaders = auth
    deleteHeaders["If-Match"] = try #require(confirmed.headers["ETag"])
    let inUse = await api.handle(
        request(.delete, "/v1/item-types/\(typeID)", headers: deleteHeaders)
    )
    #expect(inUse.status == 409)
    #expect(try jsonObject(inUse)["code"] as? String == "resource_in_use")
}

@Test func mediaUploadDownloadDeduplicatesBytesAndReservationsAdoptIndependently() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "media.write", "items.write"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x41])
    func upload(_ key: String, kind: String = "image") async -> APIResponse {
        return await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
                "NeoAnki-Media-Kind": kind,
            ],
            body: bytes
        ))
    }
    let first = await upload("first-upload")
    let firstReplay = await upload("first-upload")
    let second = await upload("second-upload")
    #expect(first.status == 201)
    #expect(first.body == firstReplay.body)
    let firstObject = try jsonObject(first)
    let secondObject = try jsonObject(second)
    let hash = try #require(firstObject["assetHash"] as? String)
    #expect(secondObject["assetHash"] as? String == hash)
    #expect(secondObject["reservationId"] as? String != firstObject["reservationId"] as? String)

    let downloaded = await api.handle(request(.get, "/v1/media/\(hash)", headers: auth))
    #expect(downloaded.status == 200)
    #expect(downloaded.body == bytes)
    #expect(downloaded.headers["Content-Type"] == "image/png")
    let head = await api.handle(request(.head, "/v1/media/\(hash)", headers: auth))
    #expect(head.status == 200)
    #expect(head.body.isEmpty)
    #expect(head.headers["Content-Length"] == String(bytes.count))
    let range = await api.handle(request(
        .get,
        "/v1/media/\(hash)",
        headers: auth.merging(["Range": "bytes=0-3"]) { _, new in new }
    ))
    #expect(range.status == 416)
    #expect(range.headers["Accept-Ranges"] == "none")
    #expect(await api.handle(
        request(.get, "/v1/media/\(String(repeating: "0", count: 64))", headers: auth)
    ).status == 404)
    let wrongKind = await upload("wrong-kind", kind: "audio")
    #expect(wrongKind.status == 422)

    let imageField = FieldDef(name: "Image", type: .image, isRequired: true)
    let answerField = FieldDef(name: "Answer", type: .text, isRequired: true)
    let template = Template(
        name: "Image card",
        prompt: Side(slots: [Slot(source: .field(imageField.id))]),
        answer: Side(slots: [Slot(source: .field(answerField.id))]),
        interaction: .reveal,
        skill: Skill(input: .image, output: .text, operation: .recall)
    )
    let type = ItemType(name: "Media API", fields: [imageField, answerField], templates: [template])
    _ = try await store.createItemType(type)

    func createMediaItem(
        _ key: String,
        reservation: [String: Any],
        assetHash: String? = nil
    ) async throws -> APIResponse {
        let body: [String: Any] = [
            "itemTypeId": type.id.uuidString.lowercased(),
            "deckId": NSNull(),
            "fields": [
                [
                    "fieldId": imageField.id.uuidString.lowercased(),
                    "value": [
                        "type": "media",
                        "mediaId": UUID().uuidString.lowercased(),
                        "kind": "image",
                        "sha256": assetHash ?? hash,
                        "fileExtension": "png",
                        "reservationId": try #require(reservation["reservationId"] as? String),
                    ],
                ],
                [
                    "fieldId": answerField.id.uuidString.lowercased(),
                    "value": ["type": "text", "text": "Answer"],
                ],
            ],
            "tags": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return await api.handle(APIRequest(
            method: .post,
            path: "/v1/items",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
            ],
            body: data
        ))
    }

    let fabricatedReservation: [String: Any] = [
        "reservationId": UUID().uuidString.lowercased(),
    ]
    let unresolvedReservation = try await createMediaItem(
        "fabricated-media-reservation",
        reservation: fabricatedReservation
    )
    #expect(unresolvedReservation.status == 422)
    #expect(try jsonObject(unresolvedReservation)["code"] as? String == "validation_failed")

    let unresolvedAsset = try await createMediaItem(
        "missing-media-asset",
        reservation: firstObject,
        assetHash: String(repeating: "0", count: 64)
    )
    #expect(unresolvedAsset.status == 422)
    #expect(try await store.listItems().isEmpty)

    let itemOne = try await createMediaItem("media-item-one", reservation: firstObject)
    let itemTwo = try await createMediaItem("media-item-two", reservation: secondObject)
    #expect(itemOne.status == 201)
    #expect(itemTwo.status == 201)
    let metadata = await api.handle(request(.get, "/v1/media/\(hash)/metadata", headers: auth))
    #expect(try jsonObject(metadata)["referenceCount"] as? Int == 2)

    let itemOneID = try #require(try jsonObject(itemOne)["id"] as? String)
    var deleteHeaders = auth
    deleteHeaders["If-Match"] = try #require(itemOne.headers["ETag"])
    #expect(await api.handle(
        request(.delete, "/v1/items/\(itemOneID)", headers: deleteHeaders)
    ).status == 204)
    #expect(await api.handle(request(.get, "/v1/media/\(hash)", headers: auth)).body == bytes)
}

@Test func itemCreationRoundTripsEveryContentValueAndExactGeneratedCards() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "items.write", "media.write"]
    )
    let textField = FieldDef(name: "Text", type: .text, isRequired: true)
    let richField = FieldDef(name: "Rich", type: .richText, isRequired: true)
    let imageField = FieldDef(name: "Image", type: .image, isRequired: true)
    let clozeField = FieldDef(name: "Cloze", type: .cloze, isRequired: true)
    let numberField = FieldDef(name: "Number", type: .number, isRequired: true)
    let optionalField = FieldDef(name: "Optional", type: .text)
    let template = Template(
        name: "All values",
        prompt: Side(slots: [Slot(source: .field(textField.id))]),
        answer: Side(slots: [
            Slot(source: .field(richField.id)),
            Slot(source: .field(imageField.id)),
            Slot(source: .field(clozeField.id)),
            Slot(source: .field(numberField.id)),
        ]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recall)
    )
    let type = ItemType(
        name: "All API values",
        fields: [
            textField, richField, imageField, clozeField, numberField, optionalField,
        ],
        templates: [template]
    )
    _ = try await store.createItemType(type)

    let mediaBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x43])
    let upload = await api.handle(APIRequest(
        method: .post,
        path: "/v1/media",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": "all-values-media",
            "NeoAnki-Media-Kind": "image",
        ],
        body: mediaBytes
    ))
    let uploaded = try jsonObject(upload)
    let itemID = UUID().uuidString.lowercased()
    let body: [String: Any] = [
        "id": itemID,
        "itemTypeId": type.id.uuidString.lowercased(),
        "deckId": NSNull(),
        "fields": [
            [
                "fieldId": textField.id.uuidString.lowercased(),
                "value": ["type": "text", "text": "Plain", "lang": "en"],
            ],
            [
                "fieldId": richField.id.uuidString.lowercased(),
                "value": [
                    "type": "rich",
                    "spans": [["text": "Styled", "styles": ["bold", "italic"]]],
                ],
            ],
            [
                "fieldId": imageField.id.uuidString.lowercased(),
                "value": [
                    "type": "media",
                    "mediaId": UUID().uuidString.lowercased(),
                    "kind": "image",
                    "sha256": try #require(uploaded["assetHash"] as? String),
                    "fileExtension": "png",
                    "altText": "Diagram",
                    "reservationId": try #require(uploaded["reservationId"] as? String),
                ],
            ],
            [
                "fieldId": clozeField.id.uuidString.lowercased(),
                "value": [
                    "type": "cloze",
                    "text": "One two",
                    "blanks": [["group": 1, "start": 4, "length": 3, "hint": "number"]],
                ],
            ],
            [
                "fieldId": numberField.id.uuidString.lowercased(),
                "value": ["type": "number", "number": 42.5],
            ],
            [
                "fieldId": optionalField.id.uuidString.lowercased(),
                "value": ["type": "empty"],
            ],
        ],
        "tags": [" structured ", "structured"],
    ]
    let created = await api.handle(APIRequest(
        method: .post,
        path: "/v1/items",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": "all-content-values",
        ],
        body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    ))
    #expect(created.status == 201)
    let representation = try APIJSON.decoder.decode(APIItem.self, from: created.body)
    #expect(representation.id == itemID)
    #expect(representation.tags == ["structured"])
    #expect(representation.fields.map(\.value.type) == [
        "text", "rich", "media", "cloze", "number", "empty",
    ])
    let persisted = try await store.itemRecord(id: UUID(uuidString: itemID)!)
    #expect(persisted.item.fields.map(\.value) == representation.fields.map {
        try! $0.value.domain(pointer: "/value")
    })
    #expect(representation.cardIds.count == CardGenerator.cards(
        for: persisted.item,
        type: type
    ).count)
    #expect(try await store.mediaAsset(
        hash: try #require(uploaded["assetHash"] as? String)
    )?.refCount == 1)
}

@Test func mediaUploadRecoversTheSameReservationAfterProcessExit() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service(faultInjector: any APIFaultInjector = NoAPIFaultInjector()) -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test",
            faultInjector: faultInjector
        )
    }

    let faultedService = service(
        faultInjector: ConfiguredAPIFaultInjector(point: .mediaAfterReservation)
    )
    let token = try await pair(
        faultedService,
        scopes: ["library.read", "media.write"]
    )
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x42])
    let key = "media-process-exit"
    func upload(using api: NeoAnkiAPIService) async -> APIResponse {
        await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
                "NeoAnki-Media-Kind": "image",
            ],
            body: bytes
        ))
    }

    let interrupted = await upload(using: faultedService)
    #expect(interrupted.status == 500)

    let grant = try #require(try await authorization.authenticate(token: token))
    var hashInput = Data("POST\n/v1/media\nimage\n\n".utf8)
    hashInput.append(bytes)
    let requestHash = APICrypto.sha256Hex(hashInput)
    let pendingClaim = try #require(try await store.idempotencyClaim(
        clientID: grant.id,
        route: "POST /v1/media",
        key: key,
        requestHash: requestHash
    ))
    let reservationID: String
    switch pendingClaim {
    case let .pending(resultResourceID):
        reservationID = try #require(resultResourceID)
    default:
        Issue.record("The interrupted upload must leave a recoverable pending claim.")
        return
    }
    let assetHash = APICrypto.sha256Hex(bytes)
    #expect(try await store.mediaAsset(hash: assetHash)?.refCount == 0)

    let restartedService = service()
    let recovered = await upload(using: restartedService)
    #expect(recovered.status == 201)
    #expect(try jsonObject(recovered)["reservationId"] as? String == reservationID)
    #expect(try jsonObject(recovered)["assetHash"] as? String == assetHash)

    let replay = await upload(using: restartedService)
    #expect(replay.status == 201)
    #expect(replay.body == recovered.body)
    #expect(try await store.mediaAsset(hash: assetHash)?.refCount == 0)
    let downloaded = await restartedService.handle(request(
        .get,
        "/v1/media/\(assetHash)",
        headers: ["Authorization": "Bearer \(token)"]
    ))
    #expect(downloaded.status == 200)
    #expect(downloaded.body == bytes)
}

@Test func bulkItemsMeetAtomicLimitDryRunAndReplayContracts() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let authorization = "Bearer \(token)"

    func operation(index: Int, valid: Bool = true) -> [String: Any] {
        let itemID = UUID().uuidString.lowercased()
        var fields: [[String: Any]] = [
            [
                "fieldId": BuiltInItemTypes.frontFieldID.uuidString.lowercased(),
                "value": ["type": "text", "text": "Front \(index)"],
            ],
            [
                "fieldId": BuiltInItemTypes.backFieldID.uuidString.lowercased(),
                "value": ["type": "text", "text": "Back \(index)"],
            ],
        ]
        if !valid { fields.append(fields[0]) }
        return [
            "operationId": "operation-\(index)",
            "action": "create",
            "item": [
                "id": itemID,
                "itemTypeId": BuiltInItemTypes.basicID.uuidString.lowercased(),
                "deckId": NSNull(),
                "fields": fields,
                "tags": ["bulk"],
            ],
        ]
    }

    func send(
        operations: [[String: Any]],
        dryRun: Bool,
        key: String? = nil
    ) async throws -> APIResponse {
        let body = try JSONSerialization.data(
            withJSONObject: ["atomic": true, "dryRun": dryRun, "operations": operations],
            options: [.sortedKeys]
        )
        var headers = [
            "Host": "127.0.0.1:8766",
            "Authorization": authorization,
        ]
        if let key { headers["Idempotency-Key"] = key }
        return await api.handle(APIRequest(
            method: .post,
            path: "/v1/items/bulk",
            headers: headers,
            body: body
        ))
    }

    let stableOperations = [operation(index: 1), operation(index: 2)]
    let beforeDryRun = try await store.currentChangeCursor()
    let dryRun = try await send(operations: stableOperations, dryRun: true)
    #expect(dryRun.status == 200)
    #expect(try await store.currentChangeCursor() == beforeDryRun)
    let dryResults = try #require(try jsonObject(dryRun)["results"] as? [[String: Any]])

    let committed = try await send(
        operations: stableOperations,
        dryRun: false,
        key: "stable-bulk"
    )
    let replay = try await send(
        operations: stableOperations,
        dryRun: false,
        key: "stable-bulk"
    )
    #expect(committed.status == 200)
    #expect(replay.body == committed.body)
    let committedResults = try #require(
        try jsonObject(committed)["results"] as? [[String: Any]]
    )
    #expect(dryResults.map { $0["itemId"] as? String } == committedResults.map { $0["itemId"] as? String })
    #expect(dryResults.map { $0["cardIds"] as? [String] } == committedResults.map { $0["cardIds"] as? [String] })

    let countBeforeInvalid = try await store.itemRecords().count
    let invalid = try await send(
        operations: [operation(index: 3), operation(index: 4, valid: false)],
        dryRun: false,
        key: "invalid-bulk"
    )
    #expect(invalid.status == 422)
    #expect(try await store.itemRecords().count == countBeforeInvalid)
    let invalidProblem = try jsonObject(invalid)
    #expect((invalidProblem["detail"] as? String)?.contains("operation-4") == true)
    let invalidErrors = try #require(invalidProblem["errors"] as? [[String: Any]])
    #expect(invalidErrors.first?["pointer"] as? String == "/operations/1")

    let oversized = try await send(
        operations: (0 ... 500).map { operation(index: 1_000 + $0) },
        dryRun: false,
        key: "oversized-bulk"
    )
    #expect([413, 422].contains(oversized.status))
    #expect(try await store.itemRecords().count == countBeforeInvalid)

    let fiveHundred = (0 ..< 500).map { operation(index: 10_000 + $0) }
    let cursorBeforeCommit = try await store.currentChangeCursor()
    let maximum = try await send(
        operations: fiveHundred,
        dryRun: false,
        key: "maximum-bulk"
    )
    #expect(maximum.status == 200)
    #expect(try await store.itemRecords().count == countBeforeInvalid + 500)
    let changes = try await store.libraryChanges(after: cursorBeforeCommit, limit: 1_000)
    #expect(changes.count == 1_000)
    #expect(Set(changes.map(\.transactionID)).count == 1)
}

@Test func deckDeletionAndResetPlansBindExactImpactAndRevisions() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "decks.write", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let parent = try await store.createDeck(Deck(name: "Outside parent"))
    let root = try await store.createDeck(Deck(name: "Planned root", parentID: parent.id))
    let child = try await store.createDeck(Deck(name: "Planned child", parentID: root.id))

    func basicItem(deckID: UUID, front: String) -> Item {
        Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text(front)
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Back")
                ),
            ],
            deckID: deckID
        )
    }
    let rootItem = basicItem(deckID: root.id, front: "Root")
    let childItem = basicItem(deckID: child.id, front: "Child")
    _ = try await store.createItem(rootItem)
    _ = try await store.createItem(childItem)
    let reviewedCardID = try #require(try await store.itemRecord(id: childItem.id).cardIDs.first)
    _ = try await store.submitReview(cardID: reviewedCardID, rating: .good)

    func deletionPlan(_ policy: String) async throws -> APIResponse {
        await api.handle(request(
            .post,
            "/v1/deck-deletion-plans",
            headers: auth,
            body: #"{"deckId":"\#(root.id.uuidString.lowercased())","policy":"\#(policy)"}"#
        ))
    }
    var plans: [String: [String: Any]] = [:]
    var planETags: [String: String] = [:]
    for policy in [
        "rejectIfNonempty", "unassignItems", "moveItemsToParent", "deleteSubtreeAndItems",
    ] {
        let response = try await deletionPlan(policy)
        #expect(response.status == 201)
        let object = try jsonObject(response)
        let impact = try #require(object["impact"] as? [String: Any])
        #expect(impact["deckCount"] as? Int == 2)
        #expect(impact["itemCount"] as? Int == 2)
        #expect(impact["cardCount"] as? Int == 2)
        #expect(impact["reviewLogCount"] as? Int == 1)
        #expect(impact["mediaReferenceCount"] as? Int == 0)
        plans[policy] = object
        planETags[policy] = try #require(response.headers["ETag"])
    }

    let rejectID = try #require(plans["rejectIfNonempty"]?["id"] as? String)
    let rejected = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(rejectID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "reject-nonempty",
            "If-Match": try #require(planETags["rejectIfNonempty"]),
        ]) { _, new in new },
        body: #"{"confirm":false}"#
    ))
    #expect(rejected.status == 409)
    #expect(try jsonObject(rejected)["code"] as? String == "resource_in_use")
    _ = try await store.deck(id: root.id)

    let destructiveID = try #require(plans["deleteSubtreeAndItems"]?["id"] as? String)
    let unconfirmed = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(destructiveID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "missing-confirmation",
            "If-Match": try #require(planETags["deleteSubtreeAndItems"]),
        ]) { _, new in new },
        body: #"{"confirm":false}"#
    ))
    #expect(unconfirmed.status == 422)
    _ = try await store.deck(id: child.id)

    var changedItem = try await store.itemRecord(id: rootItem.id).item
    changedItem.tags = ["invalidates-plan"]
    _ = try await store.updateItem(changedItem)
    let invalidated = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(destructiveID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "invalidated-plan",
            "If-Match": try #require(planETags["deleteSubtreeAndItems"]),
        ]) { _, new in new },
        body: #"{"confirm":true}"#
    ))
    #expect(invalidated.status == 412)
    _ = try await store.deck(id: root.id)

    let fresh = try await deletionPlan("deleteSubtreeAndItems")
    let freshID = try #require(try jsonObject(fresh)["id"] as? String)
    let committed = await api.handle(request(
        .post,
        "/v1/deck-deletion-plans/\(freshID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "confirmed-deletion",
            "If-Match": try #require(fresh.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"confirm":true}"#
    ))
    #expect(committed.status == 200)
    await #expect(throws: DatabaseError.self) { try await store.deck(id: root.id) }
    await #expect(throws: DatabaseError.self) { try await store.itemRecord(id: childItem.id) }

    let resetRoot = try await store.createDeck(Deck(name: "Reset root"))
    let resetChild = try await store.createDeck(Deck(name: "Reset child", parentID: resetRoot.id))
    let resetItem = basicItem(deckID: resetChild.id, front: "Reset me")
    _ = try await store.createItem(resetItem)
    let resetCardID = try #require(try await store.itemRecord(id: resetItem.id).cardIDs.first)
    _ = try await store.submitReview(cardID: resetCardID, rating: .easy)
    _ = try await store.setCardSuspended(id: resetCardID, isSuspended: true)
    let resetPlan = await api.handle(request(
        .post,
        "/v1/deck-reset-plans",
        headers: auth,
        body: #"{"deckId":"\#(resetRoot.id.uuidString.lowercased())"}"#
    ))
    #expect(resetPlan.status == 201)
    let resetObject = try jsonObject(resetPlan)
    let resetImpact = try #require(resetObject["impact"] as? [String: Any])
    #expect(resetImpact["deckCount"] as? Int == 2)
    #expect(resetImpact["cardCount"] as? Int == 1)
    #expect(resetImpact["reviewLogCount"] as? Int == 1)
    let resetPlanID = try #require(resetObject["id"] as? String)
    let resetCommit = await api.handle(request(
        .post,
        "/v1/deck-reset-plans/\(resetPlanID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "reset-subtree",
            "If-Match": try #require(resetPlan.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"confirm":true}"#
    ))
    #expect(resetCommit.status == 200)
    let resetCard = try await store.card(id: resetCardID)
    #expect(resetCard.memory.phase == .new)
    #expect(resetCard.isSuspended)
    #expect(try await store.rawReviewLogCount(for: resetCardID) == 0)
    #expect(try await store.itemRecord(id: resetItem.id).item == resetItem)
}

@Test func transferJobsValidateCommitReplayAndPortableRoundTrip() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "library.import", "library.export"]
    )
    let auth = ["Authorization": "Bearer \(token)"]

    func createImport(
        api: NeoAnkiAPIService,
        token: String,
        format: String,
        path: String,
        bytes: Data,
        extra: [String: Any] = [:]
    ) async throws -> (id: String, fileID: String, job: APIResponse) {
        var body: [String: Any] = [
            "format": format,
            "files": [[
                "relativePath": path,
                "byteSize": bytes.count,
                "sha256": APICrypto.sha256Hex(bytes),
            ]],
        ]
        for (key, value) in extra { body[key] = value }
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let created = await api.handle(APIRequest(
            method: .post,
            path: "/v1/imports",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
            ],
            body: encoded
        ))
        #expect(created.status == 201)
        let object = try jsonObject(created)
        let id = try #require(object["id"] as? String)
        let files = try #require(object["files"] as? [[String: Any]])
        let fileID = try #require(files.first?["id"] as? String)
        return (id, fileID, created)
    }

    func upload(
        api: NeoAnkiAPIService,
        token: String,
        importID: String,
        fileID: String,
        bytes: Data
    ) async -> APIResponse {
        let status = await api.handle(request(
            .get,
            "/v1/imports/\(importID)",
            headers: ["Authorization": "Bearer \(token)"]
        ))
        guard let currentETag = status.headers["ETag"] else { return status }
        return await api.handle(APIRequest(
            method: .put,
            path: "/v1/imports/\(importID)/files/\(fileID)",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "If-Match": currentETag,
            ],
            body: bytes
        ))
    }

    let json = Data(#"{"itemType":"Basic","rows":[{"Front":"Imported","Back":"Answer","tags":["api"]}]}"#.utf8)
    let source = try await createImport(
        api: api, token: token, format: "json", path: "items.json", bytes: json
    )
    #expect(await upload(
        api: api, token: token, importID: source.id, fileID: source.fileID,
        bytes: Data("wrong".utf8)
    ).status == 422)
    #expect(await upload(
        api: api, token: token, importID: source.id, fileID: source.fileID, bytes: json
    ).status == 204)
    let validated = await api.handle(request(
        .post, "/v1/imports/\(source.id)/validations", headers: auth
    ))
    #expect(validated.status == 200)
    let planToken = try #require(try jsonObject(validated)["planToken"] as? String)
    _ = try await store.createDeck(Deck(name: "Invalidate import"))
    let stale = await api.handle(request(
        .post,
        "/v1/imports/\(source.id)/commits",
        headers: auth.merging([
            "Idempotency-Key": "stale-import",
            "If-Match": try #require(validated.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"planToken":"\#(planToken)"}"#
    ))
    #expect(stale.status == 412)

    let revalidated = await api.handle(request(
        .post, "/v1/imports/\(source.id)/validations", headers: auth
    ))
    let currentToken = try #require(try jsonObject(revalidated)["planToken"] as? String)
    let commitHeaders = auth.merging([
        "Idempotency-Key": "json-import",
        "If-Match": try #require(revalidated.headers["ETag"]),
    ]) { _, new in new }
    let commit = await api.handle(request(
        .post,
        "/v1/imports/\(source.id)/commits",
        headers: commitHeaders,
        body: #"{"planToken":"\#(currentToken)"}"#
    ))
    let replay = await api.handle(request(
        .post,
        "/v1/imports/\(source.id)/commits",
        headers: commitHeaders,
        body: #"{"planToken":"\#(currentToken)"}"#
    ))
    #expect(commit.status == 200)
    #expect(replay.body == commit.body)
    #expect(try await store.itemRecords().contains { record in
        record.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Imported")
    })

    let authoredManifest = Data(([
        #"{"kind":"neoanki","version":2,"root":"root","parts":["items/items.jsonl"]}"#,
        #"{"kind":"type","id":"Study","name":"API Authored","fields":[{"id":"front","name":"Front","type":"text","required":true},{"id":"back","name":"Back","type":"text","required":true}],"templates":[{"name":"Forward","prompt":[{"field":"front"}],"answer":[{"field":"back"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}"#,
        #"{"kind":"deck","id":"root","name":"Authored through API"}"#,
    ].joined(separator: "\n") + "\n").utf8)
    let authoredItems = Data((
        #"{"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question"},"back":{"text":"Answer"}}}"#
            + "\n"
    ).utf8)
    let authoredFiles: [[String: Any]] = [
        [
            "relativePath": "deck.jsonl",
            "byteSize": authoredManifest.count,
            "sha256": APICrypto.sha256Hex(authoredManifest),
        ],
        [
            "relativePath": "items/items.jsonl",
            "byteSize": authoredItems.count,
            "sha256": APICrypto.sha256Hex(authoredItems),
        ],
    ]
    let authoredCreated = await api.handle(APIRequest(
        method: .post,
        path: "/v1/imports",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ],
        body: try JSONSerialization.data(
            withJSONObject: ["format": "authoredDeck", "files": authoredFiles],
            options: [.sortedKeys]
        )
    ))
    #expect(authoredCreated.status == 201)
    let authoredObject = try jsonObject(authoredCreated)
    let authoredID = try #require(authoredObject["id"] as? String)
    let authoredFileObjects = try #require(authoredObject["files"] as? [[String: Any]])
    for file in authoredFileObjects {
        let path = try #require(file["relativePath"] as? String)
        let bytes = path == "deck.jsonl" ? authoredManifest : authoredItems
        #expect(await upload(
            api: api,
            token: token,
            importID: authoredID,
            fileID: try #require(file["id"] as? String),
            bytes: bytes
        ).status == 204)
    }
    let authoredValidation = await api.handle(request(
        .post, "/v1/imports/\(authoredID)/validations", headers: auth
    ))
    #expect(authoredValidation.status == 200)
    let authoredValidationObject = try jsonObject(authoredValidation)
    let authoredPlan = try #require(authoredValidationObject["planToken"] as? String)
    let authoredReport = try #require(authoredValidationObject["report"] as? [String: Any])
    #expect(authoredReport["itemCount"] as? Int == 1)
    #expect(authoredReport["deckCount"] as? Int == 1)
    #expect(authoredReport["createdItemTypeCount"] as? Int == 1)
    #expect(authoredReport["warnings"] as? [String] == [])
    let authoredCommit = await api.handle(request(
        .post,
        "/v1/imports/\(authoredID)/commits",
        headers: auth.merging([
            "Idempotency-Key": "authored-import",
            "If-Match": try #require(authoredValidation.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"planToken":"\#(authoredPlan)"}"#
    ))
    #expect(authoredCommit.status == 200)
    let committedAuthoredReport = try #require(
        try jsonObject(authoredCommit)["report"] as? [String: Any]
    )
    #expect(committedAuthoredReport["itemCount"] as? Int == authoredReport["itemCount"] as? Int)
    #expect(committedAuthoredReport["deckCount"] as? Int == authoredReport["deckCount"] as? Int)
    #expect(
        committedAuthoredReport["createdItemTypeCount"] as? Int
            == authoredReport["createdItemTypeCount"] as? Int
    )

    let exportDeck = try await store.createDeck(Deck(name: "Portable API"))
    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Portable")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Round trip")),
        ],
        deckID: exportDeck.id
    ))
    let export = await api.handle(request(
        .post,
        "/v1/exports",
        headers: auth,
        body: #"{"format":"portableDeck","deckId":"\#(exportDeck.id.uuidString.lowercased())"}"#
    ))
    #expect(export.status == 201)
    let exportID = try #require(try jsonObject(export)["id"] as? String)
    let content = await api.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    ))
    #expect(content.status == 200)
    #expect(content.body.starts(with: Data("SQLite format 3\0".utf8)))

    let (destinationAPI, destinationStore) = try await makeAPIAndStore()
    let destinationToken = try await pair(
        destinationAPI, scopes: ["library.import", "library.read"]
    )
    let portable = try await createImport(
        api: destinationAPI,
        token: destinationToken,
        format: "portableDeck",
        path: "source.neodeck",
        bytes: content.body
    )
    #expect(await upload(
        api: destinationAPI,
        token: destinationToken,
        importID: portable.id,
        fileID: portable.fileID,
        bytes: content.body
    ).status == 204)
    let portableAuth = ["Authorization": "Bearer \(destinationToken)"]
    let portableValidation = await destinationAPI.handle(request(
        .post, "/v1/imports/\(portable.id)/validations", headers: portableAuth
    ))
    #expect(portableValidation.status == 200)
    let portableReport = try #require(
        try jsonObject(portableValidation)["report"] as? [String: Any]
    )
    #expect(portableReport["itemCount"] as? Int == 1)
    #expect(portableReport["deckCount"] as? Int == 1)
    #expect(portableReport["createdItemTypeCount"] as? Int == 0)
    #expect(portableReport["reusedItemTypeCount"] as? Int == 1)
    #expect(portableReport["warnings"] as? [String] == [])
    let portableToken = try #require(
        try jsonObject(portableValidation)["planToken"] as? String
    )
    let portableCommit = await destinationAPI.handle(request(
        .post,
        "/v1/imports/\(portable.id)/commits",
        headers: portableAuth.merging([
            "Idempotency-Key": "portable-import",
            "If-Match": try #require(portableValidation.headers["ETag"]),
        ]) { _, new in new },
        body: #"{"planToken":"\#(portableToken)"}"#
    ))
    #expect(portableCommit.status == 200)
    #expect(try await destinationStore.itemRecords().contains { record in
        record.item.fields.contains { $0.value == .text("Portable") }
    })

    #expect(await api.handle(request(
        .delete,
        "/v1/exports/\(exportID)",
        headers: auth.merging(["If-Match": try #require(export.headers["ETag"])]) { _, new in new }
    )).status == 204)
    #expect(await api.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    )).status == 404)
}

@Test func transferJobsAndPrivateStagingSurviveAPIServiceRestart() async throws {
    let databaseURL = apiTestDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service() -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
    }

    let firstService = service()
    let token = try await pair(
        firstService,
        scopes: ["library.import", "library.export"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let importBytes = Data(#"{"itemType":"Basic","rows":[]}"#.utf8)
    let importManifest: [String: Any] = [
        "format": "json",
        "files": [[
            "relativePath": "items.json",
            "byteSize": importBytes.count,
            "sha256": APICrypto.sha256Hex(importBytes),
        ]],
    ]
    let createdImport = await firstService.handle(APIRequest(
        method: .post,
        path: "/v1/imports",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ],
        body: try JSONSerialization.data(withJSONObject: importManifest, options: [.sortedKeys])
    ))
    #expect(createdImport.status == 201)
    let importObject = try jsonObject(createdImport)
    let importID = try #require(importObject["id"] as? String)
    let importFiles = try #require(importObject["files"] as? [[String: Any]])
    let fileID = try #require(importFiles.first?["id"] as? String)
    let upload = await firstService.handle(APIRequest(
        method: .put,
        path: "/v1/imports/\(importID)/files/\(fileID)",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "If-Match": try #require(createdImport.headers["ETag"]),
        ],
        body: importBytes
    ))
    #expect(upload.status == 204)

    let deck = try await store.createDeck(Deck(name: "Restart export"))
    let createdExport = await firstService.handle(request(
        .post,
        "/v1/exports",
        headers: auth,
        body: #"{"format":"portableDeck","deckId":"\#(deck.id.uuidString.lowercased())"}"#
    ))
    #expect(createdExport.status == 201)
    let exportID = try #require(try jsonObject(createdExport)["id"] as? String)
    let expectedExportBytes = await firstService.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    )).body

    let stateURL = await store.localAPITransferStateURL()
    let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let restartedService = service()
    let restoredImport = await restartedService.handle(request(
        .get, "/v1/imports/\(importID)", headers: auth
    ))
    #expect(restoredImport.status == 200)
    let restoredFiles = try #require(try jsonObject(restoredImport)["files"] as? [[String: Any]])
    #expect(restoredFiles.first?["uploaded"] as? Bool == true)

    let restoredExport = await restartedService.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    ))
    #expect(restoredExport.status == 200)
    #expect(restoredExport.body == expectedExportBytes)

    #expect(await restartedService.handle(request(
        .delete,
        "/v1/imports/\(importID)",
        headers: auth.merging(["If-Match": try #require(restoredImport.headers["ETag"])]) {
            _, new in new
        }
    )).status == 204)
    let restoredExportStatus = await restartedService.handle(request(
        .get, "/v1/exports/\(exportID)", headers: auth
    ))
    #expect(await restartedService.handle(request(
        .delete,
        "/v1/exports/\(exportID)",
        headers: auth.merging([
            "If-Match": try #require(restoredExportStatus.headers["ETag"]),
        ]) { _, new in new }
    )).status == 204)

    let afterDeletionRestart = service()
    let missing = await afterDeletionRestart.handle(request(
        .get, "/v1/imports/\(importID)", headers: auth
    ))
    #expect(missing.status == 404)
    #expect(try jsonObject(missing)["code"] as? String == "resource_not_found")
}

@Test func optionalIdempotencyReplaysOrdinaryMutationsAndRejectsDifferentInput() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "items.write"])
    let auth = ["Authorization": "Bearer \(token)"]
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ],
        tags: ["source"]
    )
    _ = try await store.createItem(item)

    let tags = await api.handle(request(.get, "/v1/tags", headers: auth))
    let cursor = try await store.currentChangeCursor()
    let headers = auth.merging([
        "If-Match": try #require(tags.headers["ETag"]),
        "Idempotency-Key": "rename-once",
    ]) { _, new in new }
    let first = await api.handle(request(
        .post,
        "/v1/tag-renames",
        headers: headers,
        body: #"{"from":"source","to":"destination"}"#
    ))
    let replay = await api.handle(request(
        .post,
        "/v1/tag-renames",
        headers: headers,
        body: #"{"from":"source","to":"destination"}"#
    ))
    #expect(first.status == 200)
    #expect(replay.status == first.status)
    #expect(replay.body == first.body)
    #expect(try await store.itemRecord(id: item.id).item.tags == ["destination"])
    let changes = try await store.libraryChanges(after: cursor, limit: 20)
    #expect(changes.count == 1)

    let conflict = await api.handle(request(
        .post,
        "/v1/tag-renames",
        headers: headers,
        body: #"{"from":"source","to":"different"}"#
    ))
    #expect(conflict.status == 409)
    #expect(try jsonObject(conflict)["code"] as? String == "idempotency_conflict")
}

@Test func expiredTransferJobsRemoveStagedInputAndOutput() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    let service = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test"
    )
    let token = try await pair(
        service,
        scopes: ["library.import", "library.export"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let stagedBytes = Data("private-expiring-import-payload".utf8)
    let manifest: [String: Any] = [
        "format": "json",
        "files": [[
            "relativePath": "items.json",
            "byteSize": stagedBytes.count,
            "sha256": APICrypto.sha256Hex(stagedBytes),
        ]],
    ]
    let createdImport = await service.handle(APIRequest(
        method: .post,
        path: "/v1/imports",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ],
        body: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    ))
    let importObject = try jsonObject(createdImport)
    let importID = try #require(importObject["id"] as? String)
    let fileID = try #require(
        (importObject["files"] as? [[String: Any]])?.first?["id"] as? String
    )
    #expect(await service.handle(APIRequest(
        method: .put,
        path: "/v1/imports/\(importID)/files/\(fileID)",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "If-Match": try #require(createdImport.headers["ETag"]),
        ],
        body: stagedBytes
    )).status == 204)

    let deck = try await store.createDeck(Deck(name: "Expiring export"))
    let createdExport = await service.handle(request(
        .post,
        "/v1/exports",
        headers: auth,
        body: #"{"format":"portableDeck","deckId":"\#(deck.id.uuidString.lowercased())"}"#
    ))
    let exportID = try #require(try jsonObject(createdExport)["id"] as? String)

    let expiringService = NeoAnkiAPIService(
        store: store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test",
        transferJobLifetime: -1
    )
    let missingImport = await expiringService.handle(request(
        .get, "/v1/imports/\(importID)", headers: auth
    ))
    let missingExport = await expiringService.handle(request(
        .get, "/v1/exports/\(exportID)/content", headers: auth
    ))
    #expect(missingImport.status == 404)
    #expect(missingExport.status == 404)

    let persisted = try Data(contentsOf: await store.localAPITransferStateURL())
    #expect(persisted.range(of: stagedBytes) == nil)
}

@Test func everyCollectionTraversesDeterministicallyAndRejectsMismatchedCursors() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read"])
    let headers = [
        "Host": "127.0.0.1:8766",
        "Authorization": "Bearer \(token)",
    ]
    let decks = try await ["Zulu", "Alpha", "Middle"].asyncMap {
        try await store.createDeck(Deck(name: $0))
    }
    for index in 0 ..< 3 {
        _ = try await store.createItem(Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text("Front \(index)")
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Back \(index)")
                ),
            ],
            tags: index < 2 ? ["shared", "tag-\(index)"] : ["tag-\(index)"],
            deckID: decks[index].id
        ))
    }

    func page(
        _ path: String,
        cursor: String? = nil,
        extra: [String: [String]] = [:],
        service: NeoAnkiAPIService? = nil,
        requestHeaders: [String: String]? = nil
    ) async -> APIResponse {
        var query = extra
        query["limit"] = ["1"]
        if let cursor { query["cursor"] = [cursor] }
        return await (service ?? api).handle(APIRequest(
            method: .get,
            path: path,
            query: query,
            headers: requestHeaders ?? headers
        ))
    }

    func traverse(_ path: String, identity: String) async throws -> [String] {
        var cursor: String?
        var values: [String] = []
        repeat {
            let response = await page(path, cursor: cursor)
            #expect(response.status == 200)
            let object = try jsonObject(response)
            let data = try #require(object["data"] as? [[String: Any]])
            #expect(data.count <= 1)
            values += try data.map { try #require($0[identity] as? String) }
            let pageObject = try #require(object["page"] as? [String: Any])
            cursor = pageObject["nextCursor"] as? String
        } while cursor != nil
        #expect(Set(values).count == values.count)
        return values
    }

    for (path, identity) in [
        ("/v1/decks", "id"), ("/v1/item-types", "id"),
        ("/v1/items", "id"), ("/v1/tags", "name"), ("/v1/cards", "id"),
    ] {
        let first = try await traverse(path, identity: identity)
        let second = try await traverse(path, identity: identity)
        #expect(first == second)
    }

    let filteredFirst = await page(
        "/v1/items", extra: ["tag": ["shared"]]
    )
    let filteredCursor = try #require(
        (try jsonObject(filteredFirst)["page"] as? [String: Any])?["nextCursor"] as? String
    )
    let mismatched = await page(
        "/v1/items", cursor: filteredCursor, extra: ["tag": ["tag-2"]]
    )
    #expect(mismatched.status == 400)
    #expect(try jsonObject(mismatched)["code"] as? String == "invalid_cursor")

    let replacement = filteredCursor.last == "a" ? "b" : "a"
    let tamperedCursor = String(filteredCursor.dropLast()) + replacement
    let tampered = await page(
        "/v1/items", cursor: tamperedCursor, extra: ["tag": ["shared"]]
    )
    #expect(tampered.status == 400)

    let (otherAPI, _) = try await makeAPIAndStore()
    let otherToken = try await pair(otherAPI, scopes: ["library.read"])
    let foreign = await page(
        "/v1/items",
        cursor: filteredCursor,
        extra: ["tag": ["shared"]],
        service: otherAPI,
        requestHeaders: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(otherToken)",
        ]
    )
    #expect(foreign.status == 400)

    let excessive = await api.handle(APIRequest(
        method: .get,
        path: "/v1/items",
        query: ["limit": ["201"]],
        headers: headers
    ))
    #expect(excessive.status == 422)
}

@Test func everyItemFilterMatchesTheNativeContractFixture() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read"])
    let root = try await store.createDeck(Deck(name: "Filter root"))
    let child = try await store.createDeck(Deck(name: "Filter child", parentID: root.id))
    let otherType = try await store.createItemType(ItemType(
        name: "Filter alternate",
        fields: BuiltInItemTypes.basic.fields,
        templates: BuiltInItemTypes.basic.templates
    ))
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func basic(
        typeID: UUID = BuiltInItemTypes.basicID,
        deckID: UUID?,
        front: String,
        tags: [String]
    ) -> Item {
        Item(
            itemTypeID: typeID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text(front)
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Answer \(front)")
                ),
            ],
            tags: tags,
            deckID: deckID
        )
    }
    let rootItem = try await store.createItem(
        basic(deckID: root.id, front: "Café root", tags: ["alpha", "beta"]),
        now: base
    )
    var childDomain = basic(
        deckID: child.id,
        front: "Nested child",
        tags: ["alpha", "gamma"]
    )
    let childItem = try await store.createItem(
        childDomain,
        now: base.addingTimeInterval(10)
    )
    let alternateItem = try await store.createItem(
        basic(
            typeID: otherType.id,
            deckID: nil,
            front: "Alternate",
            tags: ["beta"]
        ),
        now: base.addingTimeInterval(20)
    )
    childDomain.tags.append("updated")
    _ = try await store.updateItem(childDomain, now: base.addingTimeInterval(30))

    func timestamp(_ date: Date) throws -> String {
        let encoded = try APIJSON.encoder.encode(date)
        return try #require(String(data: encoded, encoding: .utf8))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    func filtered(_ query: [String: [String]]) async throws -> Set<String> {
        let response = await api.handle(APIRequest(
            method: .get,
            path: "/v1/items",
            query: query,
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
            ]
        ))
        #expect(response.status == 200)
        let rows = try #require(try jsonObject(response)["data"] as? [[String: Any]])
        return Set(rows.compactMap { $0["id"] as? String })
    }
    let rootID = rootItem.id.uuidString.lowercased()
    let childID = childItem.id.uuidString.lowercased()
    let alternateID = alternateItem.id.uuidString.lowercased()

    #expect(try await filtered([
        "deckId": [root.id.uuidString.lowercased()],
    ]) == [rootID])
    #expect(try await filtered([
        "deckId": [root.id.uuidString.lowercased()],
        "includeDescendants": ["true"],
    ]) == [rootID, childID])
    #expect(try await filtered([
        "itemTypeId": [otherType.id.uuidString.lowercased()],
    ]) == [alternateID])
    #expect(try await filtered(["tag": ["alpha", "beta"]]) == [rootID])
    #expect(try await filtered(["text": ["cafe"]]) == [rootID])
    #expect(try await filtered(["schedulePhase": ["new"]]) == [
        rootID, childID, alternateID,
    ])
    #expect(try await filtered([
        "dueBefore": [timestamp(base.addingTimeInterval(15))],
    ]) == [rootID, childID])
    #expect(try await filtered([
        "createdAfter": [timestamp(base.addingTimeInterval(5))],
    ]) == [childID, alternateID])
    #expect(try await filtered([
        "updatedAfter": [timestamp(base.addingTimeInterval(25))],
    ]) == [childID])
}

@Test func everySupportedMediaSignatureRoundTripsAndHostileUploadsDoNotPersist() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "media.write"])
    let auth = ["Authorization": "Bearer \(token)"]

    func ascii(_ value: String) -> [UInt8] { Array(value.utf8) }
    func iso(_ brand: String, compatible: String? = nil) -> Data {
        var bytes: [UInt8] = [0, 0, 0, compatible == nil ? 16 : 20]
        bytes += ascii("ftyp") + ascii(brand) + [0, 0, 0, 0]
        if let compatible { bytes += ascii(compatible) }
        return Data(bytes)
    }
    let fixtures: [(kind: String, ext: String, bytes: Data)] = [
        ("audio", "mp3", Data(ascii("ID3fixture"))),
        ("audio", "wav", Data(ascii("RIFF0000WAVEfixture"))),
        ("audio", "aac", Data([0xFF, 0xF0, 0x50, 0x80])),
        ("audio", "caf", Data(ascii("cafffixture"))),
        ("audio", "m4a", iso("M4A ")),
        ("image", "png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])),
        ("image", "jpg", Data([0xFF, 0xD8, 0xFF, 0xE0])),
        ("image", "heic", iso("heic")),
        ("image", "webp", Data(ascii("RIFF0000WEBPfixture"))),
        ("image", "tiff", Data([0x49, 0x49, 0x2A, 0x00, 1])),
        ("gif", "gif", Data(ascii("GIF89afixture"))),
        ("video", "mov", iso("qt  ")),
        ("video", "m4v", iso("M4V ")),
        ("video", "mp4", iso("isom")),
    ]
    for (index, fixture) in fixtures.enumerated() {
        let uploaded = await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": "format-\(index)",
                "NeoAnki-Media-Kind": fixture.kind,
            ],
            body: fixture.bytes
        ))
        #expect(uploaded.status == 201)
        let object = try jsonObject(uploaded)
        let hash = try #require(object["assetHash"] as? String)
        #expect(hash == APICrypto.sha256Hex(fixture.bytes))
        #expect(object["fileExtension"] as? String == fixture.ext)
        let downloaded = await api.handle(request(
            .get, "/v1/media/\(hash)", headers: auth
        ))
        #expect(downloaded.status == 200)
        #expect(downloaded.body == fixture.bytes)
        #expect(await api.handle(request(
            .head, "/v1/media/\(hash)", headers: auth
        )).status == 200)
    }

    func rejected(_ key: String, kind: String, bytes: Data) async -> APIResponse {
        await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
                "NeoAnki-Media-Kind": kind,
            ],
            body: bytes
        ))
    }
    let beforeHostile = try await store.currentChangeCursor()
    #expect(await rejected("wrong-magic", kind: "image", bytes: Data("not-media".utf8)).status == 422)
    #expect(await rejected("kind-mismatch", kind: "audio", bytes: fixtures[5].bytes).status == 422)
    #expect(await rejected("ambiguous", kind: "audio", bytes: iso("M4A ", compatible: "isom")).status == 422)
    #expect(try await store.currentChangeCursor() == beforeHostile)

    for (index, kind) in [MediaKind.audio, .image, .gif, .video].enumerated() {
        var bytes = Data(repeating: 0, count: MediaValidation.maxBytes(for: kind) + 1)
        bytes.replaceSubrange(0 ..< min(fixtures[index == 0 ? 0 : index + 4].bytes.count, bytes.count),
                              with: fixtures[index == 0 ? 0 : index + 4].bytes.prefix(bytes.count))
        let response = await rejected("oversize-\(kind.rawValue)", kind: kind.rawValue, bytes: bytes)
        #expect(response.status == 413)
    }
}

@Test func studyScopesAndOneHundredConcurrentSessionsNeverDoubleReserve() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["study.review"])
    let auth = ["Authorization": "Bearer \(token)"]
    let root = try await store.createDeck(Deck(name: "Scope root"))
    let child = try await store.createDeck(Deck(name: "Scope child", parentID: root.id))

    func item(_ index: Int, deckID: UUID?) -> Item {
        Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text("Concurrent \(index)")
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("Answer \(index)")
                ),
            ],
            deckID: deckID
        )
    }
    _ = try await store.createItem(item(0, deckID: nil))
    _ = try await store.createItem(item(1, deckID: root.id))
    _ = try await store.createItem(item(2, deckID: child.id))

    func reserve(scope: String) async throws -> [String: Any] {
        let session = await api.handle(request(
            .post, "/v1/study-sessions", headers: auth,
            body: "{\"scope\":\(scope)}"
        ))
        #expect(session.status == 201)
        let id = try #require(try jsonObject(session)["id"] as? String)
        let next = await api.handle(request(
            .post, "/v1/study-sessions/\(id)/next", headers: auth
        ))
        #expect(next.status == 200)
        return try jsonObject(next)
    }
    #expect(try await reserve(scope: #"{"kind":"unassigned"}"#)["deckId"] == nil)
    #expect(try await reserve(
        scope: #"{"kind":"deck","deckId":"\#(root.id.uuidString.lowercased())","includeDescendants":false}"#
    )["deckId"] as? String == root.id.uuidString.lowercased())
    #expect(try await reserve(
        scope: #"{"kind":"deck","deckId":"\#(root.id.uuidString.lowercased())","includeDescendants":true}"#
    )["deckId"] as? String == child.id.uuidString.lowercased())

    for index in 3 ..< 103 {
        _ = try await store.createItem(item(index, deckID: nil))
    }
    var sessionIDs: [String] = []
    for _ in 0 ..< 100 {
        let response = await api.handle(request(
            .post,
            "/v1/study-sessions",
            headers: auth,
            body: #"{"scope":{"kind":"allDecks"}}"#
        ))
        sessionIDs.append(try #require(try jsonObject(response)["id"] as? String))
    }
    let reservedIDs = await withTaskGroup(of: String?.self) { group in
        for sessionID in sessionIDs {
            group.addTask {
                let response = await api.handle(request(
                    .post, "/v1/study-sessions/\(sessionID)/next", headers: auth
                ))
                return (try? jsonObject(response)["id"] as? String) ?? nil
            }
        }
        var values: [String] = []
        for await value in group {
            if let value { values.append(value) }
        }
        return values
    }
    #expect(reservedIDs.count == 100)
    #expect(Set(reservedIDs).count == 100)
}

@Test func reviewRetryAfterCommitBeforeResponseRecoversExactlyOnceAcrossServiceRestart() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service() -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
    }
    let firstService = service()
    let token = try await pair(firstService, scopes: ["study.review"])
    let grant = try #require(try await authorization.authenticate(token: token))
    _ = try await store.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Crash")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Recover")),
        ]
    ))
    let auth = ["Authorization": "Bearer \(token)"]
    let session = await firstService.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(session)["id"] as? String)
    let next = await firstService.handle(request(
        .post, "/v1/study-sessions/\(sessionID)/next", headers: auth
    ))
    let cardID = try #require(try jsonObject(next)["id"] as? String)
    let body = Data(
        #"{"sessionId":"\#(sessionID)","cardId":"\#(cardID)","rating":"easy","durationMs":17}"#.utf8
    )
    let key = "crash-boundary-review"
    let logID = UUID()
    let hash = try APIJSON.canonicalRequestHash(
        method: .post,
        path: "/v1/reviews",
        body: body
    )
    _ = try await store.claimIdempotency(
        clientID: grant.id,
        route: "POST /v1/reviews",
        key: key,
        requestHash: hash,
        resultResourceID: logID.uuidString.lowercased()
    )
    _ = try await store.submitReservedReview(
        sessionID: UUID(uuidString: sessionID)!,
        cardID: UUID(uuidString: cardID)!,
        rating: .easy,
        reviewLogID: logID,
        durationMs: 17
    )
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)

    let restartedService = service()
    let recovered = await restartedService.handle(APIRequest(
        method: .post,
        path: "/v1/reviews",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": key,
        ],
        body: body
    ))
    #expect(recovered.status == 201)
    #expect(try jsonObject(recovered)["reviewLogId"] as? String == logID.uuidString.lowercased())
    #expect(recovered.headers["ETag"] == "\"revision-1\"")
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)

    let replay = await restartedService.handle(APIRequest(
        method: .post,
        path: "/v1/reviews",
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
            "Idempotency-Key": key,
        ],
        body: body
    ))
    #expect(replay.body == recovered.body)
    #expect(try await store.rawReviewLogCount(for: UUID(uuidString: cardID)!) == 1)
}

@Test func importCommitRecoversAcrossAllProcessExitBoundaries() async throws {
    for (index, point) in [
        APIFaultPoint.importBeforeDomainCommit,
        .importAfterDomainCommit,
        .importAfterCompletedJobPersisted,
    ].enumerated() {
        let store = try ItemStore(databaseURL: apiTestDatabaseURL())
        try await store.bootstrap()
        let authorization = APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        )
        let faultedService = NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test",
            faultInjector: ConfiguredAPIFaultInjector(point: point)
        )
        let token = try await pair(faultedService, scopes: ["library.import"])
        let auth = ["Authorization": "Bearer \(token)"]
        let bytes = Data(
            #"{"itemType":"Basic","rows":[{"Front":"Boundary","Back":"\#(index)"}]}"#.utf8
        )
        let manifest: [String: Any] = [
            "format": "json",
            "files": [[
                "relativePath": "items.json",
                "byteSize": bytes.count,
                "sha256": APICrypto.sha256Hex(bytes),
            ]],
        ]
        let created = await faultedService.handle(APIRequest(
            method: .post,
            path: "/v1/imports",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
            ],
            body: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        ))
        let createdObject = try jsonObject(created)
        let importID = try #require(createdObject["id"] as? String)
        let fileID = try #require(
            (createdObject["files"] as? [[String: Any]])?.first?["id"] as? String
        )
        let uploaded = await faultedService.handle(APIRequest(
            method: .put,
            path: "/v1/imports/\(importID)/files/\(fileID)",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "If-Match": try #require(created.headers["ETag"]),
            ],
            body: bytes
        ))
        #expect(uploaded.status == 204)
        let statusAfterUpload = await faultedService.handle(request(
            .get, "/v1/imports/\(importID)", headers: auth
        ))
        let validated = await faultedService.handle(request(
            .post, "/v1/imports/\(importID)/validations", headers: auth
        ))
        #expect(validated.status == 200)
        #expect(statusAfterUpload.headers["ETag"] != validated.headers["ETag"])
        let planToken = try #require(try jsonObject(validated)["planToken"] as? String)
        let key = "import-boundary-\(index)"
        let commitHeaders = auth.merging([
            "Idempotency-Key": key,
            "If-Match": try #require(validated.headers["ETag"]),
        ]) { _, new in new }
        let commitBody = #"{"planToken":"\#(planToken)"}"#
        let interrupted = await faultedService.handle(request(
            .post,
            "/v1/imports/\(importID)/commits",
            headers: commitHeaders,
            body: commitBody
        ))
        #expect(interrupted.status == 500)
        let countBeforeRecovery = try await store.itemRecords().filter { record in
            record.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Boundary")
        }.count
        #expect(countBeforeRecovery == (index == 0 ? 0 : 1))

        let restartedService = NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test"
        )
        let recovered = await restartedService.handle(request(
            .post,
            "/v1/imports/\(importID)/commits",
            headers: commitHeaders,
            body: commitBody
        ))
        #expect(recovered.status == 200)
        #expect(try jsonObject(recovered)["state"] as? String == "completed")
        #expect(try await store.itemRecords().filter { record in
            record.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Boundary")
        }.count == 1)
        let replay = await restartedService.handle(request(
            .post,
            "/v1/imports/\(importID)/commits",
            headers: commitHeaders,
            body: commitBody
        ))
        #expect(replay.body == recovered.body)
    }
}

@Test func exportCreationRecoversAcrossAllProcessExitBoundaries() async throws {
    for (index, point) in [
        APIFaultPoint.exportAfterPendingJobPersisted,
        .exportAfterOutputGenerated,
        .exportAfterCompletedJobPersisted,
    ].enumerated() {
        let store = try ItemStore(databaseURL: apiTestDatabaseURL())
        try await store.bootstrap()
        let deck = try await store.createDeck(Deck(name: "Export boundary \(index)"))
        _ = try await store.createItem(Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .text("Boundary")
                ),
                FieldValue(
                    fieldID: BuiltInItemTypes.backFieldID,
                    value: .text("\(index)")
                ),
            ],
            deckID: deck.id
        ))
        let authorization = APIAuthorizationStore(
            persistence: InMemoryAPICredentialPersistence()
        )
        func service(
            faultInjector: any APIFaultInjector = NoAPIFaultInjector()
        ) -> NeoAnkiAPIService {
            NeoAnkiAPIService(
                store: store,
                authorization: authorization,
                pairingApprover: ApproveAllPairings(),
                applicationVersion: "test",
                faultInjector: faultInjector
            )
        }
        let faultedService = service(
            faultInjector: ConfiguredAPIFaultInjector(point: point)
        )
        let token = try await pair(faultedService, scopes: ["library.export"])
        let key = "export-boundary-\(index)"
        let body = Data(
            #"{"format":"portableDeck","deckId":"\#(deck.id.uuidString.lowercased())"}"#.utf8
        )
        func create(using api: NeoAnkiAPIService) async -> APIResponse {
            await api.handle(APIRequest(
                method: .post,
                path: "/v1/exports",
                headers: [
                    "Host": "127.0.0.1:8766",
                    "Authorization": "Bearer \(token)",
                    "Idempotency-Key": key,
                ],
                body: body
            ))
        }

        #expect(await create(using: faultedService).status == 500)
        let grant = try #require(try await authorization.authenticate(token: token))
        let requestHash = try APIJSON.canonicalRequestHash(
            method: .post,
            path: "/v1/exports",
            body: body
        )
        let pending = try #require(try await store.idempotencyClaim(
            clientID: grant.id,
            route: "POST /v1/exports",
            key: key,
            requestHash: requestHash
        ))
        let exportID: String
        switch pending {
        case let .pending(resultResourceID):
            exportID = try #require(resultResourceID)
        default:
            Issue.record("The interrupted export must retain its pending claim.")
            continue
        }

        let restartedService = service()
        let recovered = await create(using: restartedService)
        #expect(recovered.status == 201)
        #expect(try jsonObject(recovered)["id"] as? String == exportID)
        #expect(try jsonObject(recovered)["state"] as? String == "completed")
        #expect(await create(using: restartedService).body == recovered.body)

        let content = await restartedService.handle(request(
            .get,
            "/v1/exports/\(exportID)/content",
            headers: ["Authorization": "Bearer \(token)"]
        ))
        #expect(content.status == 200)
        #expect(!content.body.isEmpty)
        let secondRestart = service()
        #expect(await secondRestart.handle(request(
            .get,
            "/v1/exports/\(exportID)/content",
            headers: ["Authorization": "Bearer \(token)"]
        )).body == content.body)
    }
}

@Test func referenceScaleAPILatencyMeetsVersionOneReleaseBudgets() async throws {
    guard ProcessInfo.processInfo.environment["NEOANKI_RUN_API_PERFORMANCE_TEST"] != nil else {
        return
    }
    let fixture = try await PerformanceFixtures.makeStore(label: "local-api-v1-release")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await PerformanceFixtures.seedBasicItems(count: 100_000, in: fixture.store)
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    let api = NeoAnkiAPIService(
        store: fixture.store,
        authorization: authorization,
        pairingApprover: ApproveAllPairings(),
        applicationVersion: "test"
    )
    let token = try await pair(
        api,
        scopes: ["library.read", "study.review"]
    )
    let auth = ["Authorization": "Bearer \(token)"]

    func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    func measure(_ operation: () async -> APIResponse) async -> (APIResponse, Double) {
        let start = Date.now
        let response = await operation()
        return (response, Date.now.timeIntervalSince(start) * 1_000)
    }
    func assertBudget(
        _ values: [Double],
        milliseconds: Double,
        operation: String
    ) {
        let measured = percentile95(values)
        #expect(
            measured <= milliseconds,
            "\(operation) p95 was \(measured) ms; budget is \(milliseconds) ms."
        )
    }

    _ = await api.handle(request(.get, "/health"))
    _ = await api.handle(request(.get, "/v1/meta"))
    let pageRequest = APIRequest(
        method: .get,
        path: "/v1/items",
        query: ["limit": ["200"]],
        headers: [
            "Host": "127.0.0.1:8766",
            "Authorization": "Bearer \(token)",
        ]
    )
    _ = await api.handle(pageRequest)

    var healthTimes: [Double] = []
    var metadataTimes: [Double] = []
    var collectionTimes: [Double] = []
    for _ in 0 ..< 100 {
        let (health, healthTime) = await measure {
            await api.handle(request(.get, "/health"))
        }
        let (metadata, metadataTime) = await measure {
            await api.handle(request(.get, "/v1/meta"))
        }
        let (page, pageTime) = await measure { await api.handle(pageRequest) }
        #expect(health.status == 200)
        #expect(metadata.status == 200)
        #expect(page.status == 200)
        healthTimes.append(healthTime)
        metadataTimes.append(metadataTime)
        collectionTimes.append(pageTime)
    }

    let session = await api.handle(request(
        .post,
        "/v1/study-sessions",
        headers: auth,
        body: #"{"scope":{"kind":"allDecks"}}"#
    ))
    let sessionID = try #require(try jsonObject(session)["id"] as? String)
    var reviewTimes: [Double] = []
    for index in 0 ..< 100 {
        let next = await api.handle(request(
            .post,
            "/v1/study-sessions/\(sessionID)/next",
            headers: auth
        ))
        let cardID = try #require(try jsonObject(next)["id"] as? String)
        let reviewBody = #"{"sessionId":"\#(sessionID)","cardId":"\#(cardID)","rating":"good","durationMs":0}"#
        let (review, reviewTime) = await measure {
            await api.handle(request(
                .post,
                "/v1/reviews",
                headers: auth.merging([
                    "Idempotency-Key": "performance-review-\(index)",
                ]) { _, new in new },
                body: reviewBody
            ))
        }
        #expect(review.status == 201)
        reviewTimes.append(reviewTime)
    }

    assertBudget(healthTimes, milliseconds: 100, operation: "GET /health")
    assertBudget(metadataTimes, milliseconds: 100, operation: "GET /v1/meta")
    assertBudget(collectionTimes, milliseconds: 500, operation: "GET /v1/items?limit=200")
    assertBudget(reviewTimes, milliseconds: 500, operation: "POST /v1/reviews")
}

private extension Array where Element == String {
    func asyncMap<T>(_ transform: (String) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for value in self { values.append(try await transform(value)) }
        return values
    }
}
