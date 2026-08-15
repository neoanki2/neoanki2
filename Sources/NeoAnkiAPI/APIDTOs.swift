import Foundation
import NeoAnkiApplication
import NeoAnkiCore

public struct APIHealth: Codable, Sendable, Equatable {
    public let status: String
}

public struct APIMeta: Codable, Sendable, Equatable {
    public let apiVersion: Int
    public let applicationVersion: String
    public let serverInstanceId: String
    public let pairingAvailable: Bool
    public let capabilities: [String]
}

struct PairingInput: Decodable {
    let displayName: String
    let requestedScopes: [APIScope]
    let origin: String?
}

public struct APIPairingResult: Codable, Sendable, Equatable {
    public let client: APIClient
    public let token: String
}

public struct APIClient: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let origin: String?
    public let scopes: [APIScope]
    public let createdAt: Date
    public let revision: Int

    init(_ grant: APIClientGrant) {
        id = grant.id.uuidString.lowercased()
        displayName = grant.displayName
        origin = grant.origin
        scopes = grant.scopes.sorted { $0.rawValue < $1.rawValue }
        createdAt = grant.createdAt
        revision = grant.revision
    }
}

public struct APIDeck: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let name: String
    public let parentId: String?
    public let newCardsPerDay: Int?
    public let directItemCount: Int
    public let recursiveItemCount: Int
    public let dueCount: Int
    public let childIds: [String]
}

struct CreateDeckInput: Decodable {
    let id: String?
    let name: String
    let parentId: String?
    let newCardsPerDay: Int?
}

enum OptionalPatch<Value: Decodable>: Decodable {
    case value(Value?)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .value(nil)
        } else {
            self = .value(try container.decode(Value.self))
        }
    }
}

struct UpdateDeckInput: Decodable {
    let name: String?
    let parentId: OptionalPatch<String>?
    let newCardsPerDay: OptionalPatch<Int>?

    private enum CodingKeys: String, CodingKey {
        case name, parentId, newCardsPerDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        parentId = container.contains(.parentId)
            ? try OptionalPatch(from: container.superDecoder(forKey: .parentId))
            : nil
        newCardsPerDay = container.contains(.newCardsPerDay)
            ? try OptionalPatch(from: container.superDecoder(forKey: .newCardsPerDay))
            : nil
    }
}

struct CreateDeckDeletionPlanInput: Decodable {
    let deckId: String
    let policy: DeckDeletionPolicy
}

struct CommitDeckDeletionPlanInput: Decodable {
    let confirm: Bool?
}

public struct APIDeckDeletionPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let deckId: String
    public let policy: DeckDeletionPolicy
    public let impact: DeckDeletionImpact
    public let deckRevision: Int
    public let dependencyChangeCursor: Int64
    public let expiresAt: Date
}

struct CreateDeckResetPlanInput: Decodable {
    let deckId: String
}

struct CommitDeckResetPlanInput: Decodable {
    let confirm: Bool
}

public struct APIDeckResetPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let deckId: String
    public let impact: DeckResetImpact
    public let deckRevision: Int
    public let dependencyChangeCursor: Int64
    public let expiresAt: Date
}

public struct APIPlanCommitResult<Impact: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let planId: String
    public let committed: Bool
    public let impact: Impact
}

enum APIStudyScopeKind: String, Codable, Sendable {
    case allDecks
    case unassigned
    case deck
}

struct APIStudyScopeInput: Decodable {
    let kind: APIStudyScopeKind
    let deckId: String?
    let includeDescendants: Bool?
}

struct CreateStudySessionInput: Decodable {
    let scope: APIStudyScopeInput
}

public struct APIStudyScope: Codable, Sendable, Equatable {
    public let kind: String
    public let deckId: String?
    public let includeDescendants: Bool?

    init(_ scope: DeckScope) {
        switch scope {
        case .allDecks:
            kind = "allDecks"
            deckId = nil
            includeDescendants = nil
        case .unassigned:
            kind = "unassigned"
            deckId = nil
            includeDescendants = nil
        case let .deck(id, includeDescendants):
            kind = "deck"
            deckId = id.uuidString.lowercased()
            self.includeDescendants = includeDescendants
        }
    }
}

public struct APIStudySession: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let scope: APIStudyScope
    public let state: String
    public let currentCardId: String?
    public let createdAt: Date
    public let lastActivityAt: Date

    init(_ session: StudySessionRecord) {
        id = session.id.uuidString.lowercased()
        revision = session.revision
        scope = APIStudyScope(session.scope)
        state = session.state.rawValue
        currentCardId = session.currentCardID?.uuidString.lowercased()
        createdAt = session.createdAt
        lastActivityAt = session.lastActivityAt
    }
}

