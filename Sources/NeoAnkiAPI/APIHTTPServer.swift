import Foundation
import Network

public actor NeoAnkiLocalAPIServer {
    public struct Configuration: Sendable, Equatable {
        public var host: NWEndpoint.Host
        public var port: NWEndpoint.Port
        public var maximumRequestBytes: Int

        public init(
            host: NWEndpoint.Host = "127.0.0.1",
            port: NWEndpoint.Port = 8766,
            maximumRequestBytes: Int = 513_000_000
        ) {
            self.host = host
            self.port = port
            self.maximumRequestBytes = maximumRequestBytes
        }
    }

    private let service: NeoAnkiAPIService
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "org.neoanki.local-api.listener")
    private let connections = HTTPConnectionRegistry()
    private var listener: NWListener?

    public init(service: NeoAnkiAPIService, configuration: Configuration = .init()) {
        self.service = service
        self.configuration = configuration
    }

    public func start() async throws {
        guard listener == nil else { return }
        guard configuration.host == "127.0.0.1" else {
            throw APIHTTPServerError.nonLoopbackConfiguration
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: configuration.host,
            port: configuration.port
        )
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener

        do {
            try await withCheckedThrowingContinuation { continuation in
                let startup = ListenerStartup(continuation)
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        startup.succeed()
                        listener?.stateUpdateHandler = nil
                    case let .failed(error):
                        startup.fail(error)
                        listener?.stateUpdateHandler = nil
                    case .cancelled:
                        startup.fail(APIHTTPServerError.cancelledDuringStartup)
                        listener?.stateUpdateHandler = nil
                    default:
                        break
                    }
                }
                let connectionRegistry = connections
                listener.newConnectionHandler = {
                    [service, maximumRequestBytes = configuration.maximumRequestBytes, connectionRegistry]
                    connection in
                    HTTPConnectionHandler(
                        connection: connection,
                        service: service,
                        maximumRequestBytes: maximumRequestBytes,
                        registry: connectionRegistry
                    ).start()
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.cancelAll()
    }

    public var isRunning: Bool { listener != nil }
    var activeConnectionCount: Int { connections.count }
}

private enum APIHTTPServerError: Error {
    case cancelledDuringStartup
    case nonLoopbackConfiguration
}

private final class ListenerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() {
        finish(.success(()))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class HTTPConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let service: NeoAnkiAPIService
    private let maximumRequestBytes: Int
    private let registry: HTTPConnectionRegistry
    private let queue = DispatchQueue(label: "org.neoanki.local-api.connection")
    private var buffer = Data()
    private var expectedBytes: Int?
    private var streamRequest: APIRequest?
    private var streamLastWrite = Date.distantPast

    init(
        connection: NWConnection,
        service: NeoAnkiAPIService,
        maximumRequestBytes: Int,
        registry: HTTPConnectionRegistry
    ) {
        self.connection = connection
        self.service = service
        self.maximumRequestBytes = maximumRequestBytes
        self.registry = registry
    }

    func start() {
        registry.insert(connection)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.connection.stateUpdateHandler = nil
                self.registry.remove(self.connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > self.maximumRequestBytes {
                self.sendTransportProblem(status: 413, code: "payload_too_large", detail: "Request is too large.")
                return
            }
            do {
                if self.expectedBytes == nil,
                   let length = try HTTP1RequestParser.expectedTotalBytes(in: self.buffer) {
                    guard length <= self.maximumRequestBytes else {
                        self.sendTransportProblem(status: 413, code: "payload_too_large", detail: "Request is too large.")
                        return
                    }
                    self.expectedBytes = length
                }
                if let expectedBytes = self.expectedBytes, self.buffer.count >= expectedBytes {
                    guard self.buffer.count == expectedBytes else {
                        throw HTTP1ParseError.unexpectedTrailingBytes
                    }
                    let request = try HTTP1RequestParser.parse(
                        self.buffer,
                        remoteEndpoint: self.connection.endpoint
                    )
                    Task {
                        let response = await self.service.handle(request)
                        self.send(response, headRequest: request.method == .head)
                    }
                    return
                }
                if complete || error != nil {
                    throw HTTP1ParseError.incompleteRequest
                }
                self.receive()
            } catch let error as HTTP1ParseError {
                self.sendTransportProblem(status: error.status, code: error.code, detail: error.detail)
            } catch {
                self.sendTransportProblem(status: 400, code: "invalid_http_request", detail: "The HTTP request is invalid.")
            }
        }
    }

