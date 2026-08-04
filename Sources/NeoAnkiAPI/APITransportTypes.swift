import Foundation

public enum APIHTTPMethod: String, Sendable, Codable {
    case delete = "DELETE"
    case get = "GET"
    case head = "HEAD"
    case options = "OPTIONS"
    case patch = "PATCH"
    case post = "POST"
    case put = "PUT"
}

public struct APIRequest: Sendable {
    public let method: APIHTTPMethod
    public let path: String
    public let query: [String: [String]]
    public let headers: [String: String]
    public let body: Data
    public let isLoopback: Bool

    public init(
        method: APIHTTPMethod,
        path: String,
        query: [String: [String]] = [:],
        headers: [String: String] = [:],
        body: Data = Data(),
        isLoopback: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        self.body = body
        self.isLoopback = isLoopback
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct APIResponse: Sendable, Equatable {
    public let status: Int
    public var headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable & Sendable>(
        status: Int = 200,
        _ value: T,
        headers: [String: String] = [:]
    ) throws -> APIResponse {
        var resultHeaders = headers
        resultHeaders["Content-Type"] = "application/json; charset=utf-8"
        return APIResponse(
            status: status,
            headers: resultHeaders,
            body: try APIJSON.encoder.encode(value)
        )
    }
}

enum APIJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.formatted(
                    .iso8601
                        .year().month().day()
                        .dateSeparator(.dash)
                        .time(includingFractionalSeconds: true)
                        .timeSeparator(.colon)
                        .timeZone(separator: .omitted)
                )
            )
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(value, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected RFC 3339 UTC timestamp.")
                )
            }
            return date
        }
        return decoder
    }

    static func decodeStrict<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        allowedKeys: Set<String>
    ) throws -> T {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw APIServiceError.validation("The request body must be a JSON object.")
        }
        let unknown = Set(object.keys).subtracting(allowedKeys)
        guard unknown.isEmpty else {
            let key = unknown.sorted().first ?? "unknown"
            throw APIServiceError.validation(
                "Unknown request member.",
                pointer: "/\(key)",
                fieldCode: "unknown_member"
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch let error as APIServiceError {
            throw error
        } catch {
            throw APIServiceError.validation("The request body is invalid.")
        }
    }

    static func canonicalRequestHash(method: APIHTTPMethod, path: String, body: Data) throws -> String {
        let canonicalBody: Data
        if body.isEmpty {
            canonicalBody = Data("null".utf8)
        } else {
            let value = try JSONSerialization.jsonObject(with: body)
            canonicalBody = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        var input = Data("\(method.rawValue)\n\(path)\n".utf8)
        input.append(canonicalBody)
        return APICrypto.sha256Hex(input)
    }
}

struct EmptyResponse: Encodable, Sendable {}

public struct APIPageInfo: Codable, Sendable, Equatable {
    public let nextCursor: String?
    public let limit: Int
}

public struct APICollection<Element: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let data: [Element]
    public let page: APIPageInfo
}