public struct APIMemory: Codable, Sendable, Equatable {
    public let stabilityDays: Double
    public let difficulty: Double
    public let dueAt: Date
    public let lastReviewedAt: Date?
    public let repetitions: Int
    public let lapses: Int
    public let phase: String
    public let stepIndex: Int?

    init(_ memory: MemoryState) {
        stabilityDays = memory.stability
        difficulty = memory.difficulty
        dueAt = memory.due
        lastReviewedAt = memory.lastReview
        repetitions = memory.reps
        lapses = memory.lapses
        phase = memory.phase.rawValue
        stepIndex = memory.stepIndex
    }
}

public struct APIResolvedSlot: Codable, Sendable, Equatable {
    public let value: ContentValue
    public let presentation: Presentation

    init(_ slot: ResolvedSlot) {
        value = slot.value
        presentation = slot.presentation
    }
}

public struct APIStudyCard: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let itemId: String
    public let templateId: String
    public let deckId: String?
    public let clozeGroup: Int?
    public let interaction: String
    public let prompt: [APIResolvedSlot]
    public let answer: [APIResolvedSlot]
    public let memory: APIMemory

    init(_ due: DueCard, revision: Int) {
        id = due.card.id.uuidString.lowercased()
        self.revision = revision
        itemId = due.item.id.uuidString.lowercased()
        templateId = due.template.id.uuidString.lowercased()
        deckId = due.card.deckID?.uuidString.lowercased()
        clozeGroup = due.card.clozeGroup
        interaction = due.template.interaction.rawValue
        prompt = SideContent.resolvedSlots(for: due.template.prompt, from: due.item)
            .map(APIResolvedSlot.init)
        answer = SideContent.resolvedSlots(for: due.template.answer, from: due.item)
            .map(APIResolvedSlot.init)
        memory = APIMemory(due.card.memory)
    }
}

struct SkipStudyCardInput: Decodable {
    let cardId: String
}

enum APIReviewRating: String, Decodable {
    case again, hard, good, easy

    var domain: ReviewRating {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }
}

struct SubmitReviewInput: Decodable {
    let sessionId: String
    let cardId: String
    let rating: APIReviewRating
    let durationMs: Int
}

public struct APIReviewResult: Codable, Sendable, Equatable {
    public let reviewLogId: String
    public let revision: Int
    public let previousPhase: String
    public let resultingPhase: String
    public let memory: APIMemory
    public let changeCursor: Int64
}

struct RevertReviewInput: Decodable {
    let confirm: Bool
}

public struct APIContentValue: Codable, Sendable, Equatable {
    public let type: String
    public let text: String?
    public let lang: String?
    public let spans: [Span]?
    public let mediaId: String?
    public let kind: String?
    public let sha256: String?
    public let fileExtension: String?
    public let durationMs: Int?
    public let altText: String?
    public let reservationId: String?
    public let blanks: [ClozeSpan]?
    public let number: Double?

    init(_ value: ContentValue) {
        var type = "empty"
        var text: String?
        var lang: String?
        var spans: [Span]?
        var mediaId: String?
        var kind: String?
        var sha256: String?
        var fileExtension: String?
        var durationMs: Int?
        var altText: String?
        var reservationId: String?
        var blanks: [ClozeSpan]?
        var number: Double?
        switch value {
        case .empty:
            break
        case let .text(value, language):
            type = "text"; text = value; lang = language
        case let .rich(value):
            type = "rich"; spans = value
        case let .media(ref):
            type = "media"
            mediaId = ref.id.uuidString.lowercased()
            kind = ref.kind.rawValue
            sha256 = ref.assetHash
            fileExtension = ref.fileExtension
            durationMs = ref.durationMs
            altText = ref.altText
            reservationId = nil
        case let .cloze(value, valueBlanks):
            type = "cloze"; text = value; blanks = valueBlanks
        case let .number(value):
            type = "number"; number = value
        }
        self.type = type
        self.text = text
        self.lang = lang
        self.spans = spans
        self.mediaId = mediaId
        self.kind = kind
        self.sha256 = sha256
        self.fileExtension = fileExtension
        self.durationMs = durationMs
        self.altText = altText
        self.reservationId = reservationId
        self.blanks = blanks
        self.number = number
    }