    private func send(_ response: APIResponse, headRequest: Bool) {
        if !headRequest,
           response.status == 200,
           response.headers["Content-Type"]?.hasPrefix("text/event-stream") == true,
           let request = try? HTTP1RequestParser.parse(buffer, remoteEndpoint: connection.endpoint)
        {
            beginEventStream(response, request: request)
            return
        }
        var headers = response.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(response.body.count)
        }
        headers["Connection"] = "close"
        let statusLine = "HTTP/1.1 \(response.status) \(HTTPStatus.reason(response.status))\r\n"
        let headerText = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
        var bytes = Data((statusLine + headerText + "\r\n").utf8)
        if !headRequest { bytes.append(response.body) }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func beginEventStream(_ response: APIResponse, request: APIRequest) {
        streamRequest = request
        var headers = response.headers
        headers.removeValue(forKey: "Content-Length")
        headers["Connection"] = "keep-alive"
        headers["Cache-Control"] = "no-store"
        let statusLine = "HTTP/1.1 200 \(HTTPStatus.reason(200))\r\n"
        let headerText = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
        var bytes = Data((statusLine + headerText + "\r\n").utf8)
        bytes.append(response.body)
        if let cursor = response.headers["X-NeoAnki-Change-Cursor"] {
            updateStreamCursor(cursor)
        }
        streamLastWrite = .now
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil { self.scheduleEventPoll() } else { self.finish() }
        })
    }

    private func updateStreamCursor(_ cursor: String) {
        guard let original = streamRequest else { return }
        var headers = original.headers
        headers["last-event-id"] = cursor
        var query = original.query
        query.removeValue(forKey: "after")
        streamRequest = APIRequest(
            method: .get,
            path: original.path,
            query: query,
            headers: headers,
            body: Data(),
            isLoopback: original.isLoopback
        )
    }

    private func scheduleEventPoll() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let request = self.streamRequest else { return }
            Task {
                let response = await self.service.handle(request)
                self.queue.async { self.processEventPoll(response) }
            }
        }
    }

    private func processEventPoll(_ response: APIResponse) {
        guard streamRequest != nil, response.status == 200 else {
            finish()
            return
        }
        if let cursor = response.headers["X-NeoAnki-Change-Cursor"] {
            updateStreamCursor(cursor)
        }
        let containsEvent = response.body.range(of: Data("data: ".utf8)) != nil
        let heartbeatDue = Date.now.timeIntervalSince(streamLastWrite) >= 30
        guard containsEvent || heartbeatDue else {
            scheduleEventPoll()
            return
        }
        let content = containsEvent ? response.body : Data(": keep-alive\n\n".utf8)
        streamLastWrite = .now
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil { self.scheduleEventPoll() } else { self.finish() }
        })
    }

    private func finish() {
        streamRequest = nil
        connection.stateUpdateHandler = nil
        registry.remove(connection)
        connection.cancel()
    }

    private func sendTransportProblem(status: Int, code: String, detail: String) {
        let requestID = UUID().uuidString.lowercased()
        let body = (try? JSONSerialization.data(
            withJSONObject: [
                "type": "https://neoanki.example/problems/\(code.replacingOccurrences(of: "_", with: "-"))",
                "title": HTTPStatus.reason(status),
                "status": status,
                "code": code,
                "detail": detail,
                "requestId": requestID,
            ],
            options: [.sortedKeys]
        )) ?? Data()
        send(
            APIResponse(
                status: status,
                headers: [
                    "Content-Type": "application/problem+json; charset=utf-8",
                    "X-Request-ID": requestID,
                    "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff",
                ],
                body: body
            ),
            headRequest: false
        )
    }
}

final class HTTPConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: NWConnection] = [:]

    func insert(_ connection: NWConnection) {
        lock.lock()
        values[ObjectIdentifier(connection)] = connection
        lock.unlock()
    }

    func remove(_ connection: NWConnection) {
        lock.lock()
        values.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let connections = Array(values.values)
        values.removeAll()
        lock.unlock()
        for connection in connections { connection.cancel() }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}

