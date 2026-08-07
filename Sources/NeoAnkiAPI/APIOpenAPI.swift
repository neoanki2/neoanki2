import Foundation

enum APIOpenAPI {
    static let document: Data = {
        let publicSecurity: [[String: [String]]] = []
        var paths: [String: Any] = [:]

        func add(
            _ path: String,
            _ method: String,
            _ operationID: String,
            scope: String? = nil,
            success: Int = 200,
            request: String? = nil,
            response: String? = "Resource",
            requestContentType: String = "application/json",
            responseContentType: String = "application/json",
            query: [String] = [],
            requiredQuery: Set<String> = [],
            successHeaders: [String: Any] = [:]
        ) {
            let isProtectedMutation = scope != nil
                && ["post", "put", "patch", "delete"].contains(method)
            var operationResponses = responses(
                success: success,
                schema: response,
                contentType: responseContentType
            )
            var responseHeaders = successHeaders
            if isProtectedMutation {
                responseHeaders["X-NeoAnki-Change-Cursor"] = [
                    "description": "Last durable cursor when the operation committed library changes.",
                    "required": false,
                    "schema": ["type": "integer", "minimum": 1],
                ]
            }
            if !responseHeaders.isEmpty,
               var successResponse = operationResponses[String(success)] as? [String: Any]
            {
                successResponse["headers"] = responseHeaders
                operationResponses[String(success)] = successResponse
            }
            var operation: [String: Any] = [
                "operationId": operationID,
                "responses": operationResponses,
                "security": scope == nil ? publicSecurity : [["bearerAuth": []]],
            ]
            if let scope { operation["x-required-scope"] = scope }
            if let request {
                operation["requestBody"] = [
                    "required": true,
                    "content": [requestContentType: ["schema": reference(request)]],
                ]
            }
            let names = path.split(separator: "{").dropFirst().compactMap {
                $0.split(separator: "}").first.map(String.init)
            }
            var parameters: [[String: Any]] = names.map { name in
                    let schema: [String: Any]
                    switch name {
                    case "id" where path.contains("/vocabulary-packs/"):
                        schema = ["type": "string", "minLength": 1, "maxLength": 65_536]
                    case "entryId":
                        schema = ["type": "string", "minLength": 1, "maxLength": 65_536]
                    case "id", "fileId", "reviewLogId":
                        schema = [
                            "type": "string", "format": "uuid",
                            "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                        ]
                    case "sha256":
                        schema = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
                    default:
                        schema = ["type": "string"]
                    }
                    return [
                        "name": name, "in": "path", "required": true,
                        "schema": schema,
                    ] as [String: Any]
                }
            parameters += query.map { name in
                var schema: [String: Any] = ["type": "string"]
                if name == "limit" {
                    schema = [
                        "type": "integer", "minimum": 1,
                        "maximum": path == "/v1/changes" ? 1_000
                            : path.contains("/vocabulary-packs/{id}/entries") ? 500 : 200,
                    ]
                }
                if name == "mode" {
                    schema = ["type": "string", "enum": ["exact", "prefix"]]
                }
                if ["query", "language", "path"].contains(name) {
                    schema["minLength"] = 1
                    schema["maxLength"] = 65_536
                }
                if ["includeDescendants", "isSuspended"].contains(name) {
                    schema = ["type": "boolean"]
                }
                return [
                    "name": name, "in": "query",
                    "required": requiredQuery.contains(name), "schema": schema,
                ]
            }
            if isProtectedMutation {
                let required = [
                    "POST /v1/items", "POST /v1/items/bulk", "POST /v1/reviews",
                    "POST /v1/media", "POST /v1/cards/{id}/resets",
                    "POST /v1/deck-deletion-plans/{id}/commits",
                    "POST /v1/deck-reset-plans/{id}/commits",
                    "POST /v1/imports/{id}/commits",
                    "POST /v1/vocabulary-pack-imports/{id}/commits",
                ].contains("\(method.uppercased()) \(path)")
                parameters.append([
                    "name": "Idempotency-Key", "in": "header", "required": required,
                    "schema": ["type": "string", "minLength": 1, "maxLength": 256],
                ])
            }
            let needsIfMatch = scope != nil && (
                ["put", "patch", "delete"].contains(method)
                    || path.hasSuffix("/resets")
                    || path.hasSuffix("/commits")
                    || path == "/v1/tag-renames"
                    || path.hasSuffix("/reverts")
            )
            if needsIfMatch {
                parameters.append([
                    "name": "If-Match", "in": "header", "required": true,
                    "schema": ["type": "string", "pattern": "^\\\"revision-[0-9]+\\\"$"],
                ])
            }
            if path == "/v1/item-types/{id}", method == "put" {
                parameters.append([
                    "name": "NeoAnki-Impact-Token", "in": "header", "required": false,
                    "schema": ["type": "string"],
                ])
            }
            if path == "/v1/media", method == "post" {
                parameters += [
                    ["name": "NeoAnki-Media-Kind", "in": "header", "required": true,
                     "schema": ["type": "string", "enum": ["audio", "image", "gif", "video"]]],
                    ["name": "NeoAnki-Alt-Text", "in": "header", "required": false,
                     "schema": ["type": "string"]],
                ]
            }
            if path == "/v1/events" {
                parameters.append([
                    "name": "Last-Event-ID", "in": "header", "required": false,
                    "schema": ["type": "integer", "minimum": 0],
                ])
            }
            if !parameters.isEmpty {
                operation["parameters"] = parameters
            }
            var pathItem = paths[path] as? [String: Any] ?? [:]
            pathItem[method] = operation
            paths[path] = pathItem
        }

        let vocabularyETagHeader: [String: Any] = [
            "description": "Current immutable pack or import-job revision.",
            "required": true,
            "schema": ["type": "string", "pattern": "^\\\"revision-[0-9]+\\\"$"],
        ]
        let vocabularyLocationHeader: [String: Any] = [
            "description": "Canonical relative URL of the created job or installed pack.",
            "required": true,
            "schema": ["type": "string"],
        ]
        let vocabularyMediaHeaders: [String: Any] = [
            "Content-Length": [
                "description": "Validated media byte count.", "required": true,
                "schema": ["type": "integer", "minimum": 0],
            ],
            "Digest": [
                "description": "Validated vocabulary manifest SHA-256 digest.", "required": true,
                "schema": ["type": "string", "pattern": "^sha-256=[0-9a-f]{64}$"],
            ],
            "Accept-Ranges": [
                "description": "Vocabulary media is not range-addressable.", "required": true,
                "schema": ["type": "string", "const": "none"],
            ],
        ]

        add("/health", "get", "health", success: 200, response: "Health")
        add("/v1/meta", "get", "meta", response: "Meta")
        add("/v1/openapi.json", "get", "openapi", response: "OpenAPIDocument")
        add("/v1/pairings", "post", "pair", success: 201, request: "PairingInput", response: "PairingResult")
        add("/v1/clients/current", "get", "currentClient", scope: "any", response: "Client")
        add("/v1/clients/current", "delete", "revokeCurrentClient", scope: "any", success: 204, response: nil)

        add("/v1/decks", "get", "listDecks", scope: "library.read", response: "DeckCollection", query: ["cursor", "limit"])
        add("/v1/decks", "post", "createDeck", scope: "decks.write", success: 201, request: "CreateDeckInput", response: "Deck")
        add("/v1/decks/{id}", "get", "getDeck", scope: "library.read", response: "Deck")
        add("/v1/decks/{id}", "patch", "updateDeck", scope: "decks.write", request: "UpdateDeckInput", response: "Deck")
        add("/v1/deck-deletion-plans", "post", "createDeckDeletionPlan", scope: "decks.write", success: 201, request: "CreateDeckDeletionPlanInput", response: "DeckDeletionPlan")
        add("/v1/deck-deletion-plans/{id}/commits", "post", "commitDeckDeletionPlan", scope: "decks.write", request: "ConfirmInput", response: "DeckDeletionCommitResult")
        add("/v1/deck-reset-plans", "post", "createDeckResetPlan", scope: "study.review", success: 201, request: "DeckIdentifierInput", response: "DeckResetPlan")
        add("/v1/deck-reset-plans/{id}/commits", "post", "commitDeckResetPlan", scope: "study.review", request: "RequiredConfirmInput", response: "DeckResetCommitResult")
        add("/v1/decks/{id}/item-type-policy", "get", "deckItemTypePolicy", scope: "library.read", response: "ItemTypePolicy")

        add("/v1/item-types", "get", "listItemTypes", scope: "library.read", response: "ItemTypeCollection", query: ["cursor", "limit"])
        add("/v1/item-types", "post", "createItemType", scope: "schemas.write", success: 201, request: "ItemTypeInput", response: "ItemType")
        add("/v1/item-types/validate", "post", "validateItemType", scope: "schemas.write", success: 204, request: "ItemTypeInput", response: nil)
        add("/v1/item-types/{id}", "get", "getItemType", scope: "library.read", response: "ItemType")
        add("/v1/item-types/{id}", "put", "replaceItemType", scope: "schemas.write", request: "ItemTypeInput", response: "ItemType")
        add("/v1/item-types/{id}", "delete", "deleteItemType", scope: "schemas.write", success: 204, response: nil)
        add("/v1/item-types/{id}/duplicate", "post", "duplicateItemType", scope: "schemas.write", success: 201, request: "DuplicateItemTypeInput", response: "ItemType")

        add("/v1/items", "get", "listItems", scope: "library.read", response: "ItemCollection", query: ["cursor", "limit", "deckId", "includeDescendants", "itemTypeId", "tag", "text", "schedulePhase", "dueBefore", "createdAfter", "updatedAfter"])
        add("/v1/items", "post", "createItem", scope: "items.write", success: 201, request: "CreateItemInput", response: "Item")
        add("/v1/items/validate", "post", "validateItem", scope: "items.write", success: 204, request: "CreateItemInput", response: nil)
        add("/v1/items/bulk", "post", "bulkItems", scope: "items.write", request: "BulkItemsInput", response: "BulkItemsResult")
        add("/v1/items/{id}", "get", "getItem", scope: "library.read", response: "Item")
        add("/v1/items/{id}", "put", "replaceItem", scope: "items.write", request: "ReplaceItemInput", response: "Item")
        add("/v1/items/{id}", "delete", "deleteItem", scope: "items.write", success: 204, response: nil)
        add("/v1/items/{id}/duplicate-checks", "post", "duplicateChecks", scope: "library.read", request: "EmptyObject", response: "DuplicateCheckResult")
        add("/v1/tags", "get", "listTags", scope: "library.read", response: "TagCollection", query: ["cursor", "limit"])
        add("/v1/tag-renames", "post", "renameTag", scope: "items.write", request: "RenameTagInput", response: "MutationCount")
        add("/v1/tags/{encodedTag}", "delete", "removeTag", scope: "items.write", success: 204, response: nil)

        add("/v1/cards", "get", "listCards", scope: "library.read", response: "CardCollection", query: ["cursor", "limit", "itemId", "deckId", "includeDescendants", "templateId", "phase", "isSuspended", "dueBefore"])
        add("/v1/cards/{id}", "get", "getCard", scope: "library.read", response: "Card")
        add("/v1/cards/{id}", "patch", "patchCard", scope: "study.review", request: "PatchCardInput", response: "Card")
        add("/v1/cards/{id}/content", "get", "cardContent", scope: "library.read", response: "StudyCard")
        add("/v1/cards/{id}/review-preview", "get", "reviewPreview", scope: "library.read", response: "RatingPreviewArray")
        add("/v1/cards/{id}/resets", "post", "resetCard", scope: "study.review", request: "RequiredConfirmInput", response: "Card")

        add("/v1/study-sessions", "post", "createStudySession", scope: "study.review", success: 201, request: "CreateStudySessionInput", response: "StudySession")
        add("/v1/study-sessions/{id}", "get", "getStudySession", scope: "study.review", response: "StudySession")
        add("/v1/study-sessions/{id}", "delete", "endStudySession", scope: "study.review", success: 204, response: nil)
        add("/v1/study-sessions/{id}/next", "post", "nextStudyCard", scope: "study.review", response: "StudyCard")
        add("/v1/study-sessions/{id}/skips", "post", "skipStudyCard", scope: "study.review", success: 204, request: "SkipStudyCardInput", response: nil)
        add("/v1/reviews", "post", "submitReview", scope: "study.review", success: 201, request: "SubmitReviewInput", response: "ReviewResult")
        add("/v1/reviews/{reviewLogId}/reverts", "post", "revertReview", scope: "study.review", success: 204, response: nil)

        add("/v1/media", "post", "uploadMedia", scope: "media.write", success: 201, request: "Binary", response: "MediaReservation", requestContentType: "application/octet-stream")
        add("/v1/media/{sha256}", "head", "headMedia", scope: "library.read", response: nil, responseContentType: "application/octet-stream")
        add("/v1/media/{sha256}", "get", "downloadMedia", scope: "library.read", response: "Binary", responseContentType: "application/octet-stream")
        add("/v1/media/{sha256}/metadata", "get", "mediaMetadata", scope: "library.read", response: "MediaMetadata")

        add("/v1/vocabulary-packs", "get", "listVocabularyPacks", scope: "vocabulary.read", response: "VocabularyPackCollection")
        add("/v1/vocabulary-packs/{id}", "get", "getVocabularyPack", scope: "vocabulary.read", response: "VocabularyPack", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-packs/{id}", "delete", "deleteVocabularyPack", scope: "vocabulary.write", success: 204, response: nil)
        add("/v1/vocabulary-packs/{id}/entries", "get", "searchVocabularyEntries", scope: "vocabulary.read", response: "LexicalEntryCollection", query: ["query", "mode", "limit", "language"], requiredQuery: ["query"])
        add("/v1/vocabulary-packs/{id}/entries/{entryId}", "get", "getVocabularyEntry", scope: "vocabulary.read", response: "LexicalEntry")
        add("/v1/vocabulary-packs/{id}/media", "get", "downloadVocabularyMedia", scope: "vocabulary.read", response: "Binary", responseContentType: "application/octet-stream", query: ["path"], requiredQuery: ["path"], successHeaders: vocabularyMediaHeaders)
        add("/v1/vocabulary-packs/{id}/media", "head", "headVocabularyMedia", scope: "vocabulary.read", response: nil, responseContentType: "application/octet-stream", query: ["path"], requiredQuery: ["path"], successHeaders: vocabularyMediaHeaders)

        add("/v1/vocabulary-pack-imports", "post", "createVocabularyPackImport", scope: "vocabulary.write", success: 201, request: "CreateVocabularyPackImportInput", response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader, "Location": vocabularyLocationHeader])
        add("/v1/vocabulary-pack-imports/{id}", "get", "getVocabularyPackImport", scope: "vocabulary.write", response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-pack-imports/{id}", "delete", "deleteVocabularyPackImport", scope: "vocabulary.write", success: 204, response: nil)
        add("/v1/vocabulary-pack-imports/{id}/files/{fileId}", "put", "uploadVocabularyPackFile", scope: "vocabulary.write", request: "Binary", response: "VocabularyPackImport", requestContentType: "application/octet-stream", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-pack-imports/{id}/validations", "post", "validateVocabularyPackImport", scope: "vocabulary.write", response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader])
        add("/v1/vocabulary-pack-imports/{id}/commits", "post", "commitVocabularyPackImport", scope: "vocabulary.write", response: "VocabularyPackImport", successHeaders: ["ETag": vocabularyETagHeader, "Location": vocabularyLocationHeader])

        add("/v1/imports", "post", "createImport", scope: "library.import", success: 201, request: "CreateImportInput", response: "ImportJob")
        add("/v1/imports/{id}", "get", "getImport", scope: "library.import", response: "ImportJob")
        add("/v1/imports/{id}", "delete", "deleteImport", scope: "library.import", success: 204, response: nil)
        add("/v1/imports/{id}/files/{fileId}", "put", "uploadImportFile", scope: "library.import", success: 204, request: "Binary", response: nil, requestContentType: "application/octet-stream")
        add("/v1/imports/{id}/validations", "post", "validateImport", scope: "library.import", response: "ImportJob")
        add("/v1/imports/{id}/commits", "post", "commitImport", scope: "library.import", request: "CommitImportInput", response: "ImportJob")
        add("/v1/exports", "post", "createExport", scope: "library.export", success: 201, request: "CreateExportInput", response: "ExportJob")
        add("/v1/exports/{id}", "get", "getExport", scope: "library.export", response: "ExportJob")
        add("/v1/exports/{id}", "delete", "deleteExport", scope: "library.export", success: 204, response: nil)
        add("/v1/exports/{id}/content", "get", "exportContent", scope: "library.export", response: "Binary", responseContentType: "application/vnd.neoanki.portable-deck")

        add("/v1/changes", "get", "changes", scope: "library.read", response: "ChangeCollection", query: ["after", "limit"])
        add("/v1/events", "get", "events", scope: "library.read", response: "EventStream", responseContentType: "text/event-stream", query: ["after"])

        let document: [String: Any] = [
            "openapi": "3.1.0",
            "info": [
                "title": "NeoAnki Local Automation API",
                "version": "1.0.0",
                "description": "Loopback-only local automation API. It is not a synchronization or remote-access protocol.",
            ],
            "servers": [["url": "http://127.0.0.1:8766"]],
            "security": [["bearerAuth": []]],
            "paths": paths,
            "components": [
                "securitySchemes": [
                    "bearerAuth": ["type": "http", "scheme": "bearer", "bearerFormat": "opaque"],
                ],
                "schemas": schemas,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }()

    /// Resolves a concrete request path against the paths declared by the
    /// shipped contract. Browser preflight uses this rather than a second,
    /// independently maintained route list.
    static func documentedMethods(for requestPath: String) -> Set<APIHTTPMethod> {
        guard
            let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
            let paths = object["paths"] as? [String: Any]
        else { return [] }

        let requestComponents = requestPath.split(separator: "/", omittingEmptySubsequences: false)
        for (template, value) in paths {
            let templateComponents = template.split(separator: "/", omittingEmptySubsequences: false)
            guard templateComponents.count == requestComponents.count else { continue }
            let matches = zip(templateComponents, requestComponents).allSatisfy { expected, actual in
                (expected.hasPrefix("{") && expected.hasSuffix("}")) || expected == actual
            }
            guard matches, let operations = value as? [String: Any] else { continue }
            return Set(operations.keys.compactMap { APIHTTPMethod(rawValue: $0.uppercased()) })
        }
        return []
    }

    static func documentedQueryParameters(
        for requestPath: String,
        method: APIHTTPMethod
    ) -> Set<String> {
        guard
            let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
            let paths = object["paths"] as? [String: Any]
        else { return [] }
        let requestComponents = requestPath.split(separator: "/", omittingEmptySubsequences: false)
        for (template, value) in paths {
            let templateComponents = template.split(separator: "/", omittingEmptySubsequences: false)
            guard templateComponents.count == requestComponents.count else { continue }
            let matches = zip(templateComponents, requestComponents).allSatisfy { expected, actual in
                (expected.hasPrefix("{") && expected.hasSuffix("}")) || expected == actual
            }
            guard matches,
                  let operations = value as? [String: Any],
                  let operation = operations[method.rawValue.lowercased()] as? [String: Any],
                  let parameters = operation["parameters"] as? [[String: Any]]
            else { continue }
            return Set(parameters.compactMap { parameter in
                parameter["in"] as? String == "query" ? parameter["name"] as? String : nil
            })
        }
        return []
    }

    static func acceptsRequestBody(
        for requestPath: String,
        method: APIHTTPMethod
    ) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
            let paths = object["paths"] as? [String: Any]
        else { return false }
        let requestComponents = requestPath.split(separator: "/", omittingEmptySubsequences: false)
        for (template, value) in paths {
            let templateComponents = template.split(separator: "/", omittingEmptySubsequences: false)
            guard templateComponents.count == requestComponents.count else { continue }
            let matches = zip(templateComponents, requestComponents).allSatisfy { expected, actual in
                (expected.hasPrefix("{") && expected.hasSuffix("}")) || expected == actual
            }
            guard matches,
                  let operations = value as? [String: Any],
                  let operation = operations[method.rawValue.lowercased()] as? [String: Any]
            else { continue }
            return operation["requestBody"] != nil
        }
        return false
    }

    private static func reference(_ name: String) -> [String: Any] {
        ["$ref": "#/components/schemas/\(name)"]
    }

    private static func responses(
        success: Int,
        schema: String?,
        contentType: String
    ) -> [String: Any] {
        var successResponse: [String: Any] = ["description": "Success"]
        if let schema {
            successResponse["content"] = [contentType: ["schema": reference(schema)]]
        }
        return [
            String(success): successResponse,
            "default": [
                "description": "Problem details",
                "content": ["application/problem+json": ["schema": reference("Problem")]],
            ],
        ]
    }

    private static var schemas: [String: Any] {
        let uuid: [String: Any] = [
            "type": "string", "format": "uuid",
            "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        ]
        let nullableUUID: [String: Any] = ["oneOf": [uuid, ["type": "null"]]]
        let timestamp: [String: Any] = ["type": "string", "format": "date-time"]
        let nonnegative: [String: Any] = ["type": "integer", "minimum": 0]
        let revision: [String: Any] = ["type": "integer", "minimum": 1]
        let sha256: [String: Any] = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
        func object(_ required: [String], _ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object", "additionalProperties": false,
                "required": required, "properties": properties,
            ]
        }
        func array(_ schema: [String: Any], min: Int? = nil, max: Int? = nil) -> [String: Any] {
            var result: [String: Any] = ["type": "array", "items": schema]
            if let min { result["minItems"] = min }
            if let max { result["maxItems"] = max }
            return result
        }
        func collection(_ resource: String) -> [String: Any] {
            object(["data", "page"], [
                "data": array(reference(resource)),
                "page": reference("PageInfo"),
            ])
        }
        let scope = [
            "type": "string",
            "enum": [
                "library.read", "items.write", "decks.write", "schemas.write",
                "study.review", "media.write", "library.import", "library.export",
                "vocabulary.read", "vocabulary.write",
                "settings.write", "ui.control",
            ],
        ] as [String: Any]
        let contentValue: [String: Any] = [
            "oneOf": [
                object(["type"], ["type": ["type": "string", "const": "empty"]]),
                object(["type", "text"], [
                    "type": ["type": "string", "const": "text"],
                    "text": ["type": "string"], "lang": ["type": "string"],
                ]),
                object(["type", "spans"], [
                    "type": ["type": "string", "const": "rich"],
                    "spans": array(reference("RichSpan")),
                ]),
                object(["type", "mediaId", "kind", "sha256", "fileExtension"], [
                    "type": ["type": "string", "const": "media"],
                    "mediaId": uuid,
                    "kind": ["type": "string", "enum": ["audio", "image", "gif", "video"]],
                    "sha256": sha256, "fileExtension": ["type": "string"],
                    "durationMs": nonnegative, "altText": ["type": "string"],
                    "reservationId": uuid,
                ]),
                object(["type", "text", "blanks"], [
                    "type": ["type": "string", "const": "cloze"],
                    "text": ["type": "string"], "blanks": array(reference("ClozeSpan"), min: 1),
                ]),
                object(["type", "number"], [
                    "type": ["type": "string", "const": "number"],
                    "number": ["type": "number"],
                ]),
            ],
        ]
        let itemInputProperties: [String: Any] = [
            "id": uuid, "itemTypeId": uuid, "deckId": nullableUUID,
            "fields": array(reference("FieldValue")),
            "tags": ["type": "array", "maxItems": 256, "uniqueItems": true,
                     "items": ["type": "string", "minLength": 1, "maxLength": 1024]],
        ]
        let itemTypeInputProperties: [String: Any] = [
            "id": uuid, "name": ["type": "string", "minLength": 1],
            "fields": array(reference("FieldDefinition"), min: 1),
            "templates": array(reference("TemplateDefinition"), min: 1),
        ]

        return [
            "Binary": ["type": "string", "contentMediaType": "application/octet-stream"],
            "OpenAPIDocument": ["type": "object", "additionalProperties": true],
            "EventStream": ["type": "string"],
            "EmptyObject": object([], [:]),
            "PageInfo": object(["limit"], [
                "nextCursor": ["type": ["string", "null"]],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200],
            ]),
            "Health": object(["status"], ["status": ["type": "string", "const": "ok"]]),
            "Meta": object(
                ["apiVersion", "applicationVersion", "serverInstanceId", "pairingAvailable", "capabilities"],
                [
                    "apiVersion": ["type": "integer", "const": 1],
                    "applicationVersion": ["type": "string"], "serverInstanceId": uuid,
                    "pairingAvailable": ["type": "boolean"],
                    "capabilities": array(["type": "string"]),
                ]
            ),
            "PairingInput": object(["displayName", "requestedScopes"], [
                "displayName": ["type": "string", "minLength": 1, "maxLength": 256],
                "requestedScopes": ["type": "array", "items": scope, "minItems": 1,
                                    "uniqueItems": true],
                "origin": ["type": ["string", "null"]],
            ]),
            "PairingResult": object(["client", "token"], [
                "client": reference("Client"), "token": ["type": "string", "minLength": 43],
            ]),
            "Client": object(["id", "displayName", "scopes", "createdAt", "revision"], [
                "id": uuid, "displayName": ["type": "string"],
                "origin": ["type": ["string", "null"]], "scopes": array(scope, min: 1),
                "createdAt": timestamp, "revision": revision,
            ]),
            "VocabularyProvenance": object(["sourceId"], [
                "sourceId": ["type": "string"],
                "sourceName": ["type": ["string", "null"]],
                "recordId": ["type": ["string", "null"]],
                "attribution": ["type": ["string", "null"]],
                "license": ["type": ["string", "null"]],
                "sourceUrl": ["type": ["string", "null"]],
            ]),
            "VocabularyPack": object([
                "id", "revision", "title", "languages", "capabilities", "entryCount",
                "databaseSha256", "mediaFileCount", "mediaByteCount",
            ], [
                "id": ["type": "string", "minLength": 1, "maxLength": 65_536],
                "revision": ["type": "integer", "const": 1],
                "title": ["type": "string"], "summary": ["type": ["string", "null"]],
                "languages": array(["type": "string"]),
                "capabilities": array(["type": "string", "enum": [
                    "lexicon", "pronunciation", "morphology", "corpus", "frequency",
                ]]),
                "provenance": ["oneOf": [reference("VocabularyProvenance"), ["type": "null"]]],
                "entryCount": nonnegative, "databaseSha256": sha256,
                "mediaFileCount": nonnegative, "mediaByteCount": nonnegative,
            ]),
            "VocabularyPackCollection": object(["data"], [
                "data": array(reference("VocabularyPack"), max: 1_000),
            ]),
            "LocalizedVocabularyText": object(["value"], [
                "value": ["type": "string"], "language": ["type": ["string", "null"]],
            ]),
            "LexicalEntry": [
                "type": "object", "additionalProperties": false,
                "required": ["id", "language", "canonicalForm", "forms", "pronunciations", "senses"],
                "properties": [
                    "id": ["type": "string"], "language": ["type": "string"],
                    "canonicalForm": ["type": "object", "additionalProperties": true],
                    "forms": array(["type": "object", "additionalProperties": true]),
                    "pronunciations": array(["type": "object", "additionalProperties": true]),
                    "senses": array(["type": "object", "additionalProperties": true]),
                    "frequency": ["type": ["number", "null"]],
                    "provenance": ["oneOf": [reference("VocabularyProvenance"), ["type": "null"]]],
                ],
            ],
            "LexicalEntryCollection": object(["data"], [
                "data": array(reference("LexicalEntry"), max: 500),
            ]),
            "VocabularyPackImportFileInput": object(["id", "path", "byteSize", "sha256"], [
                "id": uuid, "path": ["type": "string", "minLength": 1, "maxLength": 65_536],
                "byteSize": [
                    "type": "integer", "minimum": 0,
                    "maximum": APIVocabularyLibrary.maximumFileBytes,
                ],
                "sha256": sha256,
            ]),
            "CreateVocabularyPackImportInput": object(["files"], [
                "files": array(reference("VocabularyPackImportFileInput"), min: 2, max: 100_002),
            ]),
            "VocabularyPackImportFile": object(["id", "path", "byteSize", "sha256", "uploaded"], [
                "id": uuid, "path": ["type": "string"], "byteSize": nonnegative,
                "sha256": sha256, "uploaded": ["type": "boolean"],
            ]),
            "VocabularyPackImport": object([
                "id", "revision", "state", "files", "createdAt", "updatedAt",
            ], [
                "id": uuid, "revision": revision,
                "state": ["type": "string", "enum": ["awaitingFiles", "ready", "validated", "completed"]],
                "files": array(reference("VocabularyPackImportFile"), min: 2, max: 100_002),
                "pack": ["oneOf": [reference("VocabularyPack"), ["type": "null"]]],
                "createdAt": timestamp, "updatedAt": timestamp,
            ]),
            "CreateDeckInput": object(["name"], [
                "id": uuid, "name": ["type": "string", "minLength": 1],
                "parentId": nullableUUID,
                "newCardsPerDay": ["type": ["integer", "null"], "minimum": 0],
            ]),
            "UpdateDeckInput": object([], [
                "name": ["type": "string", "minLength": 1], "parentId": nullableUUID,
                "newCardsPerDay": ["type": ["integer", "null"], "minimum": 0],
            ]),
            "Deck": object(
                ["id", "revision", "name", "directItemCount",
                 "recursiveItemCount", "dueCount", "childIds"],
                [
                    "id": uuid, "revision": revision, "name": ["type": "string"],
                    "parentId": nullableUUID,
                    "newCardsPerDay": ["type": ["integer", "null"], "minimum": 0],
                    "directItemCount": nonnegative, "recursiveItemCount": nonnegative,
                    "dueCount": nonnegative, "childIds": array(uuid),
                ]
            ),
            "DeckCollection": collection("Deck"),
            "DeckIdentifierInput": object(["deckId"], ["deckId": uuid]),
            "ConfirmInput": object([], ["confirm": ["type": "boolean"]]),
            "RequiredConfirmInput": object(["confirm"], ["confirm": ["type": "boolean"]]),
            "CreateDeckDeletionPlanInput": object(["deckId", "policy"], [
                "deckId": uuid,
                "policy": ["type": "string", "enum": ["rejectIfNonempty", "unassignItems",
                                                             "moveItemsToParent", "deleteSubtreeAndItems"]],
            ]),
            "DeckDeletionImpact": object(
                ["deckCount", "itemCount", "cardCount", "reviewLogCount", "mediaReferenceCount"],
                ["deckCount": nonnegative, "itemCount": nonnegative, "cardCount": nonnegative,
                 "reviewLogCount": nonnegative, "mediaReferenceCount": nonnegative]
            ),
            "DeckResetImpact": object(["deckCount", "cardCount", "reviewLogCount"], [
                "deckCount": nonnegative, "cardCount": nonnegative, "reviewLogCount": nonnegative,
            ]),
            "DeckDeletionPlan": object(
                ["id", "revision", "deckId", "policy", "impact", "deckRevision", "dependencyChangeCursor", "expiresAt"],
                ["id": uuid, "revision": revision, "deckId": uuid,
                 "policy": ["type": "string", "enum": ["rejectIfNonempty", "unassignItems",
                                                            "moveItemsToParent", "deleteSubtreeAndItems"]],
                 "impact": reference("DeckDeletionImpact"), "deckRevision": revision,
                 "dependencyChangeCursor": nonnegative,
                 "expiresAt": timestamp]
            ),
            "DeckResetPlan": object(
                ["id", "revision", "deckId", "impact", "deckRevision", "dependencyChangeCursor", "expiresAt"],
                ["id": uuid, "revision": revision, "deckId": uuid, "impact": reference("DeckResetImpact"),
                 "deckRevision": revision, "dependencyChangeCursor": nonnegative, "expiresAt": timestamp]
            ),
            "DeckDeletionCommitResult": object(["planId", "committed", "impact"], [
                "planId": uuid, "committed": ["type": "boolean"],
                "impact": reference("DeckDeletionImpact"),
            ]),
            "DeckResetCommitResult": object(["planId", "committed", "impact"], [
                "planId": uuid, "committed": ["type": "boolean"],
                "impact": reference("DeckResetImpact"),
            ]),
            "FieldDefinition": object(["id", "name", "type", "isRequired"], [
                "id": uuid, "name": ["type": "string"],
                "type": ["type": "string", "enum": ["text", "richText", "audio", "image",
                                                          "gif", "video", "number", "cloze"]],
                "isRequired": ["type": "boolean"],
            ]),
            "Skill": object(["input", "output", "operation"], [
                "input": ["type": "string"], "output": ["type": "string"],
                "operation": ["type": "string"],
            ]),
            "SlotSource": object(["kind"], [
                "kind": ["type": "string", "enum": ["field", "literal"]],
                "fieldId": uuid, "text": ["type": "string"],
            ]),
            "Presentation": object(["reveal", "media"], [
                "reveal": ["type": "string", "enum": ["always", "hiddenUntilAnswer", "blurred"]],
                "media": ["type": "string", "enum": ["default", "autoplay", "playOnTap", "loop"]],
            ]),
            "Slot": object(["source", "presentation"], [
                "source": reference("SlotSource"), "presentation": reference("Presentation"),
            ]),
            "Condition": object(["kind"], [
                "kind": ["type": "string", "enum": ["fieldNotEmpty", "fieldEmpty", "all", "any"]],
                "fieldId": uuid, "conditions": array(reference("Condition")),
            ]),
            "TemplateDefinition": object(
                ["id", "name", "prompt", "answer", "interaction", "skill"],
                ["id": uuid, "name": ["type": "string"], "prompt": array(reference("Slot")),
                 "answer": array(reference("Slot")),
                 "interaction": ["type": "string", "enum": ["reveal", "type", "choose", "record", "cloze", "arrange"]],
                 "skill": reference("Skill"), "generateWhen": reference("Condition")]
            ),
            "ItemTypeInput": object(["name", "fields", "templates"], itemTypeInputProperties),
            "DuplicateItemTypeInput": object(["name"], ["name": ["type": "string", "minLength": 1]]),
            "ItemType": object(
                ["id", "revision", "name", "fields", "templates", "provenance", "itemCount"],
                itemTypeInputProperties.merging([
                    "revision": revision, "provenance": ["type": "string"], "itemCount": nonnegative,
                ]) { _, new in new }
            ),
            "ItemTypeCollection": collection("ItemType"),
            "ItemTypePolicy": object(["sourceDeckId", "defaultItemTypeId", "itemTypeIds"], [
                "sourceDeckId": nullableUUID, "defaultItemTypeId": nullableUUID,
                "itemTypeIds": array(uuid),
            ]),
            "RichSpan": object(["text", "styles"], [
                "text": ["type": "string"],
                "styles": ["type": "array", "uniqueItems": true,
                           "items": ["type": "string", "enum": ["bold", "italic", "underline",
                               "strikethrough", "highlight", "code", "superscript", "subscript"]]],
                "textColor": ["type": "string"], "textSize": ["type": "string", "enum": ["small", "large"]],
                "link": ["type": "string", "format": "uri"],
            ]),
            "ClozeSpan": object(["group", "start", "length"], [
                "group": ["type": "integer"], "start": nonnegative, "length": nonnegative,
                "hint": ["type": "string"],
            ]),
            "ContentValue": contentValue,
            "FieldValue": object(["fieldId", "value"], [
                "fieldId": uuid, "value": reference("ContentValue"),
            ]),
            "CreateItemInput": object(["itemTypeId", "fields", "tags"], itemInputProperties),
            "ReplaceItemInput": object(["itemTypeId", "deckId", "fields", "tags"], itemInputProperties),
            "Item": object(
                ["id", "revision", "itemTypeId", "fields", "tags", "createdAt", "updatedAt", "cardIds"],
                itemInputProperties.merging([
                    "revision": revision, "createdAt": timestamp, "updatedAt": timestamp,
                    "cardIds": array(uuid),
                ]) { _, new in new }
            ),
            "ItemCollection": collection("Item"),
            "BulkItemOperation": object(["operationId", "action"], [
                "operationId": ["type": "string"],
                "action": ["type": "string", "enum": ["create", "replace", "delete"]],
                "item": reference("CreateItemInput"), "itemId": uuid,
            ]),
            "BulkItemsInput": object(["atomic", "dryRun", "operations"], [
                "atomic": ["type": "boolean", "const": true], "dryRun": ["type": "boolean"],
                "operations": array(reference("BulkItemOperation"), min: 1, max: 500),
            ]),
            "BulkItemsResult": object(["dryRun", "results", "impact"], [
                "dryRun": ["type": "boolean"], "results": array(reference("BulkItemResult")),
                "impact": reference("BulkItemImpact"),
            ]),
            "BulkItemResult": object(["operationId", "action", "itemId", "cardIds"], [
                "operationId": ["type": "string"], "action": ["type": "string"],
                "itemId": uuid, "cardIds": array(uuid),
            ]),
            "BulkItemImpact": object(
                ["createdItemCount", "replacedItemCount", "deletedItemCount", "resultingCardCount"],
                ["createdItemCount": nonnegative, "replacedItemCount": nonnegative,
                 "deletedItemCount": nonnegative, "resultingCardCount": nonnegative]
            ),
            "DuplicateCheckResult": object(["candidates"], [
                "candidates": array(reference("DuplicateCandidate")),
            ]),
            "DuplicateCandidate": object(["itemId", "reasonCodes"], [
                "itemId": uuid, "reasonCodes": array(["type": "string"]),
            ]),
            "Tag": object(["name", "itemCount", "revision"], [
                "name": ["type": "string"], "itemCount": nonnegative, "revision": revision,
            ]),
            "TagCollection": collection("Tag"),
            "RenameTagInput": object(["from", "to"], ["from": ["type": "string"], "to": ["type": "string"]]),
            "MutationCount": object(["updatedItemCount"], ["updatedItemCount": nonnegative]),
            "Memory": object(
                ["stabilityDays", "difficulty", "dueAt", "repetitions", "lapses", "phase"],
                ["stabilityDays": ["type": "number"], "difficulty": ["type": "number"],
                 "dueAt": timestamp, "lastReviewedAt": ["oneOf": [timestamp, ["type": "null"]]],
                 "repetitions": nonnegative, "lapses": nonnegative, "phase": ["type": "string"],
                 "stepIndex": ["type": ["integer", "null"]]]
            ),
            "Card": object(
                ["id", "revision", "itemId", "templateId", "skill", "isSuspended", "memory"],
                ["id": uuid, "revision": revision, "itemId": uuid, "templateId": uuid,
                 "deckId": nullableUUID, "clozeGroup": ["type": ["integer", "null"]],
                 "skill": reference("Skill"), "isSuspended": ["type": "boolean"],
                 "memory": reference("Memory")]
            ),
            "CardCollection": collection("Card"),
            "PatchCardInput": object(["isSuspended"], ["isSuspended": ["type": "boolean"]]),
            "ResolvedSlot": object(["value", "presentation"], [
                "value": reference("ContentValue"), "presentation": reference("Presentation"),
            ]),
            "StudyCard": object(
                ["id", "revision", "itemId", "templateId", "interaction", "prompt", "answer", "memory"],
                ["id": uuid, "revision": revision, "itemId": uuid, "templateId": uuid,
                 "deckId": nullableUUID, "clozeGroup": ["type": ["integer", "null"]],
                 "interaction": ["type": "string"], "prompt": array(reference("ResolvedSlot")),
                 "answer": array(reference("ResolvedSlot")), "memory": reference("Memory")]
            ),
            "RatingPreviewArray": array(reference("RatingPreview")),
            "RatingPreview": object(["rating", "memory"], [
                "rating": ["type": "string", "enum": ["again", "hard", "good", "easy"]],
                "memory": reference("Memory"),
            ]),
            "StudyScope": object(["kind"], [
                "kind": ["type": "string", "enum": ["allDecks", "unassigned", "deck"]],
                "deckId": uuid, "includeDescendants": ["type": "boolean"],
            ]),
            "CreateStudySessionInput": object(["scope"], ["scope": reference("StudyScope")]),
            "StudySession": object(
                ["id", "revision", "scope", "state", "createdAt", "lastActivityAt"],
                ["id": uuid, "revision": revision, "scope": reference("StudyScope"),
                 "state": ["type": "string"], "currentCardId": nullableUUID,
                 "createdAt": timestamp, "lastActivityAt": timestamp]
            ),
            "SkipStudyCardInput": object(["cardId"], ["cardId": uuid]),
            "SubmitReviewInput": object(["sessionId", "cardId", "rating", "durationMs"], [
                "sessionId": uuid, "cardId": uuid,
                "rating": ["type": "string", "enum": ["again", "hard", "good", "easy"]],
                "durationMs": nonnegative,
            ]),
            "ReviewResult": object(
                ["reviewLogId", "revision", "previousPhase", "resultingPhase", "memory", "changeCursor"],
                ["reviewLogId": uuid, "revision": revision, "previousPhase": ["type": "string"],
                 "resultingPhase": ["type": "string"], "memory": reference("Memory"),
                 "changeCursor": nonnegative]
            ),
            "MediaReservation": object(
                ["assetHash", "kind", "fileExtension", "byteSize", "reservationId", "reservationExpiresAt"],
                ["assetHash": sha256, "kind": ["type": "string", "enum": ["audio", "image", "gif", "video"]],
                 "fileExtension": ["type": "string"], "byteSize": nonnegative,
                 "reservationId": uuid, "reservationExpiresAt": timestamp]
            ),
            "MediaMetadata": object(
                ["assetHash", "kind", "fileExtension", "byteSize", "referenceCount"],
                ["assetHash": sha256, "kind": ["type": "string"], "fileExtension": ["type": "string"],
                 "byteSize": nonnegative, "referenceCount": nonnegative]
            ),
            "ImportFileDeclaration": object(["relativePath", "byteSize", "sha256"], [
                "relativePath": ["type": "string"], "byteSize": nonnegative, "sha256": sha256,
            ]),
            "CreateImportInput": object(["format", "files"], [
                "format": ["type": "string", "enum": ["json", "csv", "authoredDeck", "portableDeck"]],
                "itemTypeId": uuid, "csvItemTypeName": ["type": "string"],
                "destinationDeckId": uuid, "files": array(reference("ImportFileDeclaration"), min: 1),
            ]),
            "ImportFile": object(["id", "relativePath", "byteSize", "sha256", "uploaded"], [
                "id": uuid, "relativePath": ["type": "string"], "byteSize": nonnegative,
                "sha256": sha256, "uploaded": ["type": "boolean"],
            ]),
            "TransferReport": object(
                ["itemCount", "deckCount", "createdItemTypeCount", "reusedItemTypeCount", "warnings"],
                ["itemCount": nonnegative, "deckCount": nonnegative,
                 "createdItemTypeCount": nonnegative, "reusedItemTypeCount": nonnegative,
                 "warnings": array(["type": "string"])]
            ),
            "ImportJob": object(
                ["id", "revision", "format", "state", "files", "createdAt", "updatedAt"],
                ["id": uuid, "revision": revision, "format": ["type": "string"],
                 "state": ["type": "string"], "files": array(reference("ImportFile")),
                 "report": ["oneOf": [reference("TransferReport"), ["type": "null"]]],
                 "planToken": ["type": ["string", "null"]], "createdAt": timestamp, "updatedAt": timestamp]
            ),
            "CommitImportInput": object(["planToken"], ["planToken": ["type": "string"]]),
            "CreateExportInput": object(["format", "deckId"], [
                "format": ["type": "string", "const": "portableDeck"], "deckId": uuid,
            ]),
            "ExportJob": object(
                ["id", "revision", "format", "deckId", "state", "createdAt", "updatedAt"],
                ["id": uuid, "revision": revision, "format": ["type": "string", "const": "portableDeck"],
                 "deckId": uuid, "state": ["type": "string"],
                 "byteSize": ["type": ["integer", "null"], "minimum": 0],
                 "sha256": ["oneOf": [sha256, ["type": "null"]]],
                 "createdAt": timestamp, "updatedAt": timestamp]
            ),
            "Change": object(
                ["cursor", "transactionId", "sequence", "type", "resourceType", "resourceId", "revision", "tombstone", "occurredAt"],
                ["cursor": nonnegative, "transactionId": uuid, "sequence": nonnegative,
                 "type": ["type": "string"], "resourceType": ["type": "string"],
                 "resourceId": ["type": "string"], "revision": revision,
                 "tombstone": ["type": "boolean"], "occurredAt": timestamp]
            ),
            "ChangeCollection": collection("Change"),
            "ValidationError": object(["pointer", "code"], [
                "pointer": ["type": "string"], "code": ["type": "string"],
            ]),
            "Problem": object(
                ["type", "title", "status", "code", "detail", "requestId"],
                ["type": ["type": "string", "format": "uri"], "title": ["type": "string"],
                 "status": ["type": "integer", "minimum": 400, "maximum": 599],
                 "code": ["type": "string"], "detail": ["type": "string"],
                 "requestId": uuid, "errors": array(reference("ValidationError"))]
            ),
        ]
    }
}
