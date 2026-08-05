import CryptoKit
import Foundation
import Security

public enum APIScope: String, Codable, CaseIterable, Hashable, Sendable {
    case libraryRead = "library.read"
    case itemsWrite = "items.write"
    case decksWrite = "decks.write"
    case schemasWrite = "schemas.write"
    case studyReview = "study.review"
    case mediaWrite = "media.write"
    case libraryImport = "library.import"
    case libraryExport = "library.export"
    case vocabularyRead = "vocabulary.read"
    case vocabularyWrite = "vocabulary.write"
    case settingsWrite = "settings.write"
    case uiControl = "ui.control"
}

public struct APIClientGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let origin: String?
    public let scopes: Set<APIScope>
    public let createdAt: Date
    public let revision: Int
}

struct StoredAPIClientGrant: Codable, Sendable, Equatable {
    let grant: APIClientGrant
    let tokenHash: String
}

public protocol APICredentialPersistence: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

public actor InMemoryAPICredentialPersistence: APICredentialPersistence {
    private var data: Data?

    public init() {}

    public func load() -> Data? { data }
    public func save(_ data: Data) { self.data = data }
}

public actor KeychainAPICredentialPersistence: APICredentialPersistence {
    private let service: String
    private let account: String

    public init(
        service: String = "org.neoanki.neoanki2.local-api",
        account: String = "client-grants"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw APIAuthorizationError.credentialPersistence(status)
        }
        return data
    }

    public func save(_ data: Data) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insertion = identity
            insertion[kSecValueData as String] = data
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw APIAuthorizationError.credentialPersistence(status)
            }
            return
        }
        guard update == errSecSuccess else {
            throw APIAuthorizationError.credentialPersistence(update)
        }
    }
}

enum APIAuthorizationError: Error, Sendable {
    case credentialPersistence(OSStatus)
    case invalidCredentialData
    case randomGeneration
}

enum APICrypto {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256Hex(key: Data, data: Data) -> String {
        HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        ).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw APIAuthorizationError.randomGeneration
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public actor APIAuthorizationStore {
    private let persistence: any APICredentialPersistence
    private var grantsByHash: [String: StoredAPIClientGrant]?

    public init(persistence: any APICredentialPersistence) {
        self.persistence = persistence
    }

    public func issueGrant(
        displayName: String,
        origin: String?,
        scopes: Set<APIScope>,
        now: Date = .now
    ) async throws -> (grant: APIClientGrant, token: String) {
        var grants = try await loadGrants()
        let token = try APICrypto.randomToken()
        let hash = APICrypto.sha256Hex(Data(token.utf8))
        let grant = APIClientGrant(
            id: UUID(),
            displayName: displayName,
            origin: origin,
            scopes: scopes,
            createdAt: now,
            revision: 1
        )
        grants[hash] = StoredAPIClientGrant(grant: grant, tokenHash: hash)
        try await persist(grants)
        return (grant, token)
    }

    public func authenticate(token: String) async throws -> APIClientGrant? {
        let hash = APICrypto.sha256Hex(Data(token.utf8))
        return try await loadGrants()[hash]?.grant
    }

    @discardableResult
    public func revoke(clientID: UUID) async throws -> Bool {
        var grants = try await loadGrants()
        let keys = grants.compactMap { $0.value.grant.id == clientID ? $0.key : nil }
        guard !keys.isEmpty else { return false }
        for key in keys { grants.removeValue(forKey: key) }
        try await persist(grants)
        return true
    }

    public func listGrants() async throws -> [APIClientGrant] {
        try await loadGrants().values.map(\.grant).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func loadGrants() async throws -> [String: StoredAPIClientGrant] {
        if let grantsByHash { return grantsByHash }
        guard let data = try await persistence.load() else {
            grantsByHash = [:]
            return [:]
        }
        guard let decoded = try? APIJSON.decoder.decode([StoredAPIClientGrant].self, from: data) else {
            throw APIAuthorizationError.invalidCredentialData
        }
        let grants = Dictionary(uniqueKeysWithValues: decoded.map { ($0.tokenHash, $0) })
        grantsByHash = grants
        return grants
    }

    private func persist(_ grants: [String: StoredAPIClientGrant]) async throws {
        let ordered = grants.values.sorted { $0.grant.id.uuidString < $1.grant.id.uuidString }
        try await persistence.save(try APIJSON.encoder.encode(ordered))
        grantsByHash = grants
    }
}

public struct APIPairingRequest: Sendable, Equatable {
    public let displayName: String
    public let origin: String?
    public let requestedScopes: Set<APIScope>

    public init(displayName: String, origin: String?, requestedScopes: Set<APIScope>) {
        self.displayName = displayName
        self.origin = origin
        self.requestedScopes = requestedScopes
    }
}

public protocol APIPairingApprover: Sendable {
    func approve(_ request: APIPairingRequest) async -> Bool
    func cancel(_ request: APIPairingRequest) async
}

public extension APIPairingApprover {
    func cancel(_ request: APIPairingRequest) async {}
}

public struct DenyAPIPairingApprover: APIPairingApprover {
    public init() {}
    public func approve(_ request: APIPairingRequest) async -> Bool { false }
}
