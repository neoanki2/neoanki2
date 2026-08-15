import Foundation

package enum APIEndpointGroup: String, CaseIterable, Sendable {
    case discovery = "Discovery"
    case authentication = "Authentication and clients"
    case decks = "Decks"
    case itemTypes = "Item types"
    case items = "Items and tags"
    case study = "Cards and study"
    case responses = "Responses and media"
    case vocabulary = "Vocabulary"
    case transfers = "Import and export"
    case events = "Changes and events"

    package var slug: String {
        switch self {
        case .discovery: "discovery"
        case .authentication: "authentication"
        case .decks: "decks"
        case .itemTypes: "item-types"
        case .items: "items-and-tags"
        case .study: "cards-and-study"
        case .responses: "responses-and-media"
        case .vocabulary: "vocabulary"
        case .transfers: "import-and-export"
        case .events: "changes-and-events"
        }
    }
}

package enum APIEndpointAuthorization: Sendable, Equatable {
    case publicAccess
    case authenticated
    case scope(APIScope)
    case anyOf([APIScope])

    package var requiredScope: String? {
        switch self {
        case .publicAccess: nil
        case .authenticated: "any"
        case let .scope(scope): scope.rawValue
        case let .anyOf(scopes): scopes.map(\.rawValue).joined(separator: " or ")
        }
    }

    package var isProtected: Bool { self != .publicAccess }
}

/// Exhaustive identifiers for HTTP handlers exposed by version 1.
///
/// `APIOpenAPI` refuses to build an endpoint whose operation identifier is not
/// represented here. Contract tests also require every case to appear exactly
/// once, making this the compiler-checked inventory for the public HTTP surface.
package enum APIEndpointHandler: String, CaseIterable, Sendable {
    case health, meta, openapi, pair, currentClient, revokeCurrentClient
    case listDecks, createDeck, getDeck, updateDeck
    case createDeckDeletionPlan, commitDeckDeletionPlan
    case createDeckResetPlan, commitDeckResetPlan, deckItemTypePolicy
    case listItemTypes, createItemType, validateItemType, getItemType
    case replaceItemType, deleteItemType, duplicateItemType
    case listItems, createItem, validateItem, bulkItems, getItem, replaceItem, deleteItem
    case duplicateChecks, listTags, renameTag, removeTag
    case listCards, getCard, patchCard, cardContent, reviewPreview, resetCard
    case createStudySession, getStudySession, endStudySession, nextStudyCard, skipStudyCard
    case submitReview, revertReview
    case listStudyResponses, getStudyResponse, deleteStudyResponse
    case downloadStudyResponse, headStudyResponse
    case uploadMedia, headMedia, downloadMedia, mediaMetadata
    case listVocabularyPacks, getVocabularyPack, deleteVocabularyPack
    case searchVocabularyEntries, getVocabularyEntry
    case downloadVocabularyMedia, headVocabularyMedia
    case createVocabularyPackImport, getVocabularyPackImport, deleteVocabularyPackImport
    case uploadVocabularyPackFile, validateVocabularyPackImport, commitVocabularyPackImport
    case createImport, getImport, deleteImport, uploadImportFile, validateImport, commitImport
    case createExport, getExport, deleteExport, exportContent
    case changes, events
}

package struct APIEndpointParameter: Sendable, Equatable {
    package let name: String
    package let location: String
    package let isRequired: Bool
    package let description: String
}

package struct APIEndpointDefinition: Sendable, Equatable {
    package let pathTemplate: String
    package let method: APIHTTPMethod
    package let handler: APIEndpointHandler
    package let group: APIEndpointGroup
    package let summary: String
    package let description: String
    package let requiredScope: String?
    package let parameters: [APIEndpointParameter]
    package let acceptsRequestBody: Bool
    package let successStatus: Int
    package let requestSchema: String?
    package let responseSchema: String?
    package let successHeaders: [String]
    package let errorResponses: [String]

    package var operationID: String { handler.rawValue }

    package var queryParameters: Set<String> {
        Set(parameters.lazy.filter { $0.location == "query" }.map(\.name))
    }

    package func matches(path: String) -> Bool {
        let expected = pathTemplate.split(separator: "/", omittingEmptySubsequences: false)
        let actual = path.split(separator: "/", omittingEmptySubsequences: false)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).allSatisfy { component, candidate in
            (component.hasPrefix("{") && component.hasSuffix("}")) || component == candidate
        }
    }
}