    func domain(pointer: String) throws -> ContentValue {
        switch type {
        case "empty":
            return .empty
        case "text":
            guard let text else { throw APIServiceError.validation("Text is required.", pointer: pointer + "/text") }
            return .text(text, lang: lang)
        case "rich":
            guard let spans else { throw APIServiceError.validation("Spans are required.", pointer: pointer + "/spans") }
            return .rich(spans)
        case "media":
            guard let mediaId, let id = UUID(uuidString: mediaId),
                  id.uuidString.lowercased() == mediaId,
                  let kind, let mediaKind = MediaKind(rawValue: kind),
                  let sha256, let fileExtension
            else {
                throw APIServiceError.validation("A complete media reference is required.", pointer: pointer)
            }
            var reference = MediaRef(
                id: id,
                kind: mediaKind,
                assetHash: sha256,
                fileExtension: fileExtension,
                durationMs: durationMs,
                altText: altText
            )
            if let reservationId {
                guard let reservationID = UUID(uuidString: reservationId),
                      reservationID.uuidString.lowercased() == reservationId
                else {
                    throw APIServiceError.validation(
                        "Expected a lowercase reservation UUID.",
                        pointer: pointer + "/reservationId"
                    )
                }
                reference = reference.attachingReservation(reservationID)
            }
            return .media(reference)
        case "cloze":
            guard let text, let blanks else { throw APIServiceError.validation("Cloze text and blanks are required.", pointer: pointer) }
            return .cloze(text, blanks: blanks)
        case "number":
            guard let number, number.isFinite else { throw APIServiceError.validation("A finite number is required.", pointer: pointer + "/number") }
            return .number(number)
        default:
            throw APIServiceError.validation("Unknown content value type.", pointer: pointer + "/type")
        }
    }
}

public struct APIFieldValue: Codable, Sendable, Equatable {
    public let fieldId: String
    public let value: APIContentValue

    init(_ field: FieldValue) {
        fieldId = field.fieldID.uuidString.lowercased()
        value = APIContentValue(field.value)
    }
}

public struct APIItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let itemTypeId: String
    public let deckId: String?
    public let fields: [APIFieldValue]
    public let tags: [String]
    public let createdAt: Date
    public let updatedAt: Date
    public let cardIds: [String]

    init(_ record: LibraryItemRecord, revision: Int) {
        id = record.item.id.uuidString.lowercased()
        self.revision = revision
        itemTypeId = record.item.itemTypeID.uuidString.lowercased()
        deckId = record.item.deckID?.uuidString.lowercased()
        fields = record.item.fields.map(APIFieldValue.init)
        tags = record.item.tags
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        cardIds = record.cardIDs.map { $0.uuidString.lowercased() }
    }
}

struct CreateItemInput: Decodable {
    let id: String?
    let itemTypeId: String
    let deckId: String?
    let fields: [APIFieldValue]
    let tags: [String]
}

struct PutItemInput: Decodable {
    let itemTypeId: String
    let deckId: String?
    let fields: [APIFieldValue]
    let tags: [String]
}

struct DuplicateCheckInput: Decodable {}

public struct APIDuplicateCandidate: Codable, Sendable, Equatable {
    public let itemId: String
    public let reasonCodes: [String]
}

public struct APIDuplicateCheckResult: Codable, Sendable, Equatable {
    public let candidates: [APIDuplicateCandidate]
}

struct BulkItemOperationInput: Decodable {
    let operationId: String
    let action: String
    let item: CreateItemInput?
    let itemId: String?
}

struct BulkItemsInput: Decodable {
    let atomic: Bool
    let dryRun: Bool
    let operations: [BulkItemOperationInput]
}

public struct APIBulkItemResult: Codable, Sendable, Equatable {
    public let operationId: String
    public let action: String
    public let itemId: String
    public let cardIds: [String]

    init(_ result: ItemBulkOperationResult) {
        operationId = result.operationID
        action = result.action
        itemId = result.itemID.uuidString.lowercased()
        cardIds = result.cardIDs.map { $0.uuidString.lowercased() }
    }
}

public struct APIBulkItemImpact: Codable, Sendable, Equatable {
    public let createdItemCount: Int
    public let replacedItemCount: Int
    public let deletedItemCount: Int
    public let resultingCardCount: Int
}

public struct APIBulkItemsResult: Codable, Sendable, Equatable {
    public let dryRun: Bool
    public let results: [APIBulkItemResult]
    public let impact: APIBulkItemImpact
}