enum HTTP1ParseError: Error, Equatable {
    case malformedRequestLine
    case malformedHeader
    case duplicateCriticalHeader
    case headerTooLarge
    case invalidContentLength
    case unsupportedTransferEncoding
    case absoluteRequestTarget
    case unexpectedTrailingBytes
    case incompleteRequest

    var status: Int {
        switch self {
        case .headerTooLarge: 431
        case .unexpectedTrailingBytes: 400
        case .unsupportedTransferEncoding: 501
        default: 400
        }
    }

    var code: String {
        switch self {
        case .headerTooLarge: "headers_too_large"
        case .unsupportedTransferEncoding: "transfer_encoding_unsupported"
        default: "invalid_http_request"
        }
    }

    var detail: String {
        switch self {
        case .unsupportedTransferEncoding:
            "Transfer-Encoding is not supported. Send an exact Content-Length."
        case .headerTooLarge:
            "Request headers exceed 65536 bytes."
        default:
            "The HTTP request is malformed or ambiguous."
        }
    }
}

enum HTTP1RequestParser {
    private static let separator = Data("\r\n\r\n".utf8)
    private static let criticalHeaders: Set<String> = [
        "authorization", "content-length", "host", "origin", "transfer-encoding",
    ]

    static func expectedTotalBytes(in data: Data) throws -> Int? {
        guard let separatorRange = data.range(of: separator) else {
            if data.count > 65_536 { throw HTTP1ParseError.headerTooLarge }
            return nil
        }
        guard separatorRange.upperBound <= 65_536 else {
            throw HTTP1ParseError.headerTooLarge
        }
        let head = data[..<separatorRange.lowerBound]
        let (_, headers) = try parseHead(Data(head))
        if headers["transfer-encoding"] != nil {
            throw HTTP1ParseError.unsupportedTransferEncoding
        }
        let bodyLength: Int
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.allSatisfy(\.isNumber), let parsed = Int(value), parsed >= 0 else {
                throw HTTP1ParseError.invalidContentLength
            }
            bodyLength = parsed
        } else {
            bodyLength = 0
        }
        let (total, overflow) = separatorRange.upperBound.addingReportingOverflow(bodyLength)
        guard !overflow else { throw HTTP1ParseError.invalidContentLength }
        return total
    }

    static func parse(_ data: Data, remoteEndpoint: NWEndpoint?) throws -> APIRequest {
        guard let separatorRange = data.range(of: separator) else {
            throw HTTP1ParseError.incompleteRequest
        }
        let (requestLine, headers) = try parseHead(Data(data[..<separatorRange.lowerBound]))
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let method = APIHTTPMethod(rawValue: String(fields[0])),
              fields[2] == "HTTP/1.1"
        else {
            throw HTTP1ParseError.malformedRequestLine
        }
        let target = String(fields[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#") else {
            throw HTTP1ParseError.absoluteRequestTarget
        }
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            throw HTTP1ParseError.malformedRequestLine
        }
        var query: [String: [String]] = [:]
        for item in components.queryItems ?? [] {
            query[item.name, default: []].append(item.value ?? "")
        }
        let body = Data(data[separatorRange.upperBound...])
        return APIRequest(
            method: method,
            path: components.path,
            query: query,
            headers: headers,
            body: body,
            isLoopback: isLoopback(remoteEndpoint)
        )
    }

    private static func parseHead(_ data: Data) throws -> (String, [String: String]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTP1ParseError.malformedHeader
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw HTTP1ParseError.malformedRequestLine
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw HTTP1ParseError.malformedHeader
            }
            let rawName = String(line[..<colon])
            guard rawName.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
            }) else {
                throw HTTP1ParseError.malformedHeader
            }
            let name = rawName.lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if headers[name] != nil {
                if criticalHeaders.contains(name) {
                    throw HTTP1ParseError.duplicateCriticalHeader
                }
                headers[name, default: ""] += ", \(value)"
            } else {
                headers[name] = value
            }
        }
        guard headers["host"] != nil else { throw HTTP1ParseError.malformedHeader }
        return (requestLine, headers)
    }

    private static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "::1" || value == "localhost" || value.hasPrefix("127.")
    }
}

private enum HTTPStatus {
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 410: "Gone"
        case 412: "Precondition Failed"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Content"
        case 428: "Precondition Required"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        default: "Response"
        }
    }
}
