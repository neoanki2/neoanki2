import Foundation
import Network
@testable import NeoAnkiAPI
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing

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
    // Let the kernel allocate a port atomically; guessing can collide with parallel test runs.
    let port: NWEndpoint.Port = .any
    let authority = "127.0.0.1:8766"
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
    do {
        #expect(await server.isRunning)
        let actualPort = try #require(await server.listeningPort)
        // Observe this socket's readiness and EOF directly. URLSession.shared's
        // process-wide scheduling/deadline is unrelated to the server contract.
        let bytes = try await loopbackHTTPResponse(
            port: actualPort,
            request: Data("GET /health HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\n\r\n".utf8)
        )
        let separator = try #require(bytes.range(of: Data("\r\n\r\n".utf8)))
        let head = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        #expect(lines.first == "HTTP/1.1 200 OK")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let colon = try #require(line.firstIndex(of: ":"))
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            #expect(headers[name] == nil, "Duplicate response header: \(name)")
            headers[name] = value
        }
        let length = try #require(headers["content-length"].flatMap(Int.init))
        let data = Data(bytes[separator.upperBound...])
        #expect(length == data.count, "EOF must follow exactly the declared response body.")
        #expect(headers["connection"]?.lowercased() == "close")
        #expect(headers["transfer-encoding"] == nil)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["status": "ok"])
    } catch {
        await server.stop()
        throw error
    }

    await server.stop()
    #expect(await !server.isRunning)
}

private func loopbackHTTPResponse(port: NWEndpoint.Port, request: Data) async throws -> Data {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    defer { connection.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "neoanki-api-http-test"))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        return try await loopbackReadToEOF(connection)
    } onCancel: {
        connection.cancel()
    }
}

private func loopbackReadToEOF(_ connection: NWConnection) async throws -> Data {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
        var bytes = Data()
        while true {
            let (data, complete) = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data ?? Data(), complete)) }
                }
            }
            bytes.append(data)
            if complete { return bytes }
        }
    } onCancel: {
        connection.cancel()
    }
}

@Test func openEventStreamClosesAfterClientRevocation() async throws {
    // Let the kernel allocate a port atomically; guessing can collide with parallel test runs.
    let port: NWEndpoint.Port = .any
    let authority = "127.0.0.1:8766"
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

    let actualPort = try #require(await server.listeningPort)
    let connection = NWConnection(host: "127.0.0.1", port: actualPort, using: .tcp)
    defer { connection.cancel() }
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
    do {
        _ = try await loopbackReadToEOF(connection)
    } catch let error as NWError {
        // Either orderly EOF or a peer reset proves that revocation closed the
        // stream. Other network errors remain failures.
        guard case .posix(.ECONNRESET) = error else {
            await server.stop()
            throw error
        }
    } catch {
        await server.stop()
        throw error
    }
    #expect(await server.activeConnectionCount == 0)
    connection.cancel()
    await server.stop()
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