public struct APICard: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let itemId: String
    public let templateId: String
    public let deckId: String?
    public let clozeGroup: Int?
    public let skill: Skill
    public let isSuspended: Bool
    public let memory: APIMemory

    init(_ card: Card, revision: Int) {
        id = card.id.uuidString.lowercased()
        self.revision = revision
        itemId = card.itemID.uuidString.lowercased()
        templateId = card.templateID.uuidString.lowercased()
        deckId = card.deckID?.uuidString.lowercased()
        clozeGroup = card.clozeGroup
        skill = card.skill
        isSuspended = card.isSuspended
        memory = APIMemory(card.memory)
    }
}

struct PatchCardInput: Decodable {
    let isSuspended: Bool
}

struct ResetCardInput: Decodable {
    let confirm: Bool
}

public struct APIRatingPreview: Codable, Sendable, Equatable {
    public let rating: String
    public let reviewedAt: Date
    public let intervalSeconds: Double
    public let rawIntervalDays: Double
    public let operationalIntervalSeconds: Int
    public let memoryBefore: APIMemory
    public let memoryAfter: APIMemory
    public let memory: APIMemory
    public let predictedRetrievability: Double
    public let presetId: String?
    public let parameterSetId: String?
    public let modelVersion: String
    public let timingPolicyVersion: String
    public let intervalPolicyVersion: String
    public let finalDueAt: Date
    public let constraintReason: String?

    init(rating: String, preview: ReviewSchedulePreview) {
        self.rating = rating
        reviewedAt = preview.reviewedAt
        intervalSeconds = preview.intervalSeconds
        rawIntervalDays = preview.rawIntervalDays
        operationalIntervalSeconds = preview.operationalIntervalSeconds
        memoryBefore = APIMemory(preview.memoryBefore)
        memoryAfter = APIMemory(preview.memoryAfter)
        memory = memoryAfter
        predictedRetrievability = preview.predictedRetrievability
        presetId = preview.presetID?.uuidString.lowercased()
        parameterSetId = preview.parameterSetID?.uuidString.lowercased()
        modelVersion = preview.modelVersion
        timingPolicyVersion = preview.timingPolicyVersion
        intervalPolicyVersion = preview.intervalPolicyVersion
        finalDueAt = preview.finalDueAt
        constraintReason = preview.constraintReason
    }
}

public struct APISchedulingExplanation: Codable, Sendable, Equatable {
    public let cardId: String
    public let reviewedAt: Date
    public let elapsedSeconds: Double
    public let elapsedModelDays: Int
    public let previousMemory: APIMemory
    public let desiredRetention: Double
    public let modelIdentifier: String
    public let elapsedTimePolicy: String
    public let intervalPolicy: String
    public let presetId: String?
    public let parameterSetId: String?
    public let ratings: [APIRatingPreview]
}

public struct APISchedulingHealth: Codable, Sendable, Equatable {
    public let modelIdentifier: String
    public let desiredRetention: Double
    public let maximumIntervalDays: Int
    public let automaticOptimizationEnabled: Bool
    public let parameterCount: Int
    public let parameterSource: String
    public let activeParameterSetId: String?
    public let activeParameterSource: String?
    public let optimizerParityVerified: Bool
    public let optimizerStatus: String
    public let personalizationStatus: String
    public let lastOptimizationDecision: String?
    public let lastOptimizationReason: String?
    public let lastOptimizationCompletedAt: Date?
    public let migrationStatus: String?
    public let legacyParametersQuarantined: Bool
    public let canRestoreDefaults: Bool
    public let canRollback: Bool

    init(_ health: LibrarySchedulingHealth) {
        modelIdentifier = health.modelIdentifier
        desiredRetention = health.desiredRetention
        maximumIntervalDays = health.maximumIntervalDays
        automaticOptimizationEnabled = health.automaticOptimizationEnabled
        parameterCount = health.parameterCount
        parameterSource = health.usesPopulationDefaults ? "populationDefaults" : "personalized"
        activeParameterSetId = health.activeParameterSetID?.uuidString.lowercased()
        activeParameterSource = health.activeParameterSource
        optimizerParityVerified = health.optimizerParityVerified
        optimizerStatus = health.optimizerStatus
        personalizationStatus = health.optimizerParityVerified
            ? (health.usesPopulationDefaults ? "populationDefaults" : "personalized")
            : "unavailablePendingVerification"
        lastOptimizationDecision = health.lastOptimizationDecision
        lastOptimizationReason = health.lastOptimizationReason
        lastOptimizationCompletedAt = health.lastOptimizationCompletedAt
        migrationStatus = health.migrationStatus
        legacyParametersQuarantined = health.legacyParametersQuarantined
        canRestoreDefaults = health.canRestoreDefaults
        canRollback = health.canRollback
    }
}

