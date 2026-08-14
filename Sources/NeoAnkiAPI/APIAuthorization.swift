import CryptoKit
import Darwin
import Foundation

public enum APIScope: String, Codable, CaseIterable, Hashable, Sendable {
    case libraryRead = "library.read"
    case itemsWrite = "items.write"
    case decksWrite = "decks.write"
    case schemasWrite = "schemas.write"
    case studyReview = "study.review"
    case studyResponsesRead = "study.responses.read"
    case studyResponsesDelete = "study.responses.delete"
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

/// Persists only one-way bearer-token verifiers and their grant metadata.
/// The bearer tokens themselves are returned once at pairing and never reach
/// this file.
public actor VerifierFileAPICredentialPersistence: APICredentialPersistence {
    public static let fileName = "client-grants-v1.json"

    private static let maximumByteCount = 1_048_576
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public func load() throws -> Data? {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw APIAuthorizationError.insecureCredentialStorage }
            throw APIAuthorizationError.credentialPersistence
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            try? handle.close()
            throw APIAuthorizationError.credentialPersistence
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_mode & 0o077 == 0
        else {
            try? handle.close()
            throw APIAuthorizationError.insecureCredentialStorage
        }
        guard fileStatus.st_size <= Self.maximumByteCount else {
            try? handle.close()
            throw APIAuthorizationError.credentialDataTooLarge
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        guard data.count <= Self.maximumByteCount else {
            throw APIAuthorizationError.credentialDataTooLarge
        }
        return data
    }

    public func save(_ data: Data) throws {
        guard data.count <= Self.maximumByteCount else {
            throw APIAuthorizationError.credentialDataTooLarge
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try preparePrivateDirectory(directoryURL)

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(Self.fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw APIAuthorizationError.credentialPersistence
        }

        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var preparedURL = temporaryURL
            try preparedURL.setResourceValues(resourceValues)
            guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
                throw APIAuthorizationError.credentialPersistence
            }
        } catch {
            _ = Darwin.unlink(temporaryURL.path)
            throw error
        }
    }

    private func preparePrivateDirectory(_ directoryURL: URL) throws {
        let fileManager = FileManager.default
        var directoryStatus = stat()
        if Darwin.lstat(directoryURL.path, &directoryStatus) == 0 {
            guard directoryStatus.st_mode & S_IFMT == S_IFDIR,
                  directoryStatus.st_uid == geteuid()
            else {
                throw APIAuthorizationError.insecureCredentialStorage
            }
        } else {
            guard errno == ENOENT else {
                throw APIAuthorizationError.credentialPersistence
            }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }
}

enum APIAuthorizationError: Error, Sendable {
    case credentialPersistence
    case credentialDataTooLarge
    case insecureCredentialStorage
    case invalidCredentialData
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
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
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
