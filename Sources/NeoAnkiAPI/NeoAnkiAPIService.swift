import Foundation
import NeoAnkiApplication
import NeoAnkiCore

public enum APIFaultPoint: Sendable {
    case importBeforeDomainCommit
    case importAfterDomainCommit
    case importAfterCompletedJobPersisted
    case mediaAfterReservation
    case exportAfterPendingJobPersisted
    case exportAfterOutputGenerated
    case exportAfterCompletedJobPersisted
}

public protocol APIFaultInjector: Sendable {
    func simulatesProcessExit(at point: APIFaultPoint) -> Bool
}

public struct NoAPIFaultInjector: APIFaultInjector {
    public init() {}
    public func simulatesProcessExit(at point: APIFaultPoint) -> Bool { false }
}

private struct SimulatedAPIProcessExit: Error {}

public actor NeoAnkiAPIService {
    public static let maximumJSONBodyBytes = 5_000_000
    public static let maximumStagedImportBytes = 4_000_000_000

    private let store: any LocalAPILibrary
    private let authorization: APIAuthorizationStore
    private let pairingApprover: any APIPairingApprover
    private let applicationVersion: String
    private let authority: String
    let vocabularyLibrary: APIVocabularyLibrary
    private let pairingRequestLifetime: TimeInterval
    private let transferJobLifetime: TimeInterval
    private let faultInjector: any APIFaultInjector
    private let serverInstanceID = UUID()
    private let cursorSecret = try! APICrypto.randomToken()
    private var pairingAttempts: [Date] = []
    private var pairingPromptActive = false
    private struct ImpactAuthorization {
        let resourceID: UUID
        let requestHash: String
        let changeCursor: Int64
        let expiresAt: Date
    }
    private var impactAuthorizations: [String: ImpactAuthorization] = [:]
    private struct DeckDeletionPlanRecord {
        let representation: APIDeckDeletionPlan
        let deckID: UUID
        let deckRevision: Int
    }
    private struct DeckResetPlanRecord {
        let representation: APIDeckResetPlan
        let deckID: UUID
        let deckRevision: Int
    }
    private var deckDeletionPlans: [UUID: DeckDeletionPlanRecord] = [:]
    private var deckResetPlans: [UUID: DeckResetPlanRecord] = [:]
    private struct ImportFileRecord: Codable {
        let id: UUID
        let relativePath: String
        let byteSize: Int
        let sha256: String
        var data: Data?
    }
    private struct ImportJobRecord: Codable {
        let id: UUID
        var revision: Int
        let format: APIImportFormat
        let itemTypeID: UUID?
        let csvItemTypeName: String?
        let destinationDeckID: UUID?
        var state: String
        var files: [ImportFileRecord]
        var report: APITransferReport?
        var planToken: String?
        var dependencyCursor: Int64?
        var committedChangeCursor: Int64?
        let createdAt: Date
        var updatedAt: Date
    }
    private struct ExportJobRecord: Codable {
        let id: UUID
        var revision: Int
        let deckID: UUID
        var state: String
        var bytes: Data?
        let createdAt: Date
        var updatedAt: Date
    }
    private var importJobs: [UUID: ImportJobRecord] = [:]
    private var exportJobs: [UUID: ExportJobRecord] = [:]
    private var transferStateLoaded = false
    private struct TransferState: Codable {
        let imports: [ImportJobRecord]
        let exports: [ExportJobRecord]
    }

    public init(
        library: any LocalAPILibrary,
        authorization: APIAuthorizationStore,
        pairingApprover: any APIPairingApprover = DenyAPIPairingApprover(),
        applicationVersion: String,
        authority: String = "127.0.0.1:8766",
        vocabularyRootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-api-vocabulary-\(UUID().uuidString)", isDirectory: true),
        pairingRequestLifetime: TimeInterval = 5 * 60,
        transferJobLifetime: TimeInterval = 24 * 60 * 60,
        faultInjector: any APIFaultInjector = NoAPIFaultInjector()
    ) {
        store = library
        self.authorization = authorization
        self.pairingApprover = pairingApprover
        self.applicationVersion = applicationVersion
        self.authority = authority.lowercased()
        vocabularyLibrary = APIVocabularyLibrary(
            rootURL: vocabularyRootURL,
            jobLifetime: transferJobLifetime
        )
        self.pairingRequestLifetime = pairingRequestLifetime
        self.transferJobLifetime = transferJobLifetime
        self.faultInjector = faultInjector
    }

    public func handle(_ request: APIRequest) async -> APIResponse {
        let serializedMutation = request.path != "/v1/pairings"
            && [.delete, .patch, .post, .put].contains(request.method)
        if serializedMutation {
            return await store.withAPIMutation { [self] in
                await handle(request, serializedMutation: true)
            }
        }
        return await handle(request, serializedMutation: false)
    }

    private func handle(
        _ request: APIRequest,
        serializedMutation: Bool
    ) async -> APIResponse {
        let requestID = UUID().uuidString.lowercased()
        let cursorBefore = serializedMutation ? try? await store.currentChangeCursor() : nil
        let finalResponse: APIResponse
        do {
            var response = try await route(request)
            if (200 ..< 300).contains(response.status),
               let cursorBefore,
               let cursorAfter = try? await store.currentChangeCursor(),
               cursorAfter > cursorBefore
            {
                response.headers["X-NeoAnki-Change-Cursor"] = String(cursorAfter)
            }
            finalResponse = await addCommonHeaders(
                response, request: request, requestID: requestID
            )
        } catch {
            let serviceError = APIServiceError.from(error)
            let response = problemResponse(
                serviceError,
                request: request,
                requestID: requestID
            )
            finalResponse = await addCommonHeaders(
                response, request: request, requestID: requestID
            )
        }
        return finalResponse
    }

    private func route(
        _ request: APIRequest,
        bypassGenericIdempotency: Bool = false
    ) async throws -> APIResponse {
        guard request.isLoopback else {
            throw APIServiceError.problem(
                status: 403,
                code: "loopback_required",
                title: "Loopback required",
                detail: "The local API accepts loopback connections only."
            )
        }
        guard request.header("host")?.lowercased() == authority else {
            throw APIServiceError.problem(
                status: 403,
                code: "invalid_host",
                title: "Invalid host",
                detail: "The Host header does not match the configured API authority."
            )
        }
        let pathComponents = request.path.split(separator: "/")
        let usesLargeByteBody = request.method == .post && request.path == "/v1/media"
            || request.method == .put
                && pathComponents.count == 5
                && pathComponents[0] == "v1"
                && ["imports", "vocabulary-pack-imports"].contains(String(pathComponents[1]))
                && pathComponents[3] == "files"
        guard usesLargeByteBody || request.body.count <= Self.maximumJSONBodyBytes else {
            throw APIServiceError.problem(
                status: 413,
                code: "payload_too_large",
                title: "Payload too large",
                detail: "JSON request bodies may not exceed 5000000 bytes."
            )
        }

        if request.method == .options {
            return try await preflight(request)
        }
        guard let endpoint = APIOpenAPI.endpoint(
            for: request.path,
            method: request.method
        ) else {
            throw APIServiceError.notFound(
                "No version-1 operation matches this method and path."
            )
        }
        if endpoint.requiredScope == nil {
            try rejectUndocumentedBody(request)
            try validateQuery(
                request.query,
                allowed: endpoint.queryParameters
            )
        }

        switch (request.method, request.path) {
        case (.get, "/health"):
            guard request.body.isEmpty else {
                throw APIServiceError.validation("GET /health does not accept a body.")
            }
            return try .json(APIHealth(status: "ok"))
        case (.get, "/v1/meta"):
            return try .json(
                APIMeta(
                    apiVersion: 1,
                    applicationVersion: applicationVersion,
                    serverInstanceId: serverInstanceID.uuidString.lowercased(),
                    pairingAvailable: true,
                    capabilities: [
                        "auth.pairing",
                        "changes.durable",
                        "decks.read",
                        "decks.write",
                        "idempotency.durable",
                        "study.reservations",
                        "study.reviews",
                        "study.responses",
                        "vocabulary.lookup",
                        "vocabulary.pack-lifecycle",
                    ]
                )
            )
        case (.get, "/v1/openapi.json"):
            return APIResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "ETag": "\"\(APIOpenAPI.contractDigest)\"",
                    "X-NeoAnki-Contract-Digest": APIOpenAPI.contractDigest,
                ],
                body: APIOpenAPI.document
            )
        case (.post, "/v1/pairings"):
            return try await pair(request)
        default:
            break
        }

        let grant = try await authenticate(request)
        try require(grant, endpoint: endpoint)
        try rejectUndocumentedBody(request)
        try validateQuery(request.query, allowed: endpoint.queryParameters)
        if !bypassGenericIdempotency,
           shouldUseGenericIdempotency(for: request),
           let key = try optionalIdempotencyKey(request)
        {
            return try await genericallyIdempotentResponse(
                request: request,
                grant: grant,
                key: key
            )
        }

        switch (request.method, request.path) {
        case (.get, "/v1/clients/current"):
            return try .json(
                APIClient(grant),
                headers: ["ETag": etag(grant.revision)]
            )
        case (.delete, "/v1/clients/current"):
            try requireIfMatch(request, revision: grant.revision)
            _ = try await authorization.revoke(clientID: grant.id)
            return APIResponse(status: 204)
        case (.get, "/v1/decks"):
            try require(grant, scope: .libraryRead)
            return try await listDecks(request)
        case (.post, "/v1/decks"):
            try require(grant, scope: .decksWrite)
            return try await createDeck(request, grant: grant)
        case (.post, "/v1/deck-deletion-plans"):
            try require(grant, scope: .decksWrite)
            return try await createDeckDeletionPlan(request)
        case (.post, "/v1/deck-reset-plans"):
            try require(grant, scope: .studyReview)
            return try await createDeckResetPlan(request)
        case (.get, "/v1/changes"):
            try requireChangeRead(grant)
            return try await listChanges(request, grant: grant)
        case (.get, "/v1/events"):
            try requireChangeRead(grant)
            return try await listEvents(request, grant: grant)
        case (.post, "/v1/study-sessions"):
            try require(grant, scope: .studyReview)
            return try await createStudySession(request, grant: grant)
        case (.post, "/v1/reviews"):
            try require(grant, scope: .studyReview)
            return try await submitReview(request, grant: grant)
        case (.get, "/v1/study-responses"):
            try require(grant, scope: .studyResponsesRead)
            return try await listStudyResponses(request)
        case (.get, "/v1/items"):
            try require(grant, scope: .libraryRead)
            return try await listItems(request)
        case (.post, "/v1/items"):
            try require(grant, scope: .itemsWrite)
            return try await createItem(request, grant: grant)
        case (.post, "/v1/items/validate"):
            try require(grant, scope: .itemsWrite)
            return try await validateItem(request)
        case (.post, "/v1/items/bulk"):
            try require(grant, scope: .itemsWrite)
            return try await bulkItems(request, grant: grant)
        case (.get, "/v1/tags"):
            try require(grant, scope: .libraryRead)
            return try await listTags(request)
        case (.post, "/v1/tag-renames"):
            try require(grant, scope: .itemsWrite)
            return try await renameTag(request)
        case (.get, "/v1/cards"):
            try require(grant, scope: .libraryRead)
            return try await listCards(request)
        case (.get, "/v1/item-types"):
            try require(grant, scope: .libraryRead)
            return try await listItemTypes(request)
        case (.post, "/v1/item-types"):
            try require(grant, scope: .schemasWrite)
            return try await createItemType(request)
        case (.post, "/v1/item-types/validate"):
            try require(grant, scope: .schemasWrite)
            return try await validateItemType(request)
        case (.post, "/v1/media"):
            try require(grant, scope: .mediaWrite)
            return try await uploadMedia(request, grant: grant)
        case (.post, "/v1/imports"):
            try require(grant, scope: .libraryImport)
            return try await createImportJob(request)
        case (.post, "/v1/exports"):
            try require(grant, scope: .libraryExport)
            return try await createExportJob(request, grant: grant)
        case (.get, "/v1/vocabulary-packs"):
            try require(grant, scope: .vocabularyRead)
            return try await listVocabularyPacks(request)
        case (.post, "/v1/vocabulary-pack-imports"):
            try require(grant, scope: .vocabularyWrite)
            return try await createVocabularyImport(request)
        default:
            break
        }

        let components = request.path.split(separator: "/").map(String.init)
        if components.count >= 3, components[0] == "v1", components[1] == "vocabulary-packs" {
            let packID = try decodeVocabularyPathSegment(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .vocabularyRead)
                    return try await getVocabularyPack(packID)
                case .delete:
                    try require(grant, scope: .vocabularyWrite)
                    return try await deleteVocabularyPack(packID, request: request)
                default: break
                }
            } else if components.count == 4, components[3] == "entries", request.method == .get {
                try require(grant, scope: .vocabularyRead)
                return try await searchVocabularyEntries(packID: packID, request: request)
            } else if components.count == 4, components[3] == "media",
                      request.method == .get || request.method == .head {
                try require(grant, scope: .vocabularyRead)
                return try await vocabularyMedia(
                    packID: packID, request: request, headOnly: request.method == .head
                )
            } else if components.count == 5, components[3] == "entries", request.method == .get {
                try require(grant, scope: .vocabularyRead)
                return try await getVocabularyEntry(
                    packID: packID,
                    entryID: try decodeVocabularyPathSegment(components[4], pointer: "/entryId")
                )
            }
        }
        if components.count >= 3, components[0] == "v1",
           components[1] == "vocabulary-pack-imports"
        {
            let jobID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .vocabularyWrite)
                    return try await getVocabularyImport(jobID)
                case .delete:
                    try require(grant, scope: .vocabularyWrite)
                    return try await deleteVocabularyImport(jobID, request: request)
                default: break
                }
            } else if components.count == 4, request.method == .post {
                try require(grant, scope: .vocabularyWrite)
                switch components[3] {
                case "validations":
                    return try await validateVocabularyImport(jobID)
                case "commits":
                    return try await commitVocabularyImport(jobID, request: request)
                default: break
                }
            } else if components.count == 5, components[3] == "files", request.method == .put {
                try require(grant, scope: .vocabularyWrite)
                return try await uploadVocabularyImportFile(
                    jobID: jobID,
                    fileID: try parseUUID(components[4], pointer: "/fileId"),
                    request: request
                )
            }
        }
        if components.count >= 3, components[0] == "v1", components[1] == "imports" {
            let jobID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .libraryImport)
                    return try await getImportJob(jobID)
                case .delete:
                    try require(grant, scope: .libraryImport)
                    return try await deleteImportJob(jobID, request: request)
                default: break
                }
            } else if components.count == 4, request.method == .post {
                try require(grant, scope: .libraryImport)
                switch components[3] {
                case "validations": return try await validateImportJob(jobID)
                case "commits": return try await commitImportJob(jobID, request: request, grant: grant)
                default: break
                }
            } else if components.count == 5, components[3] == "files", request.method == .put {
                try require(grant, scope: .libraryImport)
                return try await putImportFile(
                    jobID: jobID,
                    fileID: try parseUUID(components[4], pointer: "/fileId"),
                    request: request
                )
            }
        }
        if components.count >= 3, components[0] == "v1", components[1] == "exports" {
            let jobID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .libraryExport)
                    return try await getExportJob(jobID)
                case .delete:
                    try require(grant, scope: .libraryExport)
                    return try await deleteExportJob(jobID, request: request)
                default: break
                }
            } else if components.count == 4, components[3] == "content", request.method == .get {
                try require(grant, scope: .libraryExport)
                return try await getExportContent(jobID)
            }
        }
        if components.count == 4, components[0] == "v1",
           components[1] == "deck-deletion-plans", components[3] == "commits",
           request.method == .post
        {
            try require(grant, scope: .decksWrite)
            return try await commitDeckDeletionPlan(
                try parseUUID(components[2], pointer: "/id"),
                request: request,
                grant: grant
            )
        }
        if components.count == 4, components[0] == "v1",
           components[1] == "deck-reset-plans", components[3] == "commits",
           request.method == .post
        {
            try require(grant, scope: .studyReview)
            return try await commitDeckResetPlan(
                try parseUUID(components[2], pointer: "/id"),
                request: request,
                grant: grant
            )
        }
        if components.count >= 3, components[0] == "v1", components[1] == "study-sessions" {
            let sessionID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .studyReview)
                    return try await getStudySession(sessionID, grant: grant)
                case .delete:
                    try require(grant, scope: .studyReview)
                    return try await endStudySession(sessionID, request: request, grant: grant)
                default:
                    break
                }
            } else if components.count == 4, request.method == .post {
                try require(grant, scope: .studyReview)
                switch components[3] {
                case "next":
                    return try await nextStudyCard(sessionID, request: request, grant: grant)
                case "skips":
                    return try await skipStudyCard(sessionID, request: request, grant: grant)
                default:
                    break
                }
            }
        }

        if components.count == 4,
           components[0] == "v1", components[1] == "reviews",
           components[3] == "reverts", request.method == .post
        {
            try require(grant, scope: .studyReview)
            let reviewID = try parseUUID(components[2], pointer: "/reviewLogId")
            return try await revertReview(reviewID, request: request)
        }

        if components.count >= 3, components[0] == "v1", components[1] == "study-responses" {
            let responseID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .studyResponsesRead)
                    return try await getStudyResponse(responseID)
                case .delete:
                    try require(grant, scope: .studyResponsesDelete)
                    return try await deleteStudyResponse(responseID, request: request, grant: grant)
                default: break
                }
            } else if components.count == 4, components[3] == "content",
                      request.method == .get || request.method == .head {
                try require(grant, scope: .studyResponsesRead)
                return try await studyResponseContent(
                    responseID,
                    headOnly: request.method == .head,
                    request: request
                )
            }
        }

        if components.count >= 3, components[0] == "v1", components[1] == "items" {
            let itemID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .libraryRead)
                    return try await getItem(itemID)
                case .put:
                    try require(grant, scope: .itemsWrite)
                    return try await updateItem(itemID, request: request)
                case .delete:
                    try require(grant, scope: .itemsWrite)
                    return try await deleteItem(itemID, request: request)
                default:
                    break
                }
            } else if components.count == 4, components[3] == "duplicate-checks",
                      request.method == .post {
                try require(grant, scope: .libraryRead)
                return try await duplicateChecks(itemID, request: request)
            }
        }

        if components.count >= 3, components[0] == "v1", components[1] == "item-types" {
            let itemTypeID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .libraryRead)
                    return try await getItemType(itemTypeID)
                case .put:
                    try require(grant, scope: .schemasWrite)
                    return try await updateItemType(itemTypeID, request: request)
                case .delete:
                    try require(grant, scope: .schemasWrite)
                    return try await deleteItemType(itemTypeID, request: request)
                default:
                    break
                }
            } else if components.count == 4, components[3] == "duplicate",
                      request.method == .post {
                try require(grant, scope: .schemasWrite)
                return try await duplicateItemType(itemTypeID, request: request)
            }
        }

        if components.count == 4, components[0] == "v1", components[1] == "decks",
           components[3] == "item-type-policy", request.method == .get
        {
            try require(grant, scope: .libraryRead)
            let deckID = try parseUUID(components[2], pointer: "/id")
            return try await deckItemTypePolicy(deckID)
        }

        if components.count >= 3, components[0] == "v1", components[1] == "cards" {
            let cardID = try parseUUID(components[2], pointer: "/id")
            if components.count == 3 {
                switch request.method {
                case .get:
                    try require(grant, scope: .libraryRead)
                    return try await getCard(cardID)
                case .patch:
                    try require(grant, scope: .studyReview)
                    return try await patchCard(cardID, request: request)
                default:
                    break
                }
            } else if components.count == 4 {
                switch (request.method, components[3]) {
                case (.get, "content"):
                    try require(grant, scope: .libraryRead)
                    return try await cardContent(cardID)
                case (.get, "review-preview"):
                    try require(grant, scope: .libraryRead)
                    return try await cardReviewPreview(cardID, request: request)
                case (.post, "resets"):
                    try require(grant, scope: .studyReview)
                    return try await resetCard(cardID, request: request, grant: grant)
                default:
                    break
                }
            }
        }

        if components.count == 3, components[0] == "v1", components[1] == "tags",
           request.method == .delete
        {
            try require(grant, scope: .itemsWrite)
            guard let tag = components[2].removingPercentEncoding else {
                throw APIServiceError.validation("The tag path is invalid.")
            }
            return try await removeTag(tag, request: request)
        }

        if components.count >= 3, components[0] == "v1", components[1] == "media" {
            let hash = try validateMediaHash(components[2])
            if components.count == 3, request.method == .get || request.method == .head {
                try require(grant, scope: .libraryRead)
                return try await downloadMedia(
                    hash,
                    headOnly: request.method == .head,
                    request: request
                )
            }
            if components.count == 4, components[3] == "metadata", request.method == .get {
                try require(grant, scope: .libraryRead)
                return try await mediaMetadata(hash)
            }
        }

        if let deckID = resourceID(in: request.path, prefix: "/v1/decks/") {
            switch request.method {
            case .get:
                try require(grant, scope: .libraryRead)
                return try await getDeck(deckID)
            case .patch:
                try require(grant, scope: .decksWrite)
                return try await updateDeck(deckID, request: request)
            default:
                break
            }
        }

        throw APIServiceError.notFound("No version-1 operation matches this method and path.")
    }

    /// Supplies the common replay contract for mutations whose domain command
    /// does not need a caller-selected resource identifier for crash recovery.
    /// Commands with specialized recovery keep their own idempotency handling.
    private func genericallyIdempotentResponse(
        request: APIRequest,
        grant: APIClientGrant,
        key: String
    ) async throws -> APIResponse {
        let route = "\(request.method.rawValue) \(request.path)"
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method,
            path: request.path,
            body: request.body
        )
        let existingClaim = try await store.idempotencyClaim(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        )
        if case let .completed(_, status, body)? = existingClaim {
            return APIResponse(
                status: status,
                headers: body.isEmpty
                    ? [:]
                    : ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }

        let response = try await self.route(
            request,
            bypassGenericIdempotency: true
        )
        guard (200 ..< 300).contains(response.status) else { return response }
        _ = try await store.claimIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        )
        try await store.completeIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash,
            status: response.status,
            responseBody: response.body
        )
        return response
    }

    private func optionalIdempotencyKey(_ request: APIRequest) throws -> String? {
        guard let key = request.header("idempotency-key") else { return nil }
        guard !key.isEmpty, key.utf8.count <= 256 else {
            throw APIServiceError.validation(
                "Idempotency-Key may not be empty or exceed 256 UTF-8 bytes."
            )
        }
        return key
    }

    private func shouldUseGenericIdempotency(for request: APIRequest) -> Bool {
        guard [.delete, .patch, .post, .put].contains(request.method) else {
            return false
        }
        let path = request.path
        if request.method == .post,
           path == "/v1/decks"
            || path == "/v1/items"
            || path == "/v1/items/bulk"
            || path == "/v1/reviews"
            || path == "/v1/media"
            || path == "/v1/exports"
        {
            return false
        }
        if request.method == .post,
           path.hasPrefix("/v1/deck-deletion-plans/") && path.hasSuffix("/commits")
            || path.hasPrefix("/v1/deck-reset-plans/") && path.hasSuffix("/commits")
            || path.hasPrefix("/v1/cards/") && path.hasSuffix("/resets")
            || path.hasPrefix("/v1/imports/") && path.hasSuffix("/commits")
        {
            return false
        }
        return true
    }

    private func pair(_ request: APIRequest) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            PairingInput.self,
            from: request.body,
            allowedKeys: ["displayName", "requestedScopes", "origin"]
        )
        let name = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              name.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw APIServiceError.validation(
                "Client display name must be 1 to 256 UTF-8 bytes without control characters.",
                pointer: "/displayName"
            )
        }
        let scopes = Set(input.requestedScopes)
        guard !scopes.isEmpty, scopes.count == input.requestedScopes.count else {
            throw APIServiceError.validation(
                "Requested scopes must be non-empty and unique.",
                pointer: "/requestedScopes"
            )
        }
        let headerOrigin = request.header("origin")
        guard input.origin == headerOrigin else {
            throw APIServiceError.validation(
                "The body origin must exactly match the Origin header.",
                pointer: "/origin"
            )
        }
        if let origin = headerOrigin {
            try validateOriginSyntax(origin)
        }

        let now = Date.now
        pairingAttempts.removeAll { now.timeIntervalSince($0) >= 60 }
        guard pairingAttempts.count < 5, !pairingPromptActive else {
            throw APIServiceError.problem(
                status: 429,
                code: "rate_limited",
                title: "Too many pairing requests",
                detail: "Wait before requesting another pairing approval.",
                headers: ["Retry-After": "60"]
            )
        }
        pairingAttempts.append(now)
        pairingPromptActive = true
        let pairingRequest = APIPairingRequest(
            displayName: name,
            origin: headerOrigin,
            requestedScopes: scopes
        )
        let approved = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.pairingApprover.approve(pairingRequest) }
            group.addTask {
                let nanoseconds = UInt64(max(self.pairingRequestLifetime, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            if !result { await self.pairingApprover.cancel(pairingRequest) }
            return result
        }
        pairingPromptActive = false
        guard approved else {
            throw APIServiceError.problem(
                status: 403,
                code: "pairing_denied",
                title: "Pairing denied or expired",
                detail: "The user did not approve this client before the request expired."
            )
        }
        let issued = try await authorization.issueGrant(
            displayName: name,
            origin: headerOrigin,
            scopes: scopes,
            now: now
        )
        return try .json(
            status: 201,
            APIPairingResult(client: APIClient(issued.grant), token: issued.token),
            headers: ["ETag": etag(issued.grant.revision)]
        )
    }

    private func preflight(_ request: APIRequest) async throws -> APIResponse {
        guard let origin = request.header("origin") else {
            throw APIServiceError.problem(
                status: 403,
                code: "origin_required",
                title: "Origin required",
                detail: "Browser preflight requires an Origin header."
            )
        }
        try validateOriginSyntax(origin)
        guard let requestedMethod = request.header("access-control-request-method"),
              let method = APIHTTPMethod(rawValue: requestedMethod.uppercased())
        else {
            throw APIServiceError.validation("The preflight method is invalid.")
        }
        guard let endpoint = APIOpenAPI.endpoint(for: request.path, method: method) else {
            throw APIServiceError.notFound(
                "No version-1 operation matches the requested preflight method and path."
            )
        }
        let isPairing = request.path == "/v1/pairings"
        if !isPairing {
            let grants = try await authorization.listGrants()
            guard grants.contains(where: { $0.origin == origin }) else {
                throw APIServiceError.problem(
                    status: 403,
                    code: "origin_not_approved",
                    title: "Origin not approved",
                    detail: "This browser origin has no approved API client."
                )
            }
        }
        var allowedHeaders = ["Content-Type"]
        if !isPairing { allowedHeaders.append("Authorization") }
        for name in endpoint.parameters.filter({ $0.location == "header" }).map(\.name)
        where !allowedHeaders.contains(name) {
            allowedHeaders.append(name)
        }
        return APIResponse(
            status: 204,
            headers: [
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": method.rawValue,
                "Access-Control-Allow-Headers": allowedHeaders.joined(separator: ", "),
                "Access-Control-Max-Age": "600",
                "Vary": "Origin",
            ]
        )
    }

    private func authenticate(_ request: APIRequest) async throws -> APIClientGrant {
        guard let value = request.header("authorization") else {
            throw unauthorized()
        }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty,
              let grant = try await authorization.authenticate(token: parts[1])
        else {
            throw unauthorized()
        }
        let requestOrigin = request.header("origin")
        if grant.origin != requestOrigin, requestOrigin != nil || grant.origin != nil {
            throw APIServiceError.problem(
                status: 403,
                code: "origin_not_approved",
                title: "Origin not approved",
                detail: "The request origin does not match this client grant."
            )
        }
        return grant
    }

    private func listDecks(_ request: APIRequest) async throws -> APIResponse {
        try validateQuery(request.query, allowed: ["cursor", "limit"])
        let limit = try pageLimit(request.query)
        let routeKey = "/v1/decks"
        let offset: Int
        if let cursor = request.query["cursor"]?.first {
            offset = try await decodeCursor(cursor, route: routeKey)
        } else { offset = 0 }
        let decks = try await deckRepresentations()
        guard offset <= decks.count else {
            throw invalidCursor()
        }
        let end = min(offset + limit, decks.count)
        let page = Array(decks[offset ..< end])
        let next = end < decks.count ? try await encodedCursor(route: routeKey, offset: end) : nil
        return try .json(
            APICollection(data: page, page: APIPageInfo(nextCursor: next, limit: limit))
        )
    }

    private func getDeck(_ idText: String) async throws -> APIResponse {
        let id = try parseUUID(idText, pointer: "/id")
        _ = try await store.deck(id: id)
        let representation = try requireDeck(
            try await deckRepresentations().first { $0.id == id.uuidString.lowercased() }
        )
        return try .json(
            representation,
            headers: ["ETag": etag(representation.revision)]
        )
    }

    private func createDeck(_ request: APIRequest, grant: APIClientGrant) async throws -> APIResponse {
        let key = request.header("idempotency-key")
        if let key, key.isEmpty || key.utf8.count > 256 {
            throw APIServiceError.validation(
                "Idempotency-Key may not be empty or exceed 256 UTF-8 bytes."
            )
        }
        let input = try APIJSON.decodeStrict(
            CreateDeckInput.self,
            from: request.body,
            allowedKeys: ["id", "name", "parentId", "newCardsPerDay"]
        )
        let name = try validateDeckName(input.name)
        let requestedID = try input.id.map { try parseUUID($0, pointer: "/id") }
        let generatedID = requestedID ?? UUID()
        let parentID = try input.parentId.map { try parseUUID($0, pointer: "/parentId") }
        if let limit = input.newCardsPerDay, limit < 0 {
            throw APIServiceError.validation(
                "New cards per day cannot be negative.",
                pointer: "/newCardsPerDay"
            )
        }
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method,
            path: request.path,
            body: request.body
        )
        let claim: IdempotencyClaim?
        if let key {
            claim = try await store.claimIdempotency(
                clientID: grant.id,
                route: "POST /v1/decks",
                key: key,
                requestHash: hash,
                resultResourceID: generatedID.uuidString.lowercased()
            )
        } else { claim = nil }
        if case let .completed(_, status, body)? = claim {
            return replayDeckResponse(status: status, body: body)
        }
        let resultIDText: String?
        switch claim {
        case let .claimed(id)?, let .pending(id)?: resultIDText = id
        case .completed?, nil: resultIDText = nil
        }
        let resultID = try parseUUID(
            resultIDText ?? generatedID.uuidString.lowercased(),
            pointer: "/id"
        )

        let existing = try? await store.deck(id: resultID)
        let mayRecoverExisting: Bool
        if case .pending? = claim { mayRecoverExisting = true }
        else { mayRecoverExisting = false }
        if existing != nil, !mayRecoverExisting {
            throw APIServiceError.problem(
                status: 409,
                code: "resource_id_conflict",
                title: "Resource identifier conflict",
                detail: "The requested deck identifier already exists."
            )
        }
        if existing == nil {
            do {
                _ = try await store.createDeck(
                    Deck(
                        id: resultID,
                        name: name,
                        parentID: parentID,
                        newCardsPerDay: input.newCardsPerDay
                    )
                )
            } catch {
                // A concurrent retry can win between the recovery read and
                // create. Treat an existing deterministic result as success.
                guard (try? await store.deck(id: resultID)) != nil else { throw error }
            }
        }
        let representation = try requireDeck(
            try await deckRepresentations().first { $0.id == resultID.uuidString.lowercased() }
        )
        let body = try APIJSON.encoder.encode(representation)
        if let key {
            try await store.completeIdempotency(
                clientID: grant.id,
                route: "POST /v1/decks",
                key: key,
                requestHash: hash,
                status: 201,
                responseBody: body
            )
        }
        return APIResponse(
            status: 201,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "ETag": etag(representation.revision),
                "Location": "/v1/decks/\(representation.id)",
            ],
            body: body
        )
    }

    private func updateDeck(_ idText: String, request: APIRequest) async throws -> APIResponse {
        let id = try parseUUID(idText, pointer: "/id")
        var deck = try await store.deck(id: id)
        let revision = try await revision(resourceType: "deck", resourceID: id.uuidString)
        try requireIfMatch(request, revision: revision)
        let input = try APIJSON.decodeStrict(
            UpdateDeckInput.self,
            from: request.body,
            allowedKeys: ["name", "parentId", "newCardsPerDay"]
        )
        guard input.name != nil || input.parentId != nil || input.newCardsPerDay != nil else {
            throw APIServiceError.validation("A deck patch must change at least one member.")
        }
        if let name = input.name { deck.name = try validateDeckName(name) }
        if case let .value(value)? = input.parentId {
            deck.parentID = try value.map { try parseUUID($0, pointer: "/parentId") }
        }
        if case let .value(value)? = input.newCardsPerDay {
            if let value, value < 0 {
                throw APIServiceError.validation(
                    "New cards per day cannot be negative.",
                    pointer: "/newCardsPerDay"
                )
            }
            deck.newCardsPerDay = value
        }
        _ = try await store.updateDeck(deck)
        let representation = try requireDeck(
            try await deckRepresentations().first { $0.id == id.uuidString.lowercased() }
        )
        return try .json(
            representation,
            headers: ["ETag": etag(representation.revision)]
        )
    }

    private func createDeckDeletionPlan(_ request: APIRequest) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CreateDeckDeletionPlanInput.self,
            from: request.body,
            allowedKeys: ["deckId", "policy"]
        )
        let deckID = try parseUUID(input.deckId, pointer: "/deckId")
        let id = UUID()
        let now = Date.now
        let deckRevision = try await revision(
            resourceType: "deck", resourceID: deckID.uuidString
        )
        let representation = APIDeckDeletionPlan(
            id: id.uuidString.lowercased(),
            revision: 1,
            deckId: deckID.uuidString.lowercased(),
            policy: input.policy,
            impact: try await store.deckDeletionImpact(id: deckID, policy: input.policy),
            deckRevision: deckRevision,
            dependencyChangeCursor: try await store.currentChangeCursor(),
            expiresAt: now.addingTimeInterval(10 * 60)
        )
        deckDeletionPlans[id] = DeckDeletionPlanRecord(
            representation: representation,
            deckID: deckID,
            deckRevision: deckRevision
        )
        return try .json(
            status: 201,
            representation,
            headers: [
                "Location": "/v1/deck-deletion-plans/\(representation.id)",
                "ETag": etag(representation.revision),
            ]
        )
    }

    private func commitDeckDeletionPlan(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CommitDeckDeletionPlanInput.self,
            from: request.body,
            allowedKeys: ["confirm"]
        )
        let key = try requiredIdempotencyKey(request)
        let route = "POST /v1/deck-deletion-plans/\(id.uuidString.lowercased())/commits"
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        if case let .completed(_, status, body)? = try await store.idempotencyClaim(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        ) {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        guard let plan = deckDeletionPlans[id] else {
            throw APIServiceError.notFound("The deck deletion plan does not exist.")
        }
        try requireIfMatch(request, revision: plan.representation.revision)
        try await validatePlan(
            expiresAt: plan.representation.expiresAt,
            dependencyCursor: plan.representation.dependencyChangeCursor
        )
        if plan.representation.policy == .deleteSubtreeAndItems,
           input.confirm != true {
            throw APIServiceError.validation(
                "deleteSubtreeAndItems requires confirm to be true.", pointer: "/confirm"
            )
        }
        let claim = try await store.claimIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        )
        if case let .completed(_, status, body) = claim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        try await store.commitDeckDeletion(
            id: plan.deckID,
            policy: plan.representation.policy,
            asOf: .now
        )
        let result = APIPlanCommitResult(
            planId: plan.representation.id,
            committed: true,
            impact: plan.representation.impact
        )
        let body = try APIJSON.encoder.encode(result)
        try await store.completeIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash,
            status: 200,
            responseBody: body
        )
        return APIResponse(
            status: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    private func createDeckResetPlan(_ request: APIRequest) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CreateDeckResetPlanInput.self,
            from: request.body,
            allowedKeys: ["deckId"]
        )
        let deckID = try parseUUID(input.deckId, pointer: "/deckId")
        let id = UUID()
        let now = Date.now
        let deckRevision = try await revision(
            resourceType: "deck", resourceID: deckID.uuidString
        )
        let representation = APIDeckResetPlan(
            id: id.uuidString.lowercased(),
            revision: 1,
            deckId: deckID.uuidString.lowercased(),
            impact: try await store.deckResetImpact(id: deckID),
            deckRevision: deckRevision,
            dependencyChangeCursor: try await store.currentChangeCursor(),
            expiresAt: now.addingTimeInterval(10 * 60)
        )
        deckResetPlans[id] = DeckResetPlanRecord(
            representation: representation,
            deckID: deckID,
            deckRevision: deckRevision
        )
        return try .json(
            status: 201,
            representation,
            headers: [
                "Location": "/v1/deck-reset-plans/\(representation.id)",
                "ETag": etag(representation.revision),
            ]
        )
    }

    private func commitDeckResetPlan(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CommitDeckResetPlanInput.self,
            from: request.body,
            allowedKeys: ["confirm"]
        )
        guard input.confirm else {
            throw APIServiceError.validation(
                "A deck reset requires confirm to be true.", pointer: "/confirm"
            )
        }
        let key = try requiredIdempotencyKey(request)
        let route = "POST /v1/deck-reset-plans/\(id.uuidString.lowercased())/commits"
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        if case let .completed(_, status, body)? = try await store.idempotencyClaim(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        ) {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        guard let plan = deckResetPlans[id] else {
            throw APIServiceError.notFound("The deck reset plan does not exist.")
        }
        try requireIfMatch(request, revision: plan.representation.revision)
        try await validatePlan(
            expiresAt: plan.representation.expiresAt,
            dependencyCursor: plan.representation.dependencyChangeCursor
        )
        let claim = try await store.claimIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        )
        if case let .completed(_, status, body) = claim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        _ = try await store.resetDeckProgress(id: plan.deckID)
        let result = APIPlanCommitResult(
            planId: plan.representation.id,
            committed: true,
            impact: plan.representation.impact
        )
        let body = try APIJSON.encoder.encode(result)
        try await store.completeIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash,
            status: 200,
            responseBody: body
        )
        return APIResponse(
            status: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    private func validatePlan(expiresAt: Date, dependencyCursor: Int64) async throws {
        guard Date.now < expiresAt else {
            throw APIServiceError.problem(
                status: 410,
                code: "plan_expired",
                title: "Plan expired",
                detail: "The destructive-operation plan has expired."
            )
        }
        guard try await store.currentChangeCursor() == dependencyCursor else {
            throw APIServiceError.problem(
                status: 412,
                code: "plan_invalidated",
                title: "Plan invalidated",
                detail: "A dependency changed after the plan was created."
            )
        }
    }

    private func listStudyResponses(_ request: APIRequest) async throws -> APIResponse {
        try validateQuery(
            request.query,
            allowed: ["cursor", "limit", "cardId", "itemId", "tag", "createdAfter"]
        )
        let limit = try pageLimit(request.query)
        let routeKey = collectionRouteKey(path: "/v1/study-responses", query: request.query)
        let submittedBefore: Date?
        let submittedBeforeID: UUID?
        if let cursor = request.query["cursor"]?.first {
            let decoded = try APIStudyResponseCursor.decode(
                cursor,
                route: routeKey,
                libraryId: (try await store.libraryID()).uuidString.lowercased(),
                secret: cursorSecret
            )
            submittedBefore = decoded.submittedBefore
            submittedBeforeID = UUID(uuidString: decoded.submittedBeforeId)
        } else {
            submittedBefore = nil
            submittedBeforeID = nil
        }
        let cardID = try request.query["cardId"]?.first.map {
            try parseUUID($0, pointer: "/query/cardId")
        }
        let itemID = try request.query["itemId"]?.first.map {
            try parseUUID($0, pointer: "/query/itemId")
        }
        let createdAfter = try request.query["createdAfter"]?.first.map {
            try parseDate($0, pointer: "/query/createdAfter")
        }
        let responses = try await store.studyResponses(matching: StudyResponseQuery(
            cardID: cardID,
            itemID: itemID,
            tag: request.query["tag"]?.first,
            createdAfter: createdAfter,
            submittedBefore: submittedBefore,
            submittedBeforeID: submittedBeforeID,
            limit: limit + 1
        ))
        let pageResponses = responses.prefix(limit)
        var data: [APIStudyResponse] = []
        for response in pageResponses {
            data.append(try await studyResponseRepresentation(response))
        }
        let next: String?
        if responses.count > limit, let last = pageResponses.last {
            next = try APIStudyResponseCursor(
                route: routeKey,
                submittedBefore: last.submittedAt,
                submittedBeforeId: last.id.uuidString.lowercased(),
                libraryId: (try await store.libraryID()).uuidString.lowercased()
            ).encoded(secret: cursorSecret)
        } else {
            next = nil
        }
        return try .json(APICollection(
            data: data,
            page: APIPageInfo(nextCursor: next, limit: limit)
        ))
    }

    private func getStudyResponse(_ id: UUID) async throws -> APIResponse {
        let response: StudyResponse
        do { response = try await store.studyResponse(id: id) }
        catch DatabaseError.studyResponseNotFound { throw APIServiceError.notFound("The requested resource does not exist.") }
        let representation = try await studyResponseRepresentation(response)
        return try .json(representation, headers: ["ETag": etag(representation.revision)])
    }

    private func deleteStudyResponse(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        _ = grant
        _ = try requiredIdempotencyKey(request)
        let response: StudyResponse
        do { response = try await store.studyResponse(id: id) }
        catch DatabaseError.studyResponseNotFound { throw APIServiceError.notFound("The requested resource does not exist.") }
        let representation = try await studyResponseRepresentation(response)
        try requireIfMatch(request, revision: representation.revision)
        guard try await store.deleteStudyResponse(id: id, asOf: .now) else {
            throw APIServiceError.notFound("The requested resource does not exist.")
        }
        return APIResponse(status: 204)
    }

    private func studyResponseContent(
        _ id: UUID,
        headOnly: Bool,
        request: APIRequest
    ) async throws -> APIResponse {
        if request.header("range") != nil {
            throw APIServiceError.problem(
                status: 416,
                code: "range_not_supported",
                title: "Range not supported",
                detail: "This API version does not support response media range requests.",
                headers: ["Accept-Ranges": "none"]
            )
        }
        let response: StudyResponse
        let bytes: Data
        do { (response, _, bytes) = try await store.studyResponseMediaBytes(id: id) }
        catch DatabaseError.studyResponseNotFound { throw APIServiceError.notFound("The requested resource does not exist.") }
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": "audio/mp4",
                "Content-Disposition": "attachment; filename=\"study-response-\(response.id.uuidString.lowercased()).m4a\"",
                "Content-Length": String(bytes.count),
                "Digest": "sha-256=\(response.mediaHash)",
                "Accept-Ranges": "none",
            ],
            body: headOnly ? Data() : bytes
        )
    }

    private func studyResponseRepresentation(
        _ response: StudyResponse
    ) async throws -> APIStudyResponse {
        APIStudyResponse(
            response,
            revision: try await revision(
                resourceType: LibraryResourceKind.studyResponse.rawValue,
                resourceID: response.id.uuidString
            )
        )
    }

    private func listChanges(
        _ request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        try validateQuery(request.query, allowed: ["after", "limit"])
        let after: Int64
        if let value = request.query["after"]?.first {
            guard let parsed = Int64(value), parsed >= 0 else { throw invalidCursor() }
            after = parsed
        } else {
            after = 0
        }
        try await validateRetainedCursor(after)
        let limit = try changeLimit(request.query)
        let page = try await visibleChanges(after: after, limit: limit, grant: grant)
        let changes = page.changes
        let data = changes.map(APIChange.init)
        let next = page.lastScanned > after ? String(page.lastScanned) : nil
        return try .json(
            APICollection(data: data, page: APIPageInfo(nextCursor: next, limit: limit))
        )
    }

    private func listEvents(
        _ request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        try validateQuery(request.query, allowed: ["after"])
        let queryCursor = try request.query["after"]?.first.map { value -> Int64 in
            guard let cursor = Int64(value), cursor >= 0 else { throw invalidCursor() }
            return cursor
        }
        let headerCursor = try request.header("last-event-id").map { value -> Int64 in
            guard let cursor = Int64(value), cursor >= 0 else { throw invalidCursor() }
            return cursor
        }
        if let queryCursor, let headerCursor, queryCursor != headerCursor {
            throw APIServiceError.validation(
                "after and Last-Event-ID must identify the same cursor."
            )
        }
        let after = headerCursor ?? queryCursor ?? 0
        try await validateRetainedCursor(after)
        let page = try await visibleChanges(after: after, limit: 1_000, grant: grant)
        let changes = page.changes
        var body = Data()
        if changes.isEmpty {
            body.append(Data(": keep-alive\n\n".utf8))
        } else {
            for change in changes {
                let payload = try APIJSON.encoder.encode(APIChange(change))
                body.append(Data("id: \(change.cursor)\nevent: change\ndata: ".utf8))
                body.append(payload)
                body.append(Data("\n\n".utf8))
            }
        }
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "X-NeoAnki-Change-Cursor": String(page.lastScanned),
            ],
            body: body
        )
    }

    private func visibleChanges(
        after: Int64,
        limit: Int,
        grant: APIClientGrant
    ) async throws -> (changes: [LibraryChange], lastScanned: Int64) {
        var visible: [LibraryChange] = []
        var cursor = after
        while visible.count < limit {
            let batch = try await store.changes(after: cursor, limit: 1_000)
            guard !batch.isEmpty else { break }
            for change in batch {
                cursor = change.cursor
                if try await canReadChange(change, grant: grant) {
                    visible.append(change)
                    if visible.count == limit { break }
                }
            }
            if batch.count < 1_000 || visible.count == limit { break }
        }
        return (visible, cursor)
    }

    private func canReadChange(
        _ change: LibraryChange,
        grant: APIClientGrant
    ) async throws -> Bool {
        if change.resourceType == LibraryResourceKind.studyResponse.rawValue {
            return grant.scopes.contains(.studyResponsesRead)
        }
        guard grant.scopes.contains(.libraryRead) else { return false }
        if change.resourceType == LibraryResourceKind.media.rawValue,
           try await store.isStudyResponseMediaHash(change.resourceID),
           try await store.ordinaryMediaReferenceCount(hash: change.resourceID) == 0 {
            return false
        }
        return true
    }

    private func validateRetainedCursor(_ cursor: Int64) async throws {
        if let oldest = try await store.oldestChangeCursor(), cursor < oldest - 1 {
            throw APIServiceError.problem(
                status: 410,
                code: "cursor_expired",
                title: "Cursor expired",
                detail: "The requested change cursor is no longer retained."
            )
        }
    }

    private func createStudySession(
        _ request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CreateStudySessionInput.self,
            from: request.body,
            allowedKeys: ["scope"]
        )
        try validateNestedObject(
            request.body,
            key: "scope",
            allowedKeys: ["kind", "deckId", "includeDescendants"]
        )
        let scope: DeckScope
        switch input.scope.kind {
        case .allDecks:
            guard input.scope.deckId == nil, input.scope.includeDescendants == nil else {
                throw APIServiceError.validation(
                    "allDecks scope does not accept deck members.", pointer: "/scope"
                )
            }
            scope = .allDecks
        case .unassigned:
            guard input.scope.deckId == nil, input.scope.includeDescendants == nil else {
                throw APIServiceError.validation(
                    "unassigned scope does not accept deck members.", pointer: "/scope"
                )
            }
            scope = .unassigned
        case .deck:
            guard let deckText = input.scope.deckId,
                  let includeDescendants = input.scope.includeDescendants
            else {
                throw APIServiceError.validation(
                    "deck scope requires deckId and includeDescendants.", pointer: "/scope"
                )
            }
            scope = .deck(
                try parseUUID(deckText, pointer: "/scope/deckId"),
                includeDescendants: includeDescendants
            )
        }
        let session = try await store.createStudySession(clientID: grant.id, scope: scope)
        let representation = APIStudySession(session)
        return try .json(
            status: 201,
            representation,
            headers: [
                "ETag": etag(session.revision),
                "Location": "/v1/study-sessions/\(representation.id)",
            ]
        )
    }

    private func getStudySession(
        _ id: UUID,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let session = try await ownedStudySession(id, grant: grant)
        return try .json(
            APIStudySession(session),
            headers: ["ETag": etag(session.revision)]
        )
    }

    private func nextStudyCard(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        guard request.body.isEmpty else {
            throw APIServiceError.validation("Study next does not accept a request body.")
        }
        _ = try await ownedStudySession(id, grant: grant)
        guard let due = try await store.reserveNextStudyCard(sessionID: id) else {
            return APIResponse(status: 204)
        }
        let cardRevision = try await revision(
            resourceType: "card",
            resourceID: due.card.id.uuidString
        )
        return try .json(
            APIStudyCard(due, revision: cardRevision),
            headers: ["ETag": etag(cardRevision)]
        )
    }

    private func skipStudyCard(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        _ = try await ownedStudySession(id, grant: grant)
        let input = try APIJSON.decodeStrict(
            SkipStudyCardInput.self,
            from: request.body,
            allowedKeys: ["cardId"]
        )
        let cardID = try parseUUID(input.cardId, pointer: "/cardId")
        guard try await store.skipReservedStudyCard(sessionID: id, cardID: cardID) else {
            throw studyConflict("The card is not reserved by this study session.")
        }
        return APIResponse(status: 204)
    }

    private func endStudySession(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let session = try await ownedStudySession(id, grant: grant)
        try requireIfMatch(request, revision: session.revision)
        try await store.endStudySession(id: id)
        return APIResponse(status: 204)
    }

    private func submitReview(
        _ request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        guard let key = request.header("idempotency-key"),
              !key.isEmpty, key.utf8.count <= 256
        else {
            throw APIServiceError.validation(
                "Idempotency-Key is required and may not exceed 256 UTF-8 bytes."
            )
        }
        let input = try APIJSON.decodeStrict(
            SubmitReviewInput.self,
            from: request.body,
            allowedKeys: ["sessionId", "cardId", "rating", "durationMs"]
        )
        guard input.durationMs >= 0 else {
            throw APIServiceError.validation(
                "Review duration cannot be negative.", pointer: "/durationMs"
            )
        }
        let sessionID = try parseUUID(input.sessionId, pointer: "/sessionId")
        let cardID = try parseUUID(input.cardId, pointer: "/cardId")
        _ = try await ownedStudySession(sessionID, grant: grant)
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        let generatedLogID = UUID()
        let claim = try await store.claimIdempotency(
            clientID: grant.id,
            route: "POST /v1/reviews",
            key: key,
            requestHash: hash,
            resultResourceID: generatedLogID.uuidString.lowercased()
        )
        if case let .completed(_, status, body) = claim {
            return replayReviewResponse(status: status, body: body)
        }
        let resultIDText: String?
        switch claim {
        case let .claimed(id), let .pending(id): resultIDText = id
        case .completed: resultIDText = nil
        }
        let reviewLogID = try parseUUID(
            resultIDText ?? generatedLogID.uuidString.lowercased(),
            pointer: "/reviewLogId"
        )

        let response: APIReviewResult
        if let recovered = try await recoverReview(logID: reviewLogID, cardID: cardID) {
            response = recovered
        } else {
            let before = try await store.card(id: cardID).memory
            let result = try await store.submitReservedReview(
                sessionID: sessionID,
                cardID: cardID,
                rating: input.rating.domain,
                reviewLogID: reviewLogID,
                durationMilliseconds: input.durationMs
            )
            response = APIReviewResult(
                reviewLogId: result.reviewLogID.uuidString.lowercased(),
                revision: try await revision(
                    resourceType: "review", resourceID: result.reviewLogID.uuidString
                ),
                previousPhase: before.phase.rawValue,
                resultingPhase: result.memory.phase.rawValue,
                memory: APIMemory(result.memory),
                changeCursor: try await store.currentChangeCursor()
            )
        }
        let body = try APIJSON.encoder.encode(response)
        try await store.completeIdempotency(
            clientID: grant.id,
            route: "POST /v1/reviews",
            key: key,
            requestHash: hash,
            status: 201,
            responseBody: body
        )
        return APIResponse(
            status: 201,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Location": "/v1/reviews/\(response.reviewLogId)",
                "ETag": etag(response.revision),
            ],
            body: body
        )
    }

    private func recoverReview(logID: UUID, cardID: UUID) async throws -> APIReviewResult? {
        guard let log = try? await store.reviewLog(id: logID), log.cardID == cardID else {
            return nil
        }
        let memory = try await store.card(id: cardID).memory
        return APIReviewResult(
            reviewLogId: logID.uuidString.lowercased(),
            revision: try await revision(
                resourceType: "review", resourceID: logID.uuidString
            ),
            previousPhase: log.phaseBefore.rawValue,
            resultingPhase: memory.phase.rawValue,
            memory: APIMemory(memory),
            changeCursor: try await store.currentChangeCursor()
        )
    }

    private func replayReviewResponse(status: Int, body: Data) -> APIResponse {
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        if let result = try? APIJSON.decoder.decode(APIReviewResult.self, from: body) {
            headers["ETag"] = etag(result.revision)
            headers["Location"] = "/v1/reviews/\(result.reviewLogId)"
        }
        return APIResponse(status: status, headers: headers, body: body)
    }

    private func revertReview(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        guard request.body.isEmpty else {
            throw APIServiceError.validation("Review revert does not accept a request body.")
        }
        let revision = try await revision(resourceType: "review", resourceID: id.uuidString)
        try requireIfMatch(request, revision: revision)
        try await store.revertReview(id: id, asOf: .now)
        return APIResponse(status: 204)
    }

    private func ownedStudySession(
        _ id: UUID,
        grant: APIClientGrant
    ) async throws -> StudySessionRecord {
        let session = try await store.studySession(id: id)
        guard session.clientID == grant.id else {
            throw APIServiceError.notFound("The requested resource does not exist.")
        }
        return session
    }

    private func validateNestedObject(
        _ body: Data,
        key: String,
        allowedKeys: Set<String>
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let nested = object[key] as? [String: Any]
        else {
            throw APIServiceError.validation("Expected a JSON object.", pointer: "/\(key)")
        }
        if let unknown = Set(nested.keys).subtracting(allowedKeys).sorted().first {
            throw APIServiceError.validation(
                "Unknown request member.",
                pointer: "/\(key)/\(unknown)",
                fieldCode: "unknown_member"
            )
        }
    }

    private func rejectUnknownMembers(
        _ object: [String: Any],
        allowed: Set<String>,
        pointer: String
    ) throws {
        guard let unknown = Set(object.keys).subtracting(allowed).sorted().first else { return }
        throw APIServiceError.validation(
            "Unknown request member.",
            pointer: pointer + "/" + unknown,
            fieldCode: "unknown_member"
        )
    }

    private func validateItemInputShape(_ body: Data, allowsID: Bool = true) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw APIServiceError.validation("The request body must be a JSON object.")
        }
        try validateItemObjectShape(object, pointer: "", allowsID: allowsID)
    }

    private func validateItemObjectShape(
        _ object: [String: Any],
        pointer: String,
        allowsID: Bool
    ) throws {
        var allowed: Set<String> = ["itemTypeId", "deckId", "fields", "tags"]
        if allowsID { allowed.insert("id") }
        try rejectUnknownMembers(object, allowed: allowed, pointer: pointer)
        guard let fields = object["fields"] as? [Any] else { return }
        for (index, value) in fields.enumerated() {
            let fieldPointer = pointer + "/fields/\(index)"
            guard let field = value as? [String: Any] else {
                throw APIServiceError.validation("Expected a JSON object.", pointer: fieldPointer)
            }
            try rejectUnknownMembers(
                field, allowed: ["fieldId", "value"], pointer: fieldPointer
            )
            guard let content = field["value"] as? [String: Any] else { continue }
            let contentPointer = fieldPointer + "/value"
            let common: Set<String> = ["type"]
            let allowedContent: Set<String>
            switch content["type"] as? String {
            case "empty": allowedContent = common
            case "text": allowedContent = common.union(["text", "lang"])
            case "rich": allowedContent = common.union(["spans"])
            case "media":
                allowedContent = common.union([
                    "mediaId", "kind", "sha256", "fileExtension", "durationMs",
                    "altText", "reservationId",
                ])
            case "cloze": allowedContent = common.union(["text", "blanks"])
            case "number": allowedContent = common.union(["number"])
            default: allowedContent = common
            }
            try rejectUnknownMembers(content, allowed: allowedContent, pointer: contentPointer)
            if let spans = content["spans"] as? [Any] {
                for (spanIndex, spanValue) in spans.enumerated() {
                    guard let span = spanValue as? [String: Any] else { continue }
                    try rejectUnknownMembers(
                        span,
                        allowed: ["text", "styles", "textColor", "textSize", "link"],
                        pointer: contentPointer + "/spans/\(spanIndex)"
                    )
                }
            }
            if let blanks = content["blanks"] as? [Any] {
                for (blankIndex, blankValue) in blanks.enumerated() {
                    guard let blank = blankValue as? [String: Any] else { continue }
                    try rejectUnknownMembers(
                        blank,
                        allowed: ["group", "start", "length", "hint"],
                        pointer: contentPointer + "/blanks/\(blankIndex)"
                    )
                }
            }
        }
    }

    private func validateBulkItemInputShape(_ body: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operations = object["operations"] as? [Any]
        else { return }
        for (index, value) in operations.enumerated() {
            let pointer = "/operations/\(index)"
            guard let operation = value as? [String: Any] else {
                throw APIServiceError.validation("Expected a JSON object.", pointer: pointer)
            }
            try rejectUnknownMembers(
                operation,
                allowed: ["operationId", "action", "item", "itemId"],
                pointer: pointer
            )
            if let item = operation["item"] as? [String: Any] {
                try validateItemObjectShape(item, pointer: pointer + "/item", allowsID: true)
            }
        }
    }

    private func validateImportManifestShape(_ body: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let files = object["files"] as? [Any]
        else { return }
        for (index, value) in files.enumerated() {
            let pointer = "/files/\(index)"
            guard let file = value as? [String: Any] else {
                throw APIServiceError.validation("Expected a JSON object.", pointer: pointer)
            }
            try rejectUnknownMembers(
                file,
                allowed: ["relativePath", "byteSize", "sha256"],
                pointer: pointer
            )
        }
    }

    private func validateItemTypeInputShape(_ body: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw APIServiceError.validation("The request body must be a JSON object.")
        }
        if let fields = object["fields"] as? [Any] {
            for (index, value) in fields.enumerated() {
                guard let field = value as? [String: Any] else { continue }
                try rejectUnknownMembers(
                    field,
                    allowed: ["id", "name", "type", "isRequired"],
                    pointer: "/fields/\(index)"
                )
            }
        }
        if let templates = object["templates"] as? [Any] {
            for (index, value) in templates.enumerated() {
                let pointer = "/templates/\(index)"
                guard let template = value as? [String: Any] else { continue }
                try rejectUnknownMembers(
                    template,
                    allowed: [
                        "id", "name", "prompt", "answer", "interaction", "skill",
                        "generateWhen",
                    ],
                    pointer: pointer
                )
                try validateSlots(template["prompt"], pointer: pointer + "/prompt")
                try validateSlots(template["answer"], pointer: pointer + "/answer")
                if let skill = template["skill"] as? [String: Any] {
                    try rejectUnknownMembers(
                        skill,
                        allowed: ["input", "output", "operation"],
                        pointer: pointer + "/skill"
                    )
                }
                if let condition = template["generateWhen"] as? [String: Any] {
                    try validateConditionShape(condition, pointer: pointer + "/generateWhen")
                }
            }
        }
    }

    private func validateSlots(_ value: Any?, pointer: String) throws {
        guard let slots = value as? [Any] else { return }
        for (index, value) in slots.enumerated() {
            let slotPointer = pointer + "/\(index)"
            guard let slot = value as? [String: Any] else { continue }
            try rejectUnknownMembers(
                slot, allowed: ["source", "presentation"], pointer: slotPointer
            )
            if let source = slot["source"] as? [String: Any] {
                try rejectUnknownMembers(
                    source,
                    allowed: ["kind", "fieldId", "text"],
                    pointer: slotPointer + "/source"
                )
            }
            if let presentation = slot["presentation"] as? [String: Any] {
                try rejectUnknownMembers(
                    presentation,
                    allowed: ["reveal", "media"],
                    pointer: slotPointer + "/presentation"
                )
            }
        }
    }

    private func validateConditionShape(_ condition: [String: Any], pointer: String) throws {
        try rejectUnknownMembers(
            condition,
            allowed: ["kind", "fieldId", "conditions"],
            pointer: pointer
        )
        if let children = condition["conditions"] as? [Any] {
            for (index, value) in children.enumerated() {
                guard let child = value as? [String: Any] else { continue }
                try validateConditionShape(child, pointer: pointer + "/conditions/\(index)")
            }
        }
    }

    private func studyConflict(_ detail: String) -> APIServiceError {
        .problem(
            status: 409,
            code: "study_conflict",
            title: "Study conflict",
            detail: detail
        )
    }

    private func listItems(_ request: APIRequest) async throws -> APIResponse {
        let allowed: Set<String> = [
            "cursor", "limit", "deckId", "includeDescendants", "itemTypeId",
            "tag", "text", "schedulePhase", "dueBefore", "createdAfter", "updatedAfter",
        ]
        try validateQuery(request.query, allowed: allowed)
        let limit = try pageLimit(request.query)
        let routeKey = collectionRouteKey(path: request.path, query: request.query)
        let offset: Int
        if let cursor = request.query["cursor"]?.first {
            offset = try await decodeCursor(cursor, route: routeKey)
        } else {
            offset = 0
        }
        if Set(request.query.keys).isSubset(of: ["cursor", "limit"]) {
            let records = try await store.itemRecordsPage(
                offset: offset,
                limit: limit + 1
            )
            let page = records.prefix(limit)
            var data: [APIItem] = []
            data.reserveCapacity(page.count)
            for record in page {
                data.append(APIItem(
                    record,
                    revision: try await revision(
                        resourceType: "item", resourceID: record.id.uuidString
                    )
                ))
            }
            let next = records.count > limit
                ? try await encodedCursor(route: routeKey, offset: offset + limit)
                : nil
            return try .json(
                APICollection(data: data, page: .init(nextCursor: next, limit: limit))
            )
        }
        var records = try await store.itemRecords()
        if let value = request.query["deckId"]?.first {
            let deckID = try parseUUID(value, pointer: "/query/deckId")
            let descendants = try boolQuery(request.query, key: "includeDescendants") ?? false
            let ids: Set<UUID>
            if descendants {
                ids = DeckTree.descendantIDs(of: deckID, in: try await store.deckSummaries())
            } else {
                ids = [deckID]
            }
            records.removeAll { $0.item.deckID.map(ids.contains) != true }
        } else if request.query["includeDescendants"] != nil {
            throw APIServiceError.validation(
                "includeDescendants requires deckId.", pointer: "/query/includeDescendants"
            )
        }
        if let value = request.query["itemTypeId"]?.first {
            let id = try parseUUID(value, pointer: "/query/itemTypeId")
            records.removeAll { $0.item.itemTypeID != id }
        }
        var requiredTags: [String] = []
        for tag in request.query["tag"] ?? [] {
            requiredTags.append(try await store.normalizedTagForLookup(tag))
        }
        if !requiredTags.isEmpty {
            records.removeAll { !Set(requiredTags).isSubset(of: Set($0.item.tags)) }
        }
        if let text = request.query["text"]?.first {
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let matchingIDs = Set(try await store.items().compactMap {
                    ItemBrowsing.matches($0, query: query) ? $0.id : nil
                })
                records.removeAll { !matchingIDs.contains($0.id) }
            }
        }
        if let value = request.query["createdAfter"]?.first {
            let date = try parseDate(value, pointer: "/query/createdAfter")
            records.removeAll { $0.createdAt <= date }
        }
        if let value = request.query["updatedAfter"]?.first {
            let date = try parseDate(value, pointer: "/query/updatedAfter")
            records.removeAll { $0.updatedAt <= date }
        }
        if let phase = request.query["schedulePhase"]?.first {
            guard Phase(rawValue: phase) != nil else {
                throw APIServiceError.validation("Unknown schedule phase.", pointer: "/query/schedulePhase")
            }
            let cards = Dictionary(grouping: try await store.cards(), by: \.itemID)
            records.removeAll { !(cards[$0.item.id] ?? []).contains { $0.memory.phase.rawValue == phase } }
        }
        if let value = request.query["dueBefore"]?.first {
            let date = try parseDate(value, pointer: "/query/dueBefore")
            let cards = Dictionary(grouping: try await store.cards(), by: \.itemID)
            records.removeAll { !(cards[$0.item.id] ?? []).contains { $0.memory.due < date } }
        }
        records.sort {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
        guard offset <= records.count else { throw invalidCursor() }
        let end = min(offset + limit, records.count)
        var data: [APIItem] = []
        for record in records[offset ..< end] {
            data.append(APIItem(
                record,
                revision: try await revision(resourceType: "item", resourceID: record.id.uuidString)
            ))
        }
        let next = end < records.count ? try await encodedCursor(route: routeKey, offset: end) : nil
        return try .json(APICollection(data: data, page: .init(nextCursor: next, limit: limit)))
    }

    private func createItem(_ request: APIRequest, grant: APIClientGrant) async throws -> APIResponse {
        let key = try requiredIdempotencyKey(request)
        let input = try decodeCreateItem(request.body)
        let generatedID = try input.id.map { try parseUUID($0, pointer: "/id") } ?? UUID()
        let item = try item(
            id: generatedID,
            itemTypeID: input.itemTypeId,
            deckID: input.deckId,
            fields: input.fields,
            tags: input.tags
        )
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        let claim = try await store.claimIdempotency(
            clientID: grant.id,
            route: "POST /v1/items",
            key: key,
            requestHash: hash,
            resultResourceID: generatedID.uuidString.lowercased()
        )
        if case let .completed(_, status, body) = claim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        let resultIDText: String?
        switch claim {
        case let .claimed(id), let .pending(id): resultIDText = id
        case .completed: resultIDText = nil
        }
        let resultID = try parseUUID(
            resultIDText ?? generatedID.uuidString.lowercased(), pointer: "/id"
        )
        if (try? await store.itemRecord(id: resultID)) == nil {
            var deterministic = item
            deterministic = Item(
                id: resultID,
                itemTypeID: item.itemTypeID,
                fields: item.fields,
                tags: item.tags,
                deckID: item.deckID
            )
            _ = try await store.createItem(deterministic)
        }
        let representation = try await itemRepresentation(id: resultID)
        let body = try APIJSON.encoder.encode(representation)
        try await store.completeIdempotency(
            clientID: grant.id,
            route: "POST /v1/items",
            key: key,
            requestHash: hash,
            status: 201,
            responseBody: body
        )
        return APIResponse(
            status: 201,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "ETag": etag(representation.revision),
                "Location": "/v1/items/\(representation.id)",
            ],
            body: body
        )
    }

    private func validateItem(_ request: APIRequest) async throws -> APIResponse {
        let input = try decodeCreateItem(request.body)
        let item = try item(
            id: try input.id.map { try parseUUID($0, pointer: "/id") } ?? UUID(),
            itemTypeID: input.itemTypeId,
            deckID: input.deckId,
            fields: input.fields,
            tags: input.tags
        )
        try await store.validateItem(item)
        return APIResponse(status: 204)
    }

    private func bulkItems(_ request: APIRequest, grant: APIClientGrant) async throws -> APIResponse {
        try validateBulkItemInputShape(request.body)
        let input = try APIJSON.decodeStrict(
            BulkItemsInput.self,
            from: request.body,
            allowedKeys: ["atomic", "dryRun", "operations"]
        )
        guard input.atomic else {
            throw APIServiceError.validation(
                "Version 1 requires atomic to be true.", pointer: "/atomic"
            )
        }
        guard input.operations.count <= 500 else {
            throw APIServiceError.problem(
                status: 413,
                code: "bulk_limit_exceeded",
                title: "Bulk limit exceeded",
                detail: "A bulk request may contain at most 500 operations."
            )
        }

        let operations = try input.operations.enumerated().map { index, operation in
            let pointer = "/operations/\(index)"
            switch operation.action {
            case "create", "replace":
                guard operation.itemId == nil, let source = operation.item,
                      let idText = source.id
                else {
                    throw APIServiceError.validation(
                        "Create and replace operations require item.id and do not accept itemId.",
                        pointer: pointer
                    )
                }
                let value = try item(
                    id: parseUUID(idText, pointer: pointer + "/item/id"),
                    itemTypeID: source.itemTypeId,
                    deckID: source.deckId,
                    fields: source.fields,
                    tags: source.tags
                )
                return ItemBulkOperation(
                    operationID: operation.operationId,
                    action: operation.action == "create" ? .create(value) : .replace(value)
                )
            case "delete":
                guard operation.item == nil, let idText = operation.itemId else {
                    throw APIServiceError.validation(
                        "Delete operations require itemId and do not accept item.",
                        pointer: pointer
                    )
                }
                return ItemBulkOperation(
                    operationID: operation.operationId,
                    action: .delete(try parseUUID(idText, pointer: pointer + "/itemId"))
                )
            default:
                throw APIServiceError.validation(
                    "Unknown bulk action.", pointer: pointer + "/action"
                )
            }
        }

        let key = input.dryRun ? nil : try requiredIdempotencyKey(request)
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        if let key {
            let claim = try await store.claimIdempotency(
                clientID: grant.id,
                route: "POST /v1/items/bulk",
                key: key,
                requestHash: hash
            )
            if case let .completed(_, status, body) = claim {
                return APIResponse(
                    status: status,
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: body
                )
            }
        }

        let planned: [ItemBulkOperationResult]
        do {
            planned = try await store.executeItemBulk(operations, dryRun: input.dryRun)
        } catch let error as ItemBulkOperationError {
            throw APIServiceError.validation(
                "Operation \(error.operationID): \(error.detail)",
                pointer: error.pointer
            )
        }
        let response = APIBulkItemsResult(
            dryRun: input.dryRun,
            results: planned.map(APIBulkItemResult.init),
            impact: APIBulkItemImpact(
                createdItemCount: planned.count { $0.action == "create" },
                replacedItemCount: planned.count { $0.action == "replace" },
                deletedItemCount: planned.count { $0.action == "delete" },
                resultingCardCount: planned.reduce(0) { $0 + $1.cardIDs.count }
            )
        )
        let body = try APIJSON.encoder.encode(response)
        if let key {
            try await store.completeIdempotency(
                clientID: grant.id,
                route: "POST /v1/items/bulk",
                key: key,
                requestHash: hash,
                status: 200,
                responseBody: body
            )
        }
        return APIResponse(
            status: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    private func getItem(_ id: UUID) async throws -> APIResponse {
        let representation = try await itemRepresentation(id: id)
        return try .json(representation, headers: ["ETag": etag(representation.revision)])
    }

    private func updateItem(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let existing = try await store.itemRecord(id: id)
        let currentRevision = try await revision(resourceType: "item", resourceID: id.uuidString)
        try requireIfMatch(request, revision: currentRevision)
        try validateItemInputShape(request.body, allowsID: false)
        let input = try APIJSON.decodeStrict(
            PutItemInput.self,
            from: request.body,
            allowedKeys: ["itemTypeId", "deckId", "fields", "tags"]
        )
        let item = try item(
            id: id,
            itemTypeID: input.itemTypeId,
            deckID: input.deckId,
            fields: input.fields,
            tags: input.tags
        )
        guard item.itemTypeID == existing.item.itemTypeID else {
            throw APIServiceError.validation(
                "itemTypeId is immutable after creation.", pointer: "/itemTypeId"
            )
        }
        _ = try await store.updateItem(item)
        let representation = try await itemRepresentation(id: id)
        return try .json(representation, headers: ["ETag": etag(representation.revision)])
    }

    private func deleteItem(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let currentRevision = try await revision(resourceType: "item", resourceID: id.uuidString)
        try requireIfMatch(request, revision: currentRevision)
        let cardIDs = Set(try await store.cards().filter { $0.itemID == id }.map(\.id))
        let responseCount = try await store.studyResponseCount(cardIDs: cardIDs)
        if responseCount > 0 {
            let requestHash = try APIJSON.canonicalRequestHash(
                method: request.method, path: request.path, body: request.body
            )
            try await requireStudyResponseDeletionConfirmation(
                resourceID: id,
                requestHash: requestHash,
                suppliedToken: request.header("neoanki-impact-token"),
                impact: APIImpactSummary(
                    affectedItemCount: 1,
                    affectedCardCount: cardIDs.count,
                    affectedStudyResponseCount: responseCount
                )
            )
        }
        guard try await store.deleteItem(id: id) else {
            throw APIServiceError.notFound("The requested resource does not exist.")
        }
        return APIResponse(status: 204)
    }

    private func decodeCreateItem(_ body: Data) throws -> CreateItemInput {
        try validateItemInputShape(body)
        return try APIJSON.decodeStrict(
            CreateItemInput.self,
            from: body,
            allowedKeys: ["id", "itemTypeId", "deckId", "fields", "tags"]
        )
    }

    private func item(
        id: UUID,
        itemTypeID: String,
        deckID: String?,
        fields: [APIFieldValue],
        tags: [String]
    ) throws -> Item {
        let typeID = try parseUUID(itemTypeID, pointer: "/itemTypeId")
        let parsedDeckID = try deckID.map { try parseUUID($0, pointer: "/deckId") }
        let values = try fields.enumerated().map { index, field in
            FieldValue(
                fieldID: try parseUUID(field.fieldId, pointer: "/fields/\(index)/fieldId"),
                value: try field.value.domain(pointer: "/fields/\(index)/value")
            )
        }
        return Item(id: id, itemTypeID: typeID, fields: values, tags: tags, deckID: parsedDeckID)
    }

    private func itemRepresentation(id: UUID) async throws -> APIItem {
        let record = try await store.itemRecord(id: id)
        return APIItem(
            record,
            revision: try await revision(resourceType: "item", resourceID: id.uuidString)
        )
    }

    private func duplicateChecks(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        _ = try APIJSON.decodeStrict(
            DuplicateCheckInput.self,
            from: request.body,
            allowedKeys: []
        )
        let source = try await store.itemRecord(id: id).item
        let canonical = source.fields.map { field in
            (field.fieldID, ItemDisplay.plainText(from: field.value)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
        let candidates = try await store.itemRecords().compactMap { record -> APIDuplicateCandidate? in
            guard record.id != id, record.item.itemTypeID == source.itemTypeID else { return nil }
            let candidate = record.item.fields.map { field in
                (field.fieldID, ItemDisplay.plainText(from: field.value)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
            }
            guard candidate.elementsEqual(canonical, by: { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }) else { return nil }
            return APIDuplicateCandidate(
                itemId: record.id.uuidString.lowercased(),
                reasonCodes: ["same_normalized_content"]
            )
        }.sorted { $0.itemId < $1.itemId }
        return try .json(APIDuplicateCheckResult(candidates: candidates))
    }

    private func listTags(_ request: APIRequest) async throws -> APIResponse {
        try validateQuery(request.query, allowed: ["cursor", "limit"])
        let limit = try pageLimit(request.query)
        var counts: [String: Int] = [:]
        for record in try await store.itemRecords() {
            for tag in record.item.tags { counts[tag, default: 0] += 1 }
        }
        let aggregateRevision = try await store.currentChangeCursor()
        var tags: [APITag] = counts.map { entry in
            APITag(
                name: entry.key,
                itemCount: entry.value,
                revision: Int(aggregateRevision)
            )
        }
        tags.sort { lhs, rhs in lhs.name < rhs.name }
        let routeKey = "/v1/tags"
        let offset: Int
        if let cursor = request.query["cursor"]?.first {
            offset = try await decodeCursor(cursor, route: routeKey)
        } else { offset = 0 }
        guard offset <= tags.count else { throw invalidCursor() }
        let end = min(offset + limit, tags.count)
        let next = end < tags.count ? try await encodedCursor(route: routeKey, offset: end) : nil
        return try .json(
            APICollection(
                data: Array(tags[offset ..< end]),
                page: .init(nextCursor: next, limit: limit)
            ),
            headers: ["ETag": etag(aggregateRevision)]
        )
    }

    private func renameTag(_ request: APIRequest) async throws -> APIResponse {
        let aggregateRevision = try await store.currentChangeCursor()
        try requireIfMatch(request, revision: aggregateRevision)
        let input = try APIJSON.decodeStrict(
            RenameTagInput.self,
            from: request.body,
            allowedKeys: ["from", "to"]
        )
        let count = try await store.renameTag(from: input.from, to: input.to)
        return try .json(["updatedItemCount": count])
    }

    private func removeTag(_ tag: String, request: APIRequest) async throws -> APIResponse {
        guard request.body.isEmpty else {
            throw APIServiceError.validation("Tag removal does not accept a body.")
        }
        try requireIfMatch(request, revision: try await store.currentChangeCursor())
        _ = try await store.removeTag(tag)
        return APIResponse(status: 204)
    }

    private func listCards(_ request: APIRequest) async throws -> APIResponse {
        let allowed: Set<String> = [
            "cursor", "limit", "itemId", "deckId", "includeDescendants", "templateId",
            "phase", "isSuspended", "dueBefore",
        ]
        try validateQuery(request.query, allowed: allowed)
        let limit = try pageLimit(request.query)
        var cards = try await store.cards()
        if let value = request.query["itemId"]?.first {
            let id = try parseUUID(value, pointer: "/query/itemId")
            cards.removeAll { $0.itemID != id }
        }
        if let value = request.query["templateId"]?.first {
            let id = try parseUUID(value, pointer: "/query/templateId")
            cards.removeAll { $0.templateID != id }
        }
        if let value = request.query["deckId"]?.first {
            let id = try parseUUID(value, pointer: "/query/deckId")
            let descendants = try boolQuery(request.query, key: "includeDescendants") ?? false
            let ids = descendants
                ? DeckTree.descendantIDs(of: id, in: try await store.deckSummaries())
                : Set([id])
            cards.removeAll { $0.deckID.map(ids.contains) != true }
        } else if request.query["includeDescendants"] != nil {
            throw APIServiceError.validation("includeDescendants requires deckId.")
        }
        if let value = request.query["phase"]?.first {
            guard Phase(rawValue: value) != nil else {
                throw APIServiceError.validation("Unknown phase.", pointer: "/query/phase")
            }
            cards.removeAll { $0.memory.phase.rawValue != value }
        }
        if let suspended = try boolQuery(request.query, key: "isSuspended") {
            cards.removeAll { $0.isSuspended != suspended }
        }
        if let value = request.query["dueBefore"]?.first {
            let date = try parseDate(value, pointer: "/query/dueBefore")
            cards.removeAll { $0.memory.due >= date }
        }
        cards.sort { $0.id.uuidString < $1.id.uuidString }
        let routeKey = collectionRouteKey(path: request.path, query: request.query)
        let offset: Int
        if let cursor = request.query["cursor"]?.first {
            offset = try await decodeCursor(cursor, route: routeKey)
        } else { offset = 0 }
        guard offset <= cards.count else { throw invalidCursor() }
        let end = min(offset + limit, cards.count)
        var data: [APICard] = []
        for card in cards[offset ..< end] {
            data.append(APICard(
                card,
                revision: try await revision(resourceType: "card", resourceID: card.id.uuidString)
            ))
        }
        let next = end < cards.count ? try await encodedCursor(route: routeKey, offset: end) : nil
        return try .json(APICollection(data: data, page: .init(nextCursor: next, limit: limit)))
    }

    private func getCard(_ id: UUID) async throws -> APIResponse {
        let card = try await store.card(id: id)
        let revision = try await revision(resourceType: "card", resourceID: id.uuidString)
        return try .json(APICard(card, revision: revision), headers: ["ETag": etag(revision)])
    }

    private func cardContent(_ id: UUID) async throws -> APIResponse {
        let card = try await store.hydratedCard(id: id)
        let revision = try await revision(resourceType: "card", resourceID: id.uuidString)
        return try .json(APIStudyCard(card, revision: revision), headers: ["ETag": etag(revision)])
    }

    private func cardReviewPreview(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        guard request.body.isEmpty else {
            throw APIServiceError.validation("Review preview does not accept a body.")
        }
        let previews = try await store.reviewPreviews(cardID: id)
        let names: [(ReviewRating, String)] = [
            (.again, "again"), (.hard, "hard"), (.good, "good"), (.easy, "easy"),
        ]
        return try .json(names.compactMap { rating, name in
            previews[rating].map { APIRatingPreview(rating: name, memory: APIMemory($0)) }
        })
    }

    private func patchCard(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let revision = try await revision(resourceType: "card", resourceID: id.uuidString)
        try requireIfMatch(request, revision: revision)
        let input = try APIJSON.decodeStrict(
            PatchCardInput.self,
            from: request.body,
            allowedKeys: ["isSuspended"]
        )
        let card = try await store.setCardSuspended(id: id, isSuspended: input.isSuspended)
        let updatedRevision = try await self.revision(resourceType: "card", resourceID: id.uuidString)
        return try .json(
            APICard(card, revision: updatedRevision),
            headers: ["ETag": etag(updatedRevision)]
        )
    }

    private func resetCard(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let key = try requiredIdempotencyKey(request)
        let input = try APIJSON.decodeStrict(
            ResetCardInput.self,
            from: request.body,
            allowedKeys: ["confirm"]
        )
        guard input.confirm else {
            throw APIServiceError.validation("Card reset requires confirm=true.", pointer: "/confirm")
        }
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        let route = "POST /v1/cards/\(id.uuidString.lowercased())/resets"
        if case let .completed(_, status, body)? = try await store.idempotencyClaim(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        ) {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        let revision = try await revision(resourceType: "card", resourceID: id.uuidString)
        try requireIfMatch(request, revision: revision)
        let claim = try await store.claimIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash,
            resultResourceID: id.uuidString.lowercased()
        )
        if case let .completed(_, status, body) = claim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        let card = try await store.resetCardProgress(id: id)
        let updatedRevision = try await self.revision(resourceType: "card", resourceID: id.uuidString)
        let representation = APICard(card, revision: updatedRevision)
        let body = try APIJSON.encoder.encode(representation)
        try await store.completeIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash,
            status: 200,
            responseBody: body
        )
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "ETag": etag(updatedRevision),
            ],
            body: body
        )
    }

    func requiredIdempotencyKey(_ request: APIRequest) throws -> String {
        guard let key = request.header("idempotency-key"),
              !key.isEmpty, key.utf8.count <= 256
        else {
            throw APIServiceError.validation(
                "Idempotency-Key is required and may not exceed 256 UTF-8 bytes."
            )
        }
        return key
    }

    private func boolQuery(_ query: [String: [String]], key: String) throws -> Bool? {
        guard let value = query[key]?.first else { return nil }
        switch value {
        case "true": return true
        case "false": return false
        default:
            throw APIServiceError.validation("Expected true or false.", pointer: "/query/\(key)")
        }
    }

    private func parseDate(_ value: String, pointer: String) throws -> Date {
        guard let data = try? APIJSON.decoder.decode(Date.self, from: Data("\"\(value)\"".utf8)) else {
            throw APIServiceError.validation("Expected an RFC 3339 timestamp.", pointer: pointer)
        }
        return data
    }

    private func collectionRouteKey(path: String, query: [String: [String]]) -> String {
        let filters = query.filter { $0.key != "cursor" && $0.key != "limit" }
            .sorted { $0.key < $1.key }
            .flatMap { key, values in values.sorted().map { "\(key)=\($0)" } }
            .joined(separator: "&")
        return filters.isEmpty ? path : path + "?" + filters
    }

    private func encodedCursor(route: String, offset: Int) async throws -> String {
        try APICursor(
            route: route,
            offset: offset,
            libraryId: (try await store.libraryID()).uuidString.lowercased()
        ).encoded(secret: cursorSecret)
    }

    private func decodeCursor(_ value: String, route: String) async throws -> Int {
        try APICursor.decode(
            value,
            route: route,
            libraryId: (try await store.libraryID()).uuidString.lowercased(),
            secret: cursorSecret
        ).offset
    }

    private func listItemTypes(_ request: APIRequest) async throws -> APIResponse {
        try validateQuery(request.query, allowed: ["cursor", "limit"])
        let limit = try pageLimit(request.query)
        let catalog = try await store.loadItemTypeCatalog()
        var provenance: [UUID: String] = [:]
        for itemType in catalog.itemTypes { provenance[itemType.id] = "library" }
        for group in catalog.includedWithDecks {
            for itemType in group.itemTypes {
                provenance[itemType.id] = "deck:\(group.rootDeck.id.uuidString.lowercased())"
            }
        }
        let types = try await store.listItemTypes().sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
        let offset: Int
        if let cursor = request.query["cursor"]?.first {
            offset = try await decodeCursor(cursor, route: "/v1/item-types")
        } else { offset = 0 }
        guard offset <= types.count else { throw invalidCursor() }
        let end = min(offset + limit, types.count)
        var data: [APIItemType] = []
        for itemType in types[offset ..< end] {
            data.append(try await itemTypeRepresentation(
                itemType,
                provenance: provenance[itemType.id] ?? "library"
            ))
        }
        let next = end < types.count
            ? try await encodedCursor(route: "/v1/item-types", offset: end)
            : nil
        return try .json(APICollection(data: data, page: .init(nextCursor: next, limit: limit)))
    }

    private func createItemType(_ request: APIRequest) async throws -> APIResponse {
        let input = try decodeItemTypeInput(request.body)
        let id = try input.id.map { try parseUUID($0, pointer: "/id") } ?? UUID()
        if (try? await store.itemType(id: id)) != nil {
            throw APIServiceError.problem(
                status: 409,
                code: "resource_exists",
                title: "Resource already exists",
                detail: "The requested item-type identifier already exists."
            )
        }
        let itemType = try domainItemType(input, id: id)
        _ = try await store.createItemType(itemType)
        let representation = try await itemTypeRepresentation(itemType)
        return try .json(
            status: 201,
            representation,
            headers: [
                "ETag": etag(representation.revision),
                "Location": "/v1/item-types/\(representation.id)",
            ]
        )
    }

    private func validateItemType(_ request: APIRequest) async throws -> APIResponse {
        let input = try decodeItemTypeInput(request.body)
        let itemType = try domainItemType(
            input,
            id: try input.id.map { try parseUUID($0, pointer: "/id") } ?? UUID()
        )
        try ItemTypeValidation.validate(itemType)
        return APIResponse(status: 204)
    }

    private func getItemType(_ id: UUID) async throws -> APIResponse {
        let representation = try await itemTypeRepresentation(try await store.itemType(id: id))
        return try .json(representation, headers: ["ETag": etag(representation.revision)])
    }

    private func updateItemType(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let current = try await store.itemType(id: id)
        let currentRevision = try await revision(resourceType: "itemType", resourceID: id.uuidString)
        try requireIfMatch(request, revision: currentRevision)
        let input = try decodeItemTypeInput(request.body)
        if let inputID = input.id,
           try parseUUID(inputID, pointer: "/id") != id {
            throw APIServiceError.validation("The body id must match the route id.", pointer: "/id")
        }
        let proposed = try domainItemType(input, id: id)
        try ItemTypeValidation.validate(proposed)
        let requestHash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        if let impact = try await itemTypeImpact(from: current, to: proposed),
           impact.affectedItemCount > 0 || impact.affectedCardCount > 0 {
            let supplied = request.header("neoanki-impact-token")
            let cursor = try await store.currentChangeCursor()
            let valid = supplied.flatMap { impactAuthorizations[$0] }.map {
                $0.resourceID == id
                    && $0.requestHash == requestHash
                    && $0.changeCursor == cursor
                    && $0.expiresAt > .now
            } ?? false
            guard valid else {
                let token = try APICrypto.randomToken()
                impactAuthorizations[token] = ImpactAuthorization(
                    resourceID: id,
                    requestHash: requestHash,
                    changeCursor: cursor,
                    expiresAt: .now.addingTimeInterval(300)
                )
                throw APIServiceError.problem(
                    status: 409,
                    code: impact.affectedStudyResponseCount > 0
                        ? "study_response_deletion_confirmation_required"
                        : "impact_confirmation_required",
                    title: "Impact confirmation required",
                    detail: impact.affectedStudyResponseCount > 0
                        ? "This definition change will delete persistent spoken responses."
                        : "This definition change can remove or regenerate cards.",
                    impact: impact,
                    impactToken: token
                )
            }
            if let supplied { impactAuthorizations.removeValue(forKey: supplied) }
        }
        _ = try await store.updateItemType(proposed)
        let representation = try await itemTypeRepresentation(proposed)
        return try .json(representation, headers: ["ETag": etag(representation.revision)])
    }

    private func deleteItemType(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let currentRevision = try await revision(resourceType: "itemType", resourceID: id.uuidString)
        try requireIfMatch(request, revision: currentRevision)
        let count = try await store.countItems(itemTypeID: id)
        guard count == 0 else {
            throw APIServiceError.problem(
                status: 409,
                code: "resource_in_use",
                title: "Resource in use",
                detail: "Remove all items of this type before deleting it."
            )
        }
        guard try await store.deleteItemType(id: id) else {
            throw APIServiceError.notFound("The requested resource does not exist.")
        }
        return APIResponse(status: 204)
    }

    private func duplicateItemType(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            DuplicateItemTypeInput.self,
            from: request.body,
            allowedKeys: ["name"]
        )
        let copy = try await store.duplicateItemType(id: id, name: input.name)
        let representation = try await itemTypeRepresentation(copy)
        return try .json(
            status: 201,
            representation,
            headers: [
                "ETag": etag(representation.revision),
                "Location": "/v1/item-types/\(representation.id)",
            ]
        )
    }

    private func deckItemTypePolicy(_ id: UUID) async throws -> APIResponse {
        guard let policy = try await store.effectiveItemTypePolicy(for: id) else {
            return try .json(APIItemTypePolicy(
                sourceDeckId: nil,
                defaultItemTypeId: nil,
                itemTypeIds: []
            ))
        }
        return try .json(APIItemTypePolicy(
            sourceDeckId: policy.sourceDeckID.uuidString.lowercased(),
            defaultItemTypeId: policy.defaultItemTypeID?.uuidString.lowercased(),
            itemTypeIds: policy.itemTypes.map { $0.id.uuidString.lowercased() }
        ))
    }

    private func decodeItemTypeInput(_ body: Data) throws -> ItemTypeInput {
        try validateItemTypeInputShape(body)
        return try APIJSON.decodeStrict(
            ItemTypeInput.self,
            from: body,
            allowedKeys: ["id", "name", "fields", "templates"]
        )
    }

    private func domainItemType(_ input: ItemTypeInput, id: UUID) throws -> ItemType {
        ItemType(
            id: id,
            name: input.name,
            fields: try input.fields.enumerated().map {
                try $0.element.domain(parseUUID: parseUUID, pointer: "/fields/\($0.offset)")
            },
            templates: try input.templates.enumerated().map {
                try $0.element.domain(parseUUID: parseUUID, pointer: "/templates/\($0.offset)")
            }
        )
    }

    private func itemTypeRepresentation(
        _ itemType: ItemType,
        provenance: String = "library"
    ) async throws -> APIItemType {
        APIItemType(
            itemType,
            revision: try await revision(
                resourceType: "itemType", resourceID: itemType.id.uuidString
            ),
            itemCount: try await store.countItems(itemTypeID: itemType.id),
            provenance: provenance
        )
    }

    private func itemTypeImpact(
        from current: ItemType,
        to proposed: ItemType
    ) async throws -> APIImpactSummary? {
        let proposedFields = Dictionary(uniqueKeysWithValues: proposed.fields.map { ($0.id, $0) })
        let destructiveFields = Set(current.fields.compactMap { field -> UUID? in
            guard let replacement = proposedFields[field.id], replacement.type == field.type else {
                return field.id
            }
            return nil
        })
        let proposedTemplates = Set(proposed.templates.map(\.id))
        let removedTemplates = Set(current.templates.map(\.id)).subtracting(proposedTemplates)
        guard !destructiveFields.isEmpty || !removedTemplates.isEmpty else { return nil }
        let records = try await store.itemRecords().filter { $0.item.itemTypeID == current.id }
        let affectedItems = records.filter { record in
            !destructiveFields.isDisjoint(with: Set(record.item.fields.map(\.fieldID)))
        }
        let cards = try await store.cards()
        let affectedItemIDs = Set(affectedItems.map(\.id))
        let affectedCards = cards.filter {
            removedTemplates.contains($0.templateID) || affectedItemIDs.contains($0.itemID)
        }
        return APIImpactSummary(
            affectedItemCount: affectedItems.count,
            affectedCardCount: affectedCards.count,
            affectedStudyResponseCount: try await store.studyResponseCount(
                cardIDs: Set(affectedCards.map(\.id))
            )
        )
    }

    private func requireStudyResponseDeletionConfirmation(
        resourceID: UUID,
        requestHash: String,
        suppliedToken: String?,
        impact: APIImpactSummary
    ) async throws {
        let cursor = try await store.currentChangeCursor()
        let valid = suppliedToken.flatMap { impactAuthorizations[$0] }.map {
            $0.resourceID == resourceID
                && $0.requestHash == requestHash
                && $0.changeCursor == cursor
                && $0.expiresAt > .now
        } ?? false
        guard valid else {
            let token = try APICrypto.randomToken()
            impactAuthorizations[token] = ImpactAuthorization(
                resourceID: resourceID,
                requestHash: requestHash,
                changeCursor: cursor,
                expiresAt: .now.addingTimeInterval(300)
            )
            throw APIServiceError.problem(
                status: 409,
                code: "study_response_deletion_confirmation_required",
                title: "Saved response deletion confirmation required",
                detail: "This change will permanently delete persistent spoken responses.",
                impact: impact,
                impactToken: token
            )
        }
        if let suppliedToken { impactAuthorizations.removeValue(forKey: suppliedToken) }
    }

    private func createImportJob(_ request: APIRequest) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        try validateImportManifestShape(request.body)
        let input = try APIJSON.decodeStrict(
            CreateImportJobInput.self,
            from: request.body,
            allowedKeys: [
                "format", "itemTypeId", "csvItemTypeName", "destinationDeckId", "files",
            ]
        )
        guard !input.files.isEmpty, input.files.count <= 1_000 else {
            throw APIServiceError.validation("An import must declare between 1 and 1000 files.")
        }
        let declaredTotal = input.files.reduce(into: Int64(0)) { total, file in
            total = total.addingReportingOverflow(Int64(file.byteSize)).partialValue
        }
        guard declaredTotal >= 0, declaredTotal <= Int64(Self.maximumStagedImportBytes) else {
            throw APIServiceError.problem(
                status: 413,
                code: "payload_too_large",
                title: "Payload too large",
                detail: "Declared import files may not exceed \(Self.maximumStagedImportBytes) bytes in total."
            )
        }
        var paths: Set<String> = []
        var files: [ImportFileRecord] = []
        for (index, file) in input.files.enumerated() {
            try validateImportRelativePath(file.relativePath, pointer: "/files/\(index)/relativePath")
            guard paths.insert(file.relativePath).inserted,
                  file.byteSize >= 0,
                  file.sha256.count == 64,
                  file.sha256 == file.sha256.lowercased(),
                  file.sha256.allSatisfy({ $0.isHexDigit })
            else {
                throw APIServiceError.validation(
                    "Import file declarations must have unique safe paths, non-negative sizes, and lowercase SHA-256 digests.",
                    pointer: "/files/\(index)"
                )
            }
            files.append(.init(
                id: UUID(),
                relativePath: file.relativePath,
                byteSize: file.byteSize,
                sha256: file.sha256,
                data: nil
            ))
        }
        if input.format != .authoredDeck, files.count != 1 {
            throw APIServiceError.validation("This import format requires exactly one file.")
        }
        let now = Date.now
        let id = UUID()
        let record = ImportJobRecord(
            id: id,
            revision: 1,
            format: input.format,
            itemTypeID: try input.itemTypeId.map { try parseUUID($0, pointer: "/itemTypeId") },
            csvItemTypeName: input.csvItemTypeName,
            destinationDeckID: try input.destinationDeckId.map {
                try parseUUID($0, pointer: "/destinationDeckId")
            },
            state: "uploading",
            files: files,
            report: nil,
            planToken: nil,
            dependencyCursor: nil,
            committedChangeCursor: nil,
            createdAt: now,
            updatedAt: now
        )
        importJobs[id] = record
        try await persistTransferState()
        return try .json(
            status: 201,
            importRepresentation(record),
            headers: [
                "Location": "/v1/imports/\(id.uuidString.lowercased())",
                "ETag": etag(record.revision),
            ]
        )
    }

    private func putImportFile(
        jobID: UUID,
        fileID: UUID,
        request: APIRequest
    ) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard var job = importJobs[jobID],
              let index = job.files.firstIndex(where: { $0.id == fileID })
        else { throw APIServiceError.notFound("The import file does not exist.") }
        try requireIfMatch(request, revision: job.revision)
        guard ["uploading", "failed"].contains(job.state) else {
            throw APIServiceError.problem(
                status: 409, code: "job_state_conflict", title: "Job state conflict",
                detail: "Files cannot be replaced in the current job state."
            )
        }
        let declaration = job.files[index]
        guard request.body.count == declaration.byteSize,
              APICrypto.sha256Hex(request.body) == declaration.sha256
        else {
            throw APIServiceError.validation("Uploaded bytes do not match the declared size and SHA-256.")
        }
        job.files[index].data = request.body
        job.state = "uploading"
        job.planToken = nil
        job.dependencyCursor = nil
        job.report = nil
        job.updatedAt = .now
        job.revision += 1
        importJobs[jobID] = job
        try await persistTransferState()
        return APIResponse(status: 204, headers: ["ETag": etag(job.revision)])
    }

    private func validateImportJob(_ id: UUID) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard var job = importJobs[id] else {
            throw APIServiceError.notFound("The import job does not exist.")
        }
        guard job.files.allSatisfy({ $0.data != nil }) else {
            throw APIServiceError.problem(
                status: 409, code: "upload_incomplete", title: "Upload incomplete",
                detail: "Every declared import file must be uploaded before validation."
            )
        }
        job.state = "validating"
        job.updatedAt = .now
        importJobs[id] = job
        try await persistTransferState()
        do {
            let report = try await inspectImport(job)
            let cursor = try await store.currentChangeCursor()
            let digestList = job.files.sorted { $0.id.uuidString < $1.id.uuidString }
                .map(\.sha256).joined(separator: "|")
            let token = APICrypto.sha256Hex(
                Data("\(id.uuidString)|\(cursor)|\(digestList)|\(UUID().uuidString)".utf8)
            )
            job.state = "ready"
            job.report = report
            job.planToken = token
            job.dependencyCursor = cursor
            job.updatedAt = .now
            job.revision += 1
            importJobs[id] = job
            try await persistTransferState()
            return try .json(
                importRepresentation(job), headers: ["ETag": etag(job.revision)]
            )
        } catch {
            job.state = "failed"
            job.updatedAt = .now
            job.revision += 1
            importJobs[id] = job
            try? await persistTransferState()
            throw error
        }
    }

    private func inspectImport(_ job: ImportJobRecord) async throws -> APITransferReport {
        guard let primary = job.files.first?.data else {
            throw APIServiceError.validation("The import upload is incomplete.")
        }
        switch job.format {
        case .json:
            let payload = try JSONImportAdapter().parse(primary)
            let type = try await resolvedImportType(id: job.itemTypeID, name: payload.itemTypeName)
            try validateSimpleImportRows(payload.rows, itemType: type)
            return .init(
                itemCount: payload.rows.count, deckCount: 0,
                createdItemTypeCount: 0, reusedItemTypeCount: 1, warnings: []
            )
        case .csv:
            guard let name = job.csvItemTypeName, !name.isEmpty else {
                throw APIServiceError.validation("csvItemTypeName is required for CSV imports.")
            }
            let payload = try CSVImportAdapter(itemTypeName: name).parse(primary)
            let type = try await resolvedImportType(id: job.itemTypeID, name: name)
            try validateSimpleImportRows(payload.rows, itemType: type)
            return .init(
                itemCount: payload.rows.count, deckCount: 0,
                createdItemTypeCount: 0, reusedItemTypeCount: 1, warnings: []
            )
        case .authoredDeck:
            return try await withStagedImport(job) { directory async throws in
                try await withTransferValidationStore { validationStore in
                    let result: PortableDeckImportResult
                    if let deckID = job.destinationDeckID {
                        result = try await validationStore.importAuthoredItems(
                            from: directory,
                            into: deckID
                        )
                    } else {
                        result = try await validationStore.importAuthoredDeck(from: directory)
                    }
                    return transferReport(result)
                }
            }
        case .portableDeck:
            return try await withStagedImport(job, primaryExtension: "neodeck") {
                source async throws in
                try await withTransferValidationStore { validationStore in
                    transferReport(
                        try await validationStore.importPortableDeck(
                            from: source,
                            conflictResolution: .reject
                        )
                    )
                }
            }
        }
    }

    private func commitImportJob(
        _ id: UUID,
        request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CommitImportJobInput.self,
            from: request.body,
            allowedKeys: ["planToken"]
        )
        let key = try requiredIdempotencyKey(request)
        let route = "POST /v1/imports/\(id.uuidString.lowercased())/commits"
        let hash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        let existingClaim = try await store.idempotencyClaim(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: hash
        )
        if case let .completed(_, status, body)? = existingClaim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"], body: body
            )
        }
        try await ensureTransferStateLoaded()
        guard var job = importJobs[id] else {
            throw APIServiceError.notFound("The import job does not exist.")
        }
        let currentCursor = try await store.currentChangeCursor()
        let resumesPendingCommit: Bool
        if case .pending? = existingClaim { resumesPendingCommit = true }
        else { resumesPendingCommit = false }

        if resumesPendingCommit, job.state == "completed" {
            return try await completeRecoveredImport(
                job: job, grant: grant, route: route, key: key, requestHash: hash
            )
        }
        if resumesPendingCommit, job.state == "committing",
           job.committedChangeCursor != nil
        {
            job.state = "completed"
            job.updatedAt = .now
            job.revision += 1
            importJobs[id] = job
            try await persistTransferState()
            return try await completeRecoveredImport(
                job: job, grant: grant, route: route, key: key, requestHash: hash
            )
        }

        try requireIfMatch(request, revision: job.revision)
        guard (job.state == "ready" || resumesPendingCommit && job.state == "committing"),
              job.planToken == input.planToken,
              job.dependencyCursor == currentCursor
        else {
            throw APIServiceError.problem(
                status: 412, code: "plan_invalidated", title: "Plan invalidated",
                detail: "The import plan or a destination dependency changed."
            )
        }
        let claim = try await store.claimIdempotency(
            clientID: grant.id, route: route, key: key, requestHash: hash
        )
        if case let .completed(_, status, body) = claim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"], body: body
            )
        }
        job.state = "committing"
        job.updatedAt = .now
        importJobs[id] = job
        try await persistTransferState()
        do {
            if faultInjector.simulatesProcessExit(at: .importBeforeDomainCommit) {
                throw SimulatedAPIProcessExit()
            }
            let report = try await performImport(job)
            job.committedChangeCursor = try await store.currentChangeCursor()
            job.report = report
            job.updatedAt = .now
            importJobs[id] = job
            try await persistTransferState()
            if faultInjector.simulatesProcessExit(at: .importAfterDomainCommit) {
                throw SimulatedAPIProcessExit()
            }
            job.state = "completed"
            job.updatedAt = .now
            job.revision += 1
            importJobs[id] = job
            try await persistTransferState()
            if faultInjector.simulatesProcessExit(at: .importAfterCompletedJobPersisted) {
                throw SimulatedAPIProcessExit()
            }
            return try await completeRecoveredImport(
                job: job, grant: grant, route: route, key: key, requestHash: hash
            )
        } catch let error as SimulatedAPIProcessExit {
            throw error
        } catch {
            job.state = "failed"
            job.updatedAt = .now
            job.revision += 1
            importJobs[id] = job
            try? await persistTransferState()
            throw error
        }
    }

    private func completeRecoveredImport(
        job: ImportJobRecord,
        grant: APIClientGrant,
        route: String,
        key: String,
        requestHash: String
    ) async throws -> APIResponse {
        let body = try APIJSON.encoder.encode(importRepresentation(job))
        let changeCursor: Int64
        if let committedChangeCursor = job.committedChangeCursor {
            changeCursor = committedChangeCursor
        } else {
            changeCursor = try await store.currentChangeCursor()
        }
        try await store.completeIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: requestHash,
            status: 200,
            responseBody: body
        )
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "ETag": etag(job.revision),
                "X-NeoAnki-Change-Cursor": String(changeCursor),
            ],
            body: body
        )
    }

    private func performImport(_ job: ImportJobRecord) async throws -> APITransferReport {
        guard let primary = job.files.first?.data else {
            throw APIServiceError.validation("The import upload is incomplete.")
        }
        switch job.format {
        case .json:
            let imported = try await store.importJSONItems(
                from: primary,
                itemTypeID: job.itemTypeID,
                context: ImportContext(),
                asOf: .now
            )
            return .init(
                itemCount: imported.count, deckCount: 0, createdItemTypeCount: 0,
                reusedItemTypeCount: 1, warnings: []
            )
        case .csv:
            guard let name = job.csvItemTypeName else {
                throw APIServiceError.validation("csvItemTypeName is required for CSV imports.")
            }
            let imported = try await store.importCSVItems(
                from: primary,
                itemTypeID: job.itemTypeID,
                itemTypeName: name,
                context: ImportContext(),
                asOf: .now
            )
            return .init(
                itemCount: imported.count, deckCount: 0, createdItemTypeCount: 0,
                reusedItemTypeCount: 1, warnings: []
            )
        case .authoredDeck:
            return try await withStagedImport(job) { directory async throws in
                let result: PortableDeckImportResult
                if let deckID = job.destinationDeckID {
                    result = try await store.importAuthoredItems(from: directory, into: deckID)
                } else {
                    result = try await store.importAuthoredDeck(from: directory)
                }
                return transferReport(result)
            }
        case .portableDeck:
            return try await withStagedImport(job, primaryExtension: "neodeck") {
                source async throws in
                transferReport(try await store.importPortableDeck(
                    from: source,
                    conflictResolution: .reject
                ))
            }
        }
    }

    private func createExportJob(
        _ request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let input = try APIJSON.decodeStrict(
            CreateExportJobInput.self,
            from: request.body,
            allowedKeys: ["format", "deckId"]
        )
        guard input.format == "portableDeck" else {
            throw APIServiceError.validation("Version 1 exports only portableDeck.", pointer: "/format")
        }
        let deckID = try parseUUID(input.deckId, pointer: "/deckId")
        let key = try optionalIdempotencyKey(request)
        let route = "POST /v1/exports"
        let requestHash = try APIJSON.canonicalRequestHash(
            method: request.method, path: request.path, body: request.body
        )
        if let key,
           case let .completed(_, status, body)? = try await store.idempotencyClaim(
               clientID: grant.id,
               route: route,
               key: key,
               requestHash: requestHash
           )
        {
            let recovered = try APIJSON.decoder.decode(APIExportJob.self, from: body)
            return APIResponse(
                status: status,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Location": "/v1/exports/\(recovered.id)",
                    "ETag": etag(recovered.revision),
                ],
                body: body
            )
        }
        try await ensureTransferStateLoaded()
        _ = try await store.deck(id: deckID)

        let generatedID = UUID()
        let claim: IdempotencyClaim?
        if let key {
            claim = try await store.claimIdempotency(
                clientID: grant.id,
                route: route,
                key: key,
                requestHash: requestHash,
                resultResourceID: generatedID.uuidString.lowercased()
            )
        } else {
            claim = nil
        }
        let resultIDText: String?
        switch claim {
        case let .claimed(id)?, let .pending(id)?: resultIDText = id
        case .completed?, nil: resultIDText = nil
        }
        let id = try parseUUID(
            resultIDText ?? generatedID.uuidString.lowercased(), pointer: "/id"
        )
        if let existing = exportJobs[id] {
            guard existing.deckID == deckID else {
                throw APIServiceError.problem(
                    status: 409,
                    code: "idempotency_conflict",
                    title: "Idempotency conflict",
                    detail: "The export idempotency key identifies different input."
                )
            }
            if existing.state == "completed" {
                return try await completeExportCreation(
                    existing,
                    grant: grant,
                    route: route,
                    key: key,
                    requestHash: requestHash
                )
            }
            return try await performExport(
                existing,
                grant: grant,
                route: route,
                key: key,
                requestHash: requestHash
            )
        }
        let now = Date.now
        let job = ExportJobRecord(
            id: id, revision: 1, deckID: deckID, state: "pending", bytes: nil,
            createdAt: now, updatedAt: now
        )
        exportJobs[id] = job
        try await persistTransferState()
        if faultInjector.simulatesProcessExit(at: .exportAfterPendingJobPersisted) {
            throw SimulatedAPIProcessExit()
        }
        return try await performExport(
            job,
            grant: grant,
            route: route,
            key: key,
            requestHash: requestHash
        )
    }

    private func performExport(
        _ pendingJob: ExportJobRecord,
        grant: APIClientGrant,
        route: String,
        key: String?,
        requestHash: String
    ) async throws -> APIResponse {
        var job = pendingJob
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-api-export-\(job.id.uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("export.neodeck")
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await store.exportPortableDeck(id: job.deckID, to: destination)
            job.bytes = try Data(contentsOf: destination)
            if faultInjector.simulatesProcessExit(at: .exportAfterOutputGenerated) {
                throw SimulatedAPIProcessExit()
            }
            job.state = "completed"
            job.updatedAt = .now
            job.revision += 1
            exportJobs[job.id] = job
            try await persistTransferState()
            if faultInjector.simulatesProcessExit(at: .exportAfterCompletedJobPersisted) {
                throw SimulatedAPIProcessExit()
            }
            return try await completeExportCreation(
                job,
                grant: grant,
                route: route,
                key: key,
                requestHash: requestHash
            )
        } catch let error as SimulatedAPIProcessExit {
            throw error
        } catch {
            job.state = "failed"
            job.updatedAt = .now
            job.revision += 1
            exportJobs[job.id] = job
            try? await persistTransferState()
            throw error
        }
    }

    private func completeExportCreation(
        _ job: ExportJobRecord,
        grant: APIClientGrant,
        route: String,
        key: String?,
        requestHash: String
    ) async throws -> APIResponse {
        let representation = exportRepresentation(job)
        let body = try APIJSON.encoder.encode(representation)
        if let key {
            try await store.completeIdempotency(
                clientID: grant.id,
                route: route,
                key: key,
                requestHash: requestHash,
                status: 201,
                responseBody: body
            )
        }
        return APIResponse(
            status: 201,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Location": "/v1/exports/\(job.id.uuidString.lowercased())",
                "ETag": etag(job.revision),
            ],
            body: body
        )
    }

    private func getImportJob(_ id: UUID) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard let job = importJobs[id] else {
            throw APIServiceError.notFound("The import job does not exist.")
        }
        return try .json(
            importRepresentation(job), headers: ["ETag": etag(job.revision)]
        )
    }

    private func deleteImportJob(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard let job = importJobs[id] else {
            throw APIServiceError.notFound("The import job does not exist.")
        }
        try requireIfMatch(request, revision: job.revision)
        importJobs.removeValue(forKey: id)
        try await persistTransferState()
        return APIResponse(status: 204)
    }

    private func getExportJob(_ id: UUID) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard let job = exportJobs[id] else {
            throw APIServiceError.notFound("The export job does not exist.")
        }
        return try .json(
            exportRepresentation(job), headers: ["ETag": etag(job.revision)]
        )
    }

    private func getExportContent(_ id: UUID) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard let job = exportJobs[id], job.state == "completed", let bytes = job.bytes else {
            throw APIServiceError.notFound("Completed export content does not exist.")
        }
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": "application/vnd.neoanki.portable-deck",
                "Content-Disposition": "attachment; filename=\"neoanki-export.neodeck\"",
                "ETag": etag(job.revision),
            ],
            body: bytes
        )
    }

    private func deleteExportJob(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        try await ensureTransferStateLoaded()
        guard let job = exportJobs[id] else {
            throw APIServiceError.notFound("The export job does not exist.")
        }
        try requireIfMatch(request, revision: job.revision)
        exportJobs.removeValue(forKey: id)
        try await persistTransferState()
        return APIResponse(status: 204)
    }

    private func ensureTransferStateLoaded() async throws {
        if !transferStateLoaded {
            let stateURL = await store.apiTransferStateURL()
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
                let decoded = try PropertyListDecoder().decode(TransferState.self, from: data)
                importJobs = Dictionary(uniqueKeysWithValues: decoded.imports.map { ($0.id, $0) })
                exportJobs = Dictionary(uniqueKeysWithValues: decoded.exports.map { ($0.id, $0) })
            }
            transferStateLoaded = true
        }
        let cutoff = Date.now.addingTimeInterval(-transferJobLifetime)
        let expiredImportIDs = importJobs.values.filter { $0.updatedAt <= cutoff }.map(\.id)
        let expiredExportIDs = exportJobs.values.filter { $0.updatedAt <= cutoff }.map(\.id)
        guard !expiredImportIDs.isEmpty || !expiredExportIDs.isEmpty else { return }
        expiredImportIDs.forEach { importJobs.removeValue(forKey: $0) }
        expiredExportIDs.forEach { exportJobs.removeValue(forKey: $0) }
        try await persistTransferState()
    }

    private func persistTransferState() async throws {
        let stateURL = await store.apiTransferStateURL()
        let directory = stateURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let state = TransferState(
            imports: importJobs.values.sorted { $0.id.uuidString < $1.id.uuidString },
            exports: exportJobs.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        transferStateLoaded = true
    }

    private func withTransferValidationStore<T: Sendable>(
        _ operation: (any LocalAPILibrary) async throws -> T
    ) async throws -> T {
        let temporary = try await store.makeValidationLibrary()
        return try await operation(temporary.library)
    }

    private func importRepresentation(_ job: ImportJobRecord) -> APIImportJob {
        APIImportJob(
            id: job.id.uuidString.lowercased(), revision: job.revision,
            format: job.format.rawValue,
            state: job.state,
            files: job.files.map {
                APIImportFile(
                    id: $0.id.uuidString.lowercased(), relativePath: $0.relativePath,
                    byteSize: $0.byteSize, sha256: $0.sha256, uploaded: $0.data != nil
                )
            },
            report: job.report, planToken: job.planToken,
            createdAt: job.createdAt, updatedAt: job.updatedAt
        )
    }

    private func exportRepresentation(_ job: ExportJobRecord) -> APIExportJob {
        APIExportJob(
            id: job.id.uuidString.lowercased(), revision: job.revision,
            format: "portableDeck",
            deckId: job.deckID.uuidString.lowercased(), state: job.state,
            byteSize: job.bytes?.count, sha256: job.bytes.map(APICrypto.sha256Hex),
            createdAt: job.createdAt, updatedAt: job.updatedAt
        )
    }

    private func validateImportRelativePath(_ path: String, pointer: String) throws {
        let components = NSString(string: path).pathComponents
        guard !path.isEmpty, !NSString(string: path).isAbsolutePath,
              !components.contains(".."), !components.contains("."),
              !path.contains("\\"), !path.hasPrefix("~"), path.utf8.count <= 1_024
        else { throw APIServiceError.validation("Import paths must be safe relative paths.", pointer: pointer) }
    }

    private func resolvedImportType(id: UUID?, name: String) async throws -> ItemType {
        if let id { return try await store.itemType(id: id) }
        guard let type = try await store.listItemTypes().first(where: { $0.name == name }) else {
            throw ImportError.itemTypeNotFound(name)
        }
        return type
    }

    private func validateSimpleImportRows(_ rows: [ImportRow], itemType: ItemType) throws {
        let names = Set(itemType.fields.map(\.name))
        for row in rows {
            let supplied = Set(row.fieldValues.keys).union(row.structuredFields.keys)
            guard supplied.isSubset(of: names) else {
                throw ImportError.unknownField(supplied.subtracting(names).sorted().first ?? "unknown")
            }
            for field in itemType.fields where field.isRequired {
                let text = row.fieldValues[field.name]
                let structured = row.structuredFields[field.name]
                guard text?.isEmpty == false || structured != nil else {
                    throw DatabaseError.requiredFieldEmpty(field.name)
                }
            }
        }
    }

    private func transferReport(_ result: PortableDeckImportResult) -> APITransferReport {
        APITransferReport(
            itemCount: result.itemCount, deckCount: result.deckIDs.count,
            createdItemTypeCount: result.createdItemTypeCount,
            reusedItemTypeCount: result.reusedItemTypeCount, warnings: []
        )
    }

    private func withStagedImport<Result: Sendable>(
        _ job: ImportJobRecord,
        primaryExtension: String? = nil,
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neoanki-api-import-\(UUID().uuidString)"
                    + (job.format == .authoredDeck ? ".neoanki" : ""),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let primaryExtension, let data = job.files.first?.data {
            let source = directory.appendingPathComponent("source.\(primaryExtension)")
            try data.write(to: source, options: [.atomic])
            return try body(source)
        }
        for file in job.files {
            guard let data = file.data else { throw APIServiceError.validation("Upload incomplete.") }
            let url = directory.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        }
        return try body(directory)
    }

    private func withStagedImport<Result>(
        _ job: ImportJobRecord,
        primaryExtension: String? = nil,
        _ body: (URL) async throws -> Result
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neoanki-api-import-\(UUID().uuidString)"
                    + (job.format == .authoredDeck ? ".neoanki" : ""),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let primaryExtension, let data = job.files.first?.data {
            let source = directory.appendingPathComponent("source.\(primaryExtension)")
            try data.write(to: source, options: [.atomic])
            return try await body(source)
        }
        for file in job.files {
            guard let data = file.data else { throw APIServiceError.validation("Upload incomplete.") }
            let url = directory.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        }
        return try await body(directory)
    }

    private func uploadMedia(
        _ request: APIRequest,
        grant: APIClientGrant
    ) async throws -> APIResponse {
        let key = try requiredIdempotencyKey(request)
        guard let kindText = request.header("neoanki-media-kind"),
              let kind = MediaKind(rawValue: kindText)
        else {
            throw APIServiceError.validation(
                "NeoAnki-Media-Kind must declare audio, image, gif, or video."
            )
        }
        guard request.body.count <= MediaValidation.maxBytes(for: kind) else {
            throw APIServiceError.problem(
                status: 413,
                code: "payload_too_large",
                title: "Payload too large",
                detail: "The upload exceeds the limit for this media kind."
            )
        }
        let altText = request.header("neoanki-alt-text")
        var hashInput = Data("POST\n/v1/media\n\(kind.rawValue)\n\(altText ?? "")\n".utf8)
        hashInput.append(request.body)
        let requestHash = APICrypto.sha256Hex(hashInput)
        let route = "POST /v1/media"
        if case let .completed(_, status, body)? = try await store.idempotencyClaim(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: requestHash
        ) {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        _ = try MediaValidation.inferredExtension(
            data: request.body,
            expectedKind: kind
        )
        let generatedReservationID = UUID()
        let claim = try await store.claimIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: requestHash,
            resultResourceID: generatedReservationID.uuidString.lowercased()
        )
        if case let .completed(_, status, body) = claim {
            return APIResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        }
        let reservationIDText: String?
        switch claim {
        case let .claimed(id), let .pending(id): reservationIDText = id
        case .completed: reservationIDText = nil
        }
        let reservationID = try parseUUID(
            reservationIDText ?? generatedReservationID.uuidString.lowercased(),
            pointer: "/reservationId"
        )
        let reserved = try await store.reserveMedia(
            data: request.body,
            kind: kind,
            altText: altText,
            reservationID: reservationID
        )
        if faultInjector.simulatesProcessExit(at: .mediaAfterReservation) {
            throw SimulatedAPIProcessExit()
        }
        let representation = APIMediaReservation(reserved)
        let body = try APIJSON.encoder.encode(representation)
        try await store.completeIdempotency(
            clientID: grant.id,
            route: route,
            key: key,
            requestHash: requestHash,
            status: 201,
            responseBody: body
        )
        return APIResponse(
            status: 201,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Location": "/v1/media/\(representation.assetHash)",
            ],
            body: body
        )
    }

    private func downloadMedia(
        _ hash: String,
        headOnly: Bool,
        request: APIRequest
    ) async throws -> APIResponse {
        if request.header("range") != nil {
            throw APIServiceError.problem(
                status: 416,
                code: "range_not_supported",
                title: "Range not supported",
                detail: "This API version does not support media range requests.",
                headers: ["Accept-Ranges": "none"]
            )
        }
        let isResponseHash = try await store.isStudyResponseMediaHash(hash)
        let ordinaryReferenceCount = try await store.ordinaryMediaReferenceCount(hash: hash)
        let responsePrivate = isResponseHash && ordinaryReferenceCount == 0
        guard try await store.mediaAsset(hash: hash) != nil, !responsePrivate else {
            throw APIServiceError.notFound("The requested resource does not exist.")
        }
        let (asset, bytes) = try await store.mediaBytes(hash: hash)
        let contentType: String
        switch asset.kind {
        case .audio:
            contentType = switch asset.fileExtension {
            case "mp3": "audio/mpeg"
            case "m4a": "audio/mp4"
            default: "audio/\(asset.fileExtension)"
            }
        case .image: contentType = asset.fileExtension == "jpg" || asset.fileExtension == "jpeg"
            ? "image/jpeg" : "image/\(asset.fileExtension)"
        case .gif: contentType = "image/gif"
        case .video:
            contentType = asset.fileExtension == "mov"
                ? "video/quicktime" : "video/\(asset.fileExtension)"
        }
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": contentType,
                "Content-Disposition": "attachment; filename=\"\(hash).\(asset.fileExtension)\"",
                "Accept-Ranges": "none",
                "Content-Length": String(bytes.count),
            ],
            body: headOnly ? Data() : bytes
        )
    }

    private func mediaMetadata(_ hash: String) async throws -> APIResponse {
        let isResponseHash = try await store.isStudyResponseMediaHash(hash)
        let ordinaryReferenceCount = try await store.ordinaryMediaReferenceCount(hash: hash)
        let responsePrivate = isResponseHash && ordinaryReferenceCount == 0
        guard let asset = try await store.mediaAsset(hash: hash), !responsePrivate else {
            throw APIServiceError.notFound("The requested resource does not exist.")
        }
        return try .json(APIMediaMetadata(asset))
    }

    private func validateMediaHash(_ value: String) throws -> String {
        guard value.count == 64,
              value == value.lowercased(),
              value.allSatisfy({ $0.isHexDigit })
        else {
            throw APIServiceError.validation(
                "Expected a lowercase SHA-256 digest.", pointer: "/sha256"
            )
        }
        return value
    }

    private func deckRepresentations() async throws -> [APIDeck] {
        let decks = try await store.listDecks()
        let summaries = try await store.deckSummaries()
        let summariesByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let directCounts = Dictionary(
            grouping: try await store.items(),
            by: \.deckID
        ).mapValues(\.count)
        let children = Dictionary(grouping: decks, by: \.parentID)
        var result: [APIDeck] = []
        result.reserveCapacity(decks.count)
        for deck in decks {
            let resourceID = deck.id.uuidString
            let revision = try await revision(resourceType: "deck", resourceID: resourceID)
            let summary = summariesByID[deck.id]
            result.append(
                APIDeck(
                    id: deck.id.uuidString.lowercased(),
                    revision: revision,
                    name: deck.name,
                    parentId: deck.parentID?.uuidString.lowercased(),
                    newCardsPerDay: deck.newCardsPerDay,
                    directItemCount: directCounts[Optional(deck.id), default: 0],
                    recursiveItemCount: summary?.itemCount ?? 0,
                    dueCount: summary?.dueCount ?? 0,
                    childIds: (children[deck.id] ?? [])
                        .map { $0.id.uuidString.lowercased() }
                        .sorted()
                )
            )
        }
        return result.sorted {
            let order = $0.name.compare(
                $1.name,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func revision(resourceType: String, resourceID: String) async throws -> Int {
        let candidates = [resourceID, resourceID.uppercased(), resourceID.lowercased()]
        for candidate in candidates {
            if let revision = try await store.resourceRevision(
                resourceType: resourceType,
                resourceID: candidate
            ), !revision.isDeleted {
                return revision.revision
            }
        }
        throw APIServiceError.notFound("The requested resource does not exist.")
    }

    private func require(_ grant: APIClientGrant, scope: APIScope) throws {
        guard grant.scopes.contains(scope) else {
            throw APIServiceError.problem(
                status: 403,
                code: "insufficient_scope",
                title: "Insufficient scope",
                detail: "This operation requires \(scope.rawValue).",
                requiredScope: scope.rawValue
            )
        }
    }

    private func require(
        _ grant: APIClientGrant,
        endpoint: APIEndpointDefinition
    ) throws {
        guard let expression = endpoint.requiredScope, expression != "any" else {
            return
        }
        let alternatives = expression.components(separatedBy: " or ")
        let scopes = alternatives.compactMap(APIScope.init(rawValue:))
        guard scopes.count == alternatives.count,
              scopes.contains(where: grant.scopes.contains) else {
            throw APIServiceError.problem(
                status: 403,
                code: "insufficient_scope",
                title: "Insufficient scope",
                detail: "This operation requires \(expression).",
                requiredScope: expression
            )
        }
    }

    private func requireChangeRead(_ grant: APIClientGrant) throws {
        guard grant.scopes.contains(.libraryRead)
                || grant.scopes.contains(.studyResponsesRead)
        else {
            throw APIServiceError.problem(
                status: 403,
                code: "insufficient_scope",
                title: "Insufficient scope",
                detail: "This operation requires library.read or study.responses.read.",
                requiredScope: "library.read or study.responses.read"
            )
        }
    }

    func requireIfMatch(_ request: APIRequest, revision: Int) throws {
        guard let value = request.header("if-match") else {
            throw APIServiceError.problem(
                status: 428,
                code: "precondition_required",
                title: "Precondition required",
                detail: "If-Match is required for this operation."
            )
        }
        guard value == etag(revision) else {
            throw APIServiceError.problem(
                status: 412,
                code: "revision_conflict",
                title: "Revision conflict",
                detail: "The resource changed after the client read it."
            )
        }
    }

    private func requireIfMatch(_ request: APIRequest, revision: Int64) throws {
        guard let value = request.header("if-match") else {
            throw APIServiceError.problem(
                status: 428,
                code: "precondition_required",
                title: "Precondition required",
                detail: "This operation requires an If-Match revision."
            )
        }
        guard value == etag(revision) else {
            throw APIServiceError.problem(
                status: 412,
                code: "revision_conflict",
                title: "Revision conflict",
                detail: "The resource changed after it was read."
            )
        }
    }

    func etag(_ revision: Int) -> String { "\"revision-\(revision)\"" }
    private func etag(_ revision: Int64) -> String { "\"revision-\(revision)\"" }

    private func pageLimit(_ query: [String: [String]]) throws -> Int {
        guard let value = query["limit"]?.first else { return 50 }
        guard let limit = Int(value), (1 ... 200).contains(limit) else {
            throw APIServiceError.validation("Collection limit must be between 1 and 200.")
        }
        return limit
    }

    private func changeLimit(_ query: [String: [String]]) throws -> Int {
        guard let value = query["limit"]?.first else { return 1_000 }
        guard let limit = Int(value), (1 ... 1_000).contains(limit) else {
            throw APIServiceError.validation("Change limit must be between 1 and 1000.")
        }
        return limit
    }

    private func validateQuery(_ query: [String: [String]], allowed: Set<String>) throws {
        if let unknown = Set(query.keys).subtracting(allowed).sorted().first {
            throw APIServiceError.validation(
                "Unknown query parameter.",
                pointer: "/query/\(unknown)",
                fieldCode: "unknown_member"
            )
        }
        if let duplicate = query.sorted(by: { $0.key < $1.key }).first(where: {
            $0.value.count != 1 && $0.key != "tag"
        }) {
            throw APIServiceError.validation(
                "This query parameter may appear only once.",
                pointer: "/query/\(duplicate.key)",
                fieldCode: "duplicate_member"
            )
        }
    }

    private func rejectUndocumentedBody(_ request: APIRequest) throws {
        guard request.body.isEmpty || APIOpenAPI.acceptsRequestBody(
            for: request.path,
            method: request.method
        ) else {
            throw APIServiceError.validation(
                "This operation does not accept a request body.",
                pointer: "/body"
            )
        }
    }

    private func validateDeckName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1_024 else {
            throw APIServiceError.validation(
                "Deck name must be 1 to 1024 UTF-8 bytes.",
                pointer: "/name"
            )
        }
        return name
    }

    func parseUUID(_ value: String, pointer: String) throws -> UUID {
        guard value == value.lowercased(), let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value
        else {
            throw APIServiceError.validation(
                "Expected a lowercase hyphenated UUID.",
                pointer: pointer,
                fieldCode: "invalid_uuid"
            )
        }
        return id
    }

    private func validateOriginSyntax(_ value: String) throws {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "chrome-extension", "moz-extension", "safari-web-extension"]
                .contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              value != "null"
        else {
            throw APIServiceError.validation("Origin is invalid.", pointer: "/origin")
        }
    }

    private func resourceID(in path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = String(path.dropFirst(prefix.count))
        guard !suffix.isEmpty, !suffix.contains("/") else { return nil }
        return suffix
    }

    private func replayDeckResponse(status: Int, body: Data) -> APIResponse {
        let revision = (try? APIJSON.decoder.decode(APIDeck.self, from: body).revision) ?? 1
        return APIResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "ETag": etag(revision),
            ],
            body: body
        )
    }

    private func invalidCursor() -> APIServiceError {
        .problem(
            status: 400,
            code: "invalid_cursor",
            title: "Invalid cursor",
            detail: "The cursor does not match this collection request."
        )
    }

    private func unauthorized() -> APIServiceError {
        .problem(
            status: 401,
            code: "unauthorized",
            title: "Unauthorized",
            detail: "A valid bearer token is required.",
            headers: ["WWW-Authenticate": "Bearer"]
        )
    }

    private func problemResponse(
        _ error: APIServiceError,
        request: APIRequest,
        requestID: String
    ) -> APIResponse {
        guard case let .problem(
            status, code, title, detail, errors, requiredScope, extraHeaders,
            impact, impactToken
        ) = error else {
            return APIResponse(status: 500)
        }
        let problem = APIProblem(
            status: status,
            code: code,
            title: title,
            detail: detail,
            requestID: requestID,
            errors: errors,
            requiredScope: requiredScope,
            impact: impact,
            impactToken: impactToken
        )
        var headers = extraHeaders
        headers["Content-Type"] = "application/problem+json; charset=utf-8"
        headers["X-Request-ID"] = requestID
        return APIResponse(
            status: status,
            headers: headers,
            body: (try? APIJSON.encoder.encode(problem)) ?? Data()
        )
    }

    private func addCommonHeaders(
        _ response: APIResponse,
        request: APIRequest,
        requestID: String
    ) async -> APIResponse {
        var headers = response.headers
        headers["X-Request-ID"] = requestID
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        if headers["Access-Control-Allow-Origin"] == nil,
           let origin = await approvedCORSOrigin(for: request, response: response) {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Vary"] = "Origin"
        }
        return APIResponse(status: response.status, headers: headers, body: response.body)
    }

    private func approvedCORSOrigin(
        for request: APIRequest,
        response: APIResponse
    ) async -> String? {
        guard let origin = request.header("origin") else { return nil }
        if request.method == .options,
           response.headers["Access-Control-Allow-Origin"] == origin {
            return origin
        }
        if request.path == "/v1/pairings", (200 ..< 300).contains(response.status) {
            return origin
        }
        guard let value = request.header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer",
              let grant = try? await authorization.authenticate(token: parts[1]),
              grant.origin == origin
        else { return nil }
        return origin
    }
}

private func requireDeck(_ deck: APIDeck?) throws -> APIDeck {
    guard let deck else {
        throw APIServiceError.notFound("The requested deck does not exist.")
    }
    return deck
}