public struct APIFSRSParameterSet: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let isActive: Bool
    public let weights: [Double]
    public let modelVersion: String
    public let upstreamCommit: String
    public let sourceChecksum: String
    public let fixtureChecksum: String?
    public let scope: String
    public let source: String
    public let inputFingerprint: String?
    public let trainingCutoff: Date?
    public let metrics: [String: Double]
    public let previousParameterSetId: String?
    public let createdAt: Date

    init(_ value: LibraryFSRSParameterSet) {
        id = value.id.uuidString.lowercased()
        isActive = value.isActive
        weights = value.weights
        modelVersion = value.modelVersion
        upstreamCommit = value.upstreamCommit
        sourceChecksum = value.sourceChecksum
        fixtureChecksum = value.fixtureChecksum
        scope = value.scope
        source = value.source
        inputFingerprint = value.inputFingerprint
        trainingCutoff = value.trainingCutoff
        metrics = value.metrics
        previousParameterSetId = value.previousParameterSetID?.uuidString.lowercased()
        createdAt = value.createdAt
    }
}

public struct APIFSRSOptimizationRun: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let presetId: String
    public let startedAt: Date
    public let completedAt: Date
    public let trainingCutoff: Date
    public let inputFingerprint: String
    public let eligibleTargetCount: Int
    public let distinctCardCount: Int
    public let failureCount: Int
    public let studyDayCount: Int
    public let excludedCounts: [String: Int]
    public let foldCount: Int
    public let metrics: [String: Double]
    public let decision: String
    public let reason: String?
    public let candidateParameterSetId: String?

    init(_ value: LibraryFSRSOptimizationRun) {
        id = value.id.uuidString.lowercased()
        presetId = value.presetID.uuidString.lowercased()
        startedAt = value.startedAt
        completedAt = value.completedAt
        trainingCutoff = value.trainingCutoff
        inputFingerprint = value.inputFingerprint
        eligibleTargetCount = value.eligibleTargetCount
        distinctCardCount = value.distinctCardCount
        failureCount = value.failureCount
        studyDayCount = value.studyDayCount
        excludedCounts = value.excludedCounts
        foldCount = value.foldCount
        metrics = value.metrics
        decision = value.decision
        reason = value.reason
        candidateParameterSetId = value.candidateParameterSetID?.uuidString.lowercased()
    }
}

struct RestoreDefaultSchedulingInput: Decodable {
    let confirm: Bool
}

struct RollbackSchedulingInput: Decodable {
    let confirm: Bool
    let parameterSetId: String?
}

public struct APITag: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let itemCount: Int
    public let revision: Int
}

struct RenameTagInput: Decodable {
    let from: String
    let to: String
}

public struct APIFieldDefinition: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let isRequired: Bool

    init(_ field: FieldDef) {
        id = field.id.uuidString.lowercased()
        name = field.name
        type = field.type.rawValue
        isRequired = field.isRequired
    }

    func domain(parseUUID: (String, String) throws -> UUID, pointer: String) throws -> FieldDef {
        guard let type = FieldType(rawValue: type) else {
            throw APIServiceError.validation("Unknown field type.", pointer: pointer + "/type")
        }
        return FieldDef(
            id: try parseUUID(id, pointer + "/id"),
            name: name,
            type: type,
            isRequired: isRequired
        )
    }
}

public struct APISkill: Codable, Sendable, Equatable {
    public let input: String
    public let output: String
    public let operation: String

    init(_ skill: Skill) {
        input = skill.input.rawValue
        output = skill.output.rawValue
        operation = skill.operation.rawValue
    }

    func domain(pointer: String) throws -> Skill {
        guard let input = Modality(rawValue: input),
              let output = Modality(rawValue: output),
              let operation = Operation(rawValue: operation)
        else {
            throw APIServiceError.validation("Unknown skill member.", pointer: pointer)
        }
        return Skill(input: input, output: output, operation: operation)
    }
}

public struct APISlotSource: Codable, Sendable, Equatable {
    public let kind: String
    public let fieldId: String?
    public let text: String?

