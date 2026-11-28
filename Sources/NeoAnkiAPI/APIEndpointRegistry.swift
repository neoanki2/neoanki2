import Foundation

package enum APIEndpointGroup: String, CaseIterable, Sendable {
    case discovery = "Discovery"
    case authentication = "Authentication and clients"
    case decks = "Decks"
    case itemTypes = "Item types"
    case items = "Items and tags"
    case study = "Cards and study"
    case scheduling = "Scheduling"
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
        case .scheduling: "scheduling"
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
    case createDeckResetPlan, commitDeckResetPlan, deckItemTypePolicy, setDeckItemTypePolicy, setItemTypeAvailability
    case listItemTypes, createItemType, validateItemType, getItemType
    case replaceItemType, deleteItemType, duplicateItemType
    case listItems, createItem, validateItem, bulkItems, getItem, replaceItem, deleteItem
    case duplicateChecks, listTags, renameTag, removeTag
    case listCards, getCard, patchCard, cardContent, reviewPreview, schedulingExplanation, resetCard
    case schedulingHealth, listSchedulingParameterSets, listSchedulingOptimizationRuns
    case createStudySession, getStudySession, endStudySession, nextStudyCard, skipStudyCard
    case submitReview, revertReview
    case listStudyResponses, getStudyResponse, deleteStudyResponse
    case downloadStudyResponse, headStudyResponse
    case uploadMedia, headMedia, downloadMedia, mediaMetadata
    case listKnownWords, getKnownWordsSnapshot, recordVocabularyJudgment, createVocabularySet
    case recordVocabularyJudgmentBatch, undoVocabularyJudgmentBatch
    case listVocabularyPacks, getVocabularyPack, deleteVocabularyPack
    case searchVocabularyEntries, getVocabularyEntry, resolveDictionaryForms, getVocabularyFrequencyBand
    case downloadVocabularyMedia, headVocabularyMedia
    case createVocabularyPackImport, getVocabularyPackImport, deleteVocabularyPackImport
    case uploadVocabularyPackFile, validateVocabularyPackImport, commitVocabularyPackImport
    case createImport, getImport, deleteImport, uploadImportFile, validateImport, commitImport
    case createExport, getExport, deleteExport, exportContent
    case changes, events

    package var additionalDescription: String? {
        switch self {
        case .createItem, .replaceItem, .validateItem:
            "Image occlusion values use type imageOcclusion with a still-image media reference, occlusionMode, masks, and nextGroup. Image descriptions (altText) are optional. Each stable mask group generates a separate recall card. Use type rows for a list defined on the item type."
        case .createItemType, .validateItemType, .replaceItemType:
            "Lists declare typed columns and optional shared rows. Templates select lists, checkbox filters, starting suspension, and a response override. Item rows use the list ID as their field ID."
        case .nextStudyCard:
            "Reserves an eligible card using family-aware daily introductions and related-review spacing. Poetry/prose builder cards retain eligibility and scheduling; included parts appear in source order across New/Review phases. Skipped and repair cards return on later passes. Image occlusion cards expose occlusionGroup alongside structured masks; render masks until answer reveal and conceal answerText before reveal."
        case .reviewPreview, .schedulingExplanation:
            "Successful independent-card recalls include deterministic ±15% operational interval variation. rawIntervalDays retains the FSRS estimate; finalDueAt and intervalPolicyVersion describe the committed policy. Again retains immediate repair. Recognized poetry/prose builder cards retain their existing intervals."
        case .cardContent:
            "Image occlusion cards expose occlusionGroup alongside structured masks; render masks until answer reveal and conceal answerText before reveal."
        case .bulkItems:
            "Optional order atomically reconciles one generated deck against complete expected item snapshots. Both dry runs and commits reject stale snapshots; only New-card introduction times are reordered."
        case .uploadMedia:
            "Media bytes must match the declared kind. An M4A or M4B major brand identifies M4A audio even when generic MP4 brands are listed for compatibility."
        case .listKnownWords:
            "Rows include state, the state of this exact term, and expressionState, the combined state of the spelling across all its meanings, which is the state to show for the word in text. Filter by expression to read one spelling; expression requires language and matches as a reader would, ignoring case, spacing, and, for Ukrainian, Russian, and Belarusian, stress marks and apostrophe variants. origin archivedReviews marks a word kept as known after the cards that proved it were deleted."
        case .getKnownWordsSnapshot:
            "Returns the combined reading state of every spelling (expressions) and dictionary form (lemmas) in one language, keyed by match key. Pass the version of a snapshot you hold as since; while it is still current the response contains only version, language, and unchanged true. To find the state of a word in text, use expressions for its match key; otherwise resolve its dictionary forms with a vocabulary pack and look each up in lemmas, then expressions. The word is known if every form is known or ignored and at least one is known, ignored if all are ignored, learning if any is learning, and unassessed otherwise."
        case .recordVocabularyJudgment:
            "Judgments are known, unfamiliar, ignored, or reviewHistory. Ignored hides a word, such as a name or brand, from reading highlights and word counts. term.lemma optionally records the dictionary form the spelling belongs to. Other judgment values are rejected."
        case .recordVocabularyJudgmentBatch:
            "Records 1 to 20,000 judgments in one change. The Idempotency-Key identifies the batch: retrying it returns the first receipt. Judgments that already apply are counted as unchanged and not written again. Use batchId to undo the whole change."
        case .undoVocabularyJudgmentBatch:
            "Restores the judgment each word had before the batch, except for words changed again since, which are counted as unchanged. The receipt describes the undo, whose batchId is new; retrying with the same Idempotency-Key returns the same receipt."
        case .resolveDictionaryForms:
            "Maps up to 2,000 words from text to the dictionary forms the pack lists for them, at most eight each. Matching ignores case and, where dictionaries mark stress, the stress marks that ordinary text omits. Words the pack does not contain are omitted from data."
        case .getVocabularyFrequencyBand:
            "Lists the pack's dictionary forms for a language from most to least frequent. offset and limit (1 to 20,000, default 1,000) select a band; sample instead returns that many evenly spaced words from the band, for placement checks. total counts every ranked form in the language."
        default:
            nil
        }
    }
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