    init(_ source: SlotSource) {
        switch source {
        case let .field(id):
            kind = "field"; fieldId = id.uuidString.lowercased(); text = nil
        case let .literal(value):
            kind = "literal"; fieldId = nil; text = value
        }
    }

    func domain(parseUUID: (String, String) throws -> UUID, pointer: String) throws -> SlotSource {
        switch kind {
        case "field":
            guard let fieldId, text == nil else {
                throw APIServiceError.validation("Field source requires only fieldId.", pointer: pointer)
            }
            return .field(try parseUUID(fieldId, pointer + "/fieldId"))
        case "literal":
            guard let text, fieldId == nil else {
                throw APIServiceError.validation("Literal source requires only text.", pointer: pointer)
            }
            return .literal(text)
        default:
            throw APIServiceError.validation("Unknown slot source.", pointer: pointer + "/kind")
        }
    }
}

public struct APIPresentation: Codable, Sendable, Equatable {
    public let reveal: String
    public let media: String

    init(_ presentation: Presentation) {
        reveal = presentation.reveal.rawValue
        media = presentation.media.rawValue
    }

    func domain(pointer: String) throws -> Presentation {
        guard let reveal = RevealMode(rawValue: reveal),
              let media = MediaBehavior(rawValue: media)
        else {
            throw APIServiceError.validation("Unknown presentation member.", pointer: pointer)
        }
        return Presentation(reveal: reveal, media: media)
    }
}

public struct APISlot: Codable, Sendable, Equatable {
    public let source: APISlotSource
    public let presentation: APIPresentation

    init(_ slot: Slot) {
        source = APISlotSource(slot.source)
        presentation = APIPresentation(slot.presentation)
    }

    func domain(parseUUID: (String, String) throws -> UUID, pointer: String) throws -> Slot {
        Slot(
            source: try source.domain(parseUUID: parseUUID, pointer: pointer + "/source"),
            presentation: try presentation.domain(pointer: pointer + "/presentation")
        )
    }
}

public struct APICondition: Codable, Sendable, Equatable {
    public let kind: String
    public let fieldId: String?
    public let conditions: [APICondition]?

    init(_ condition: SlotCondition) {
        switch condition {
        case let .fieldNotEmpty(id):
            kind = "fieldNotEmpty"; fieldId = id.uuidString.lowercased(); conditions = nil
        case let .fieldEmpty(id):
            kind = "fieldEmpty"; fieldId = id.uuidString.lowercased(); conditions = nil
        case let .all(values):
            kind = "all"; fieldId = nil; conditions = values.map(APICondition.init)
        case let .any(values):
            kind = "any"; fieldId = nil; conditions = values.map(APICondition.init)
        }
    }

    func domain(parseUUID: (String, String) throws -> UUID, pointer: String) throws -> SlotCondition {
        switch kind {
        case "fieldNotEmpty":
            guard let fieldId, conditions == nil else { throw APIServiceError.validation("Invalid condition.", pointer: pointer) }
            return .fieldNotEmpty(try parseUUID(fieldId, pointer + "/fieldId"))
        case "fieldEmpty":
            guard let fieldId, conditions == nil else { throw APIServiceError.validation("Invalid condition.", pointer: pointer) }
            return .fieldEmpty(try parseUUID(fieldId, pointer + "/fieldId"))
        case "all":
            guard fieldId == nil, let conditions else { throw APIServiceError.validation("Invalid condition.", pointer: pointer) }
            return .all(try conditions.enumerated().map { try $0.element.domain(parseUUID: parseUUID, pointer: pointer + "/conditions/\($0.offset)") })
        case "any":
            guard fieldId == nil, let conditions else { throw APIServiceError.validation("Invalid condition.", pointer: pointer) }
            return .any(try conditions.enumerated().map { try $0.element.domain(parseUUID: parseUUID, pointer: pointer + "/conditions/\($0.offset)") })
        default:
            throw APIServiceError.validation("Unknown condition.", pointer: pointer + "/kind")
        }
    }
}

public struct APITemplateDefinition: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let prompt: [APISlot]
    public let answer: [APISlot]
    public let interaction: String
    public let skill: APISkill
    public let generateWhen: APICondition?

    init(_ template: Template) {
        id = template.id.uuidString.lowercased()
        name = template.name
        prompt = template.prompt.slots.map(APISlot.init)
        answer = template.answer.slots.map(APISlot.init)
        interaction = template.interaction.rawValue
        skill = APISkill(template.skill)
        generateWhen = template.generateWhen.map(APICondition.init)
    }

    func domain(parseUUID: (String, String) throws -> UUID, pointer: String) throws -> Template {
        guard let interaction = Interaction(rawValue: interaction) else {
            throw APIServiceError.validation("Unknown interaction.", pointer: pointer + "/interaction")
        }
        return Template(
            id: try parseUUID(id, pointer + "/id"),
            name: name,
            prompt: Side(slots: try prompt.enumerated().map { try $0.element.domain(parseUUID: parseUUID, pointer: pointer + "/prompt/\($0.offset)") }),
            answer: Side(slots: try answer.enumerated().map { try $0.element.domain(parseUUID: parseUUID, pointer: pointer + "/answer/\($0.offset)") }),
            interaction: interaction,
            skill: try skill.domain(pointer: pointer + "/skill"),
            generateWhen: try generateWhen?.domain(parseUUID: parseUUID, pointer: pointer + "/generateWhen")
        )
    }
}

public struct APIItemType: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let name: String
    public let fields: [APIFieldDefinition]
    public let templates: [APITemplateDefinition]
    public let provenance: String
    public let itemCount: Int

    init(_ itemType: ItemType, revision: Int, itemCount: Int, provenance: String = "library") {
        id = itemType.id.uuidString.lowercased()
        self.revision = revision
        name = itemType.name
        fields = itemType.fields.map(APIFieldDefinition.init)
        templates = itemType.templates.map(APITemplateDefinition.init)
        self.provenance = provenance
        self.itemCount = itemCount
    }
}

struct ItemTypeInput: Decodable {
    let id: String?
    let name: String
    let fields: [APIFieldDefinition]
    let templates: [APITemplateDefinition]
}

struct DuplicateItemTypeInput: Decodable {
    let name: String
}

public struct APIImpactSummary: Codable, Sendable, Equatable {
    public let affectedItemCount: Int
    public let affectedCardCount: Int
    public let affectedStudyResponseCount: Int
}

public struct APIItemTypePolicy: Codable, Sendable, Equatable {
    public let sourceDeckId: String?
    public let defaultItemTypeId: String?
    public let itemTypeIds: [String]
}

public struct APIMediaReservation: Codable, Sendable, Equatable {
    public let assetHash: String
    public let kind: String
    public let fileExtension: String
    public let byteSize: Int
    public let reservationId: String
    public let reservationExpiresAt: Date

    init(_ reserved: ReservedMediaAsset) {
        assetHash = reserved.reference.assetHash
        kind = reserved.reference.kind.rawValue
        fileExtension = reserved.reference.fileExtension
        byteSize = reserved.byteSize
        reservationId = reserved.reservationID.uuidString.lowercased()
        reservationExpiresAt = reserved.reservationExpiresAt
    }
}

public struct APIMediaMetadata: Codable, Sendable, Equatable {
    public let assetHash: String
    public let kind: String
    public let fileExtension: String
    public let byteSize: Int
    public let referenceCount: Int

    init(_ asset: MediaAsset) {
        assetHash = asset.hash
        kind = asset.kind.rawValue
        fileExtension = asset.fileExtension
        byteSize = asset.byteSize
        referenceCount = asset.refCount
    }
}

public struct APIChange: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64 { cursor }
    public let cursor: Int64
    public let transactionId: String
    public let sequence: Int
    public let type: String
    public let resourceType: String
    public let resourceId: String
    public let revision: Int
    public let tombstone: Bool
    public let occurredAt: Date

    init(_ change: LibraryChange) {
        cursor = change.cursor
        transactionId = change.transactionID.uuidString.lowercased()
        sequence = change.sequence
        type = change.eventType
        resourceType = change.resourceType
        resourceId = UUID(uuidString: change.resourceID)?.uuidString.lowercased()
            ?? change.resourceID
        revision = change.revision
        tombstone = change.isTombstone
        occurredAt = change.occurredAt
    }
}

public struct APIStudyResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let cardId: String
    public let itemId: String
    public let assetHash: String
    public let contentType: String
    public let fileExtension: String
    public let byteSize: Int
    public let durationMs: Int
    public let capturedAt: Date
    public let submittedAt: Date
    public let sourceTitle: String

    init(_ response: StudyResponse, revision: Int) {
        id = response.id.uuidString.lowercased()
        self.revision = revision
        cardId = response.cardID.uuidString.lowercased()
        itemId = response.itemID.uuidString.lowercased()
        assetHash = response.mediaHash
        contentType = "audio/mp4"
        fileExtension = response.fileExtension
        byteSize = response.byteSize
        durationMs = response.durationMilliseconds
        capturedAt = response.capturedAt
        submittedAt = response.submittedAt
        sourceTitle = response.sourceTitle
    }
}

enum APIImportFormat: String, Codable, Sendable {
    case json, csv, authoredDeck, portableDeck
}

struct APIImportFileDeclarationInput: Decodable {
    let relativePath: String
    let byteSize: Int
    let sha256: String
}

struct CreateImportJobInput: Decodable {
    let format: APIImportFormat
    let itemTypeId: String?
    let csvItemTypeName: String?
    let destinationDeckId: String?
    let files: [APIImportFileDeclarationInput]
}

struct CommitImportJobInput: Decodable {
    let planToken: String
}

public struct APIImportFile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let relativePath: String
    public let byteSize: Int
    public let sha256: String
    public let uploaded: Bool
}

public struct APITransferReport: Codable, Sendable, Equatable {
    public let itemCount: Int
    public let deckCount: Int
    public let createdItemTypeCount: Int
    public let reusedItemTypeCount: Int
    public let warnings: [String]
}

public struct APIImportJob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let format: String
    public let state: String
    public let files: [APIImportFile]
    public let report: APITransferReport?
    public let planToken: String?
    public let createdAt: Date
    public let updatedAt: Date
}

struct CreateExportJobInput: Decodable {
    let format: String
    let deckId: String
}

public struct APIExportJob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let format: String
    public let deckId: String
    public let state: String
    public let byteSize: Int?
    public let sha256: String?
    public let createdAt: Date
    public let updatedAt: Date
}

struct APICursor: Codable, Sendable, Equatable {
    let route: String
    let offset: Int
    let libraryId: String

    func encoded(secret: String) throws -> String {
        let payload = try APIJSON.encoder.encode(self)
        let envelope = SignedAPICursor(
            payload: payload,
            signature: APICrypto.hmacSHA256Hex(key: Data(secret.utf8), data: payload)
        )
        return try APIJSON.encoder.encode(envelope)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(
        _ value: String,
        route: String,
        libraryId: String,
        secret: String
    ) throws -> APICursor {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard
            let data = Data(base64Encoded: base64),
            let envelope = try? APIJSON.decoder.decode(SignedAPICursor.self, from: data),
            APICrypto.hmacSHA256Hex(key: Data(secret.utf8), data: envelope.payload)
                == envelope.signature,
            let cursor = try? APIJSON.decoder.decode(APICursor.self, from: envelope.payload),
            cursor.route == route,
            cursor.libraryId == libraryId,
            cursor.offset >= 0
        else {
            throw APIServiceError.problem(
                status: 400,
                code: "invalid_cursor",
                title: "Invalid cursor",
                detail: "The cursor does not match this collection request."
            )
        }
        return cursor
    }
}

struct APIStudyResponseCursor: Codable, Sendable, Equatable {
    let route: String
    let submittedBefore: Date
    let submittedBeforeId: String
    let libraryId: String

    func encoded(secret: String) throws -> String {
        let payload = try APIJSON.encoder.encode(self)
        let envelope = SignedStudyResponseCursor(
            payload: payload,
            signature: APICrypto.hmacSHA256Hex(key: Data(secret.utf8), data: payload)
        )
        return try APIJSON.encoder.encode(envelope)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(
        _ value: String,
        route: String,
        libraryId: String,
        secret: String
    ) throws -> APIStudyResponseCursor {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard
            let data = Data(base64Encoded: base64),
            let envelope = try? APIJSON.decoder.decode(SignedStudyResponseCursor.self, from: data),
            APICrypto.hmacSHA256Hex(key: Data(secret.utf8), data: envelope.payload)
                == envelope.signature,
            let cursor = try? APIJSON.decoder.decode(APIStudyResponseCursor.self, from: envelope.payload),
            cursor.route == route,
            cursor.libraryId == libraryId,
            UUID(uuidString: cursor.submittedBeforeId) != nil
        else {
            throw APIServiceError.problem(
                status: 400,
                code: "invalid_cursor",
                title: "Invalid cursor",
                detail: "The cursor does not match this collection request."
            )
        }
        return cursor
    }
}

private struct SignedAPICursor: Codable {
    let payload: Data
    let signature: String
}

private struct SignedStudyResponseCursor: Codable {
    let payload: Data
    let signature: String
}
