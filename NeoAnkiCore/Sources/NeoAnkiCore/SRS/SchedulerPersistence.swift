import CryptoKit
import Foundation
import NeoAnkiFSRS

/// Stable identities and policy labels persisted with scheduler decisions.
/// They deliberately live outside the numerical engine so a database can be
/// inspected or rolled back even when a particular engine version is absent.
public enum SchedulerPersistenceConstants {
    public static let sharedPresetID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    )!
    public static let populationDefaultParameterSetID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
    )!
    public static let globalCohortID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000003"
    )!
    public static let sharedPresetName = "Default"
    public static let desiredRetention = 0.90
    public static let maximumIntervalDays = 36_500
    public static let memoryModelVersion = FSRSReference.modelIdentifier
    public static let upstreamCommit = FSRSReference.upstreamCommit
    public static let sourceChecksum = FSRSReference.sourceArchiveSHA256
    public static let optimizerParityVerified = FSRSReference.optimizerParityVerified
    /// SHA-256 of the signed full-reference verification manifest.
    public static let fixtureChecksum = "b132b3d6f3ce7bc1292f54001c558acd6230afad6e037dfd1670ef7c93d51a2f"
    public static let timingPolicyVersion = FSRSScheduler.elapsedPolicyIdentifier
    public static let intervalPolicyVersion = "continuous-due-v1"
    public static let cohortPolicyVersion = "item-type-template-v1"

    public static func cardKindCohortID(itemTypeID: UUID, templateID: UUID) -> UUID {
        let signature = "neoanki-scheduler-cohort-v1|"
            + itemTypeID.uuidString.lowercased() + "|"
            + templateID.uuidString.lowercased()
        var bytes = Array(SHA256.hash(data: Data(signature.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func parameterSetID(
        cohortID: UUID,
        inputFingerprint: String,
        parentParameterSetID: UUID,
        weights: [Double]
    ) -> UUID {
        let weightText = weights.map { String(format: "%.17g", $0) }.joined(separator: ",")
        let signature = "neoanki-parameter-set-v1|\(cohortID.uuidString.lowercased())|"
            + "\(parentParameterSetID.uuidString.lowercased())|\(inputFingerprint)|\(weightText)|"
            + memoryModelVersion
        var bytes = Array(SHA256.hash(data: Data(signature.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum ReviewWorkloadTimingPolicy {
    public static let maximumStoredMilliseconds = 30 * 60 * 1_000
    public static let minimumUsableMilliseconds = 250
    public static let maximumUsableMilliseconds = 10 * 60 * 1_000

    public static func clamped(_ milliseconds: Int) -> Int {
        min(maximumStoredMilliseconds, max(0, milliseconds))
    }

    public static func isUsable(_ milliseconds: Int) -> Bool {
        (minimumUsableMilliseconds ... maximumUsableMilliseconds).contains(milliseconds)
    }
}

public enum SchedulerCohortKind: String, Codable, Equatable, Sendable {
    case global
    case cardKind
}

public struct SchedulerCohort: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: SchedulerCohortKind
    public let canonicalSignature: String
    public let parentCohortID: UUID?
    public let activeParameterSetID: UUID?
    public let isDirty: Bool
    public let dirtyRevision: Int
    public let lastAttemptAt: Date?
    public let lastMaintenanceAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        kind: SchedulerCohortKind,
        canonicalSignature: String,
        parentCohortID: UUID? = nil,
        activeParameterSetID: UUID? = nil,
        isDirty: Bool = true,
        dirtyRevision: Int = 1,
        lastAttemptAt: Date? = nil,
        lastMaintenanceAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.canonicalSignature = canonicalSignature
        self.parentCohortID = parentCohortID
        self.activeParameterSetID = activeParameterSetID
        self.isDirty = isDirty
        self.dirtyRevision = dirtyRevision
        self.lastAttemptAt = lastAttemptAt
        self.lastMaintenanceAt = lastMaintenanceAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SchedulerCardHistory: Codable, Equatable, Sendable {
    public let cardID: UUID
    public let cohortID: UUID
    public let itemTypeIDAtAssignment: UUID
    public let templateIDAtAssignment: UUID
    public let historyOrigin: Date?
    public let updatedAt: Date
}

public struct SchedulerPreset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let desiredRetention: Double
    public let maximumIntervalDays: Int
    public let automaticOptimizationEnabled: Bool
    public let activeParameterSetID: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        desiredRetention: Double,
        maximumIntervalDays: Int,
        automaticOptimizationEnabled: Bool,
        activeParameterSetID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.desiredRetention = desiredRetention
        self.maximumIntervalDays = maximumIntervalDays
        self.automaticOptimizationEnabled = automaticOptimizationEnabled
        self.activeParameterSetID = activeParameterSetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum FSRSParameterSource: String, Codable, Equatable, Sendable {
    case populationDefault
    case optimized
    case imported
    case legacyQuarantine
}

/// An immutable set of model parameters. Activation is represented by the
/// preset's pointer, rather than by mutating this historical record.
public struct FSRSParameterSet: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let weights: [Double]
    public let modelVersion: String
    public let upstreamCommit: String
    public let sourceChecksum: String
    public let fixtureChecksum: String?
    public let scope: String
    public let cohortID: UUID?
    public let source: FSRSParameterSource
    public let inputFingerprint: String?
    public let trainingCutoff: Date?
    public let metrics: [String: Double]
    public let previousParameterSetID: UUID?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        weights: [Double],
        modelVersion: String,
        upstreamCommit: String,
        sourceChecksum: String,
        fixtureChecksum: String? = nil,
        scope: String = "shared",
        cohortID: UUID? = nil,
        source: FSRSParameterSource,
        inputFingerprint: String? = nil,
        trainingCutoff: Date? = nil,
        metrics: [String: Double] = [:],
        previousParameterSetID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.weights = weights
        self.modelVersion = modelVersion
        self.upstreamCommit = upstreamCommit
        self.sourceChecksum = sourceChecksum
        self.fixtureChecksum = fixtureChecksum
        self.scope = scope
        self.cohortID = cohortID
        self.source = source
        self.inputFingerprint = inputFingerprint
        self.trainingCutoff = trainingCutoff
        self.metrics = metrics
        self.previousParameterSetID = previousParameterSetID
        self.createdAt = createdAt
    }
}

public enum FSRSOptimizationDecision: String, Codable, Equatable, Sendable {
    case promoted
    case held
    case rejected
    case probationCompleted
    case rolledBack
    case notEnoughData
    case failed
}

/// Final, append-only account of an optimization attempt. Progress belongs in
/// transient application state; only a terminal result is inserted here.
public struct FSRSOptimizationRun: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let presetID: UUID
    public let cohortID: UUID?
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
    public let decision: FSRSOptimizationDecision
    public let reason: String?
    public let candidateParameterSetID: UUID?

    public init(
        id: UUID = UUID(),
        presetID: UUID,
        cohortID: UUID? = nil,
        startedAt: Date,
        completedAt: Date,
        trainingCutoff: Date,
        inputFingerprint: String,
        eligibleTargetCount: Int,
        distinctCardCount: Int,
        failureCount: Int,
        studyDayCount: Int,
        excludedCounts: [String: Int] = [:],
        foldCount: Int,
        metrics: [String: Double] = [:],
        decision: FSRSOptimizationDecision,
        reason: String? = nil,
        candidateParameterSetID: UUID? = nil
    ) {
        self.id = id
        self.presetID = presetID
        self.cohortID = cohortID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.trainingCutoff = trainingCutoff
        self.inputFingerprint = inputFingerprint
        self.eligibleTargetCount = eligibleTargetCount
        self.distinctCardCount = distinctCardCount
        self.failureCount = failureCount
        self.studyDayCount = studyDayCount
        self.excludedCounts = excludedCounts
        self.foldCount = foldCount
        self.metrics = metrics
        self.decision = decision
        self.reason = reason
        self.candidateParameterSetID = candidateParameterSetID
    }
}

/// Complete scheduler provenance for one answer. Optional on legacy and
/// synchronized logs, which keeps old exports and databases decodable.
public struct ReviewSchedulingAudit: Codable, Equatable, Sendable {
    public let presetID: UUID?
    public let deckIDAtReview: UUID?
    public let cohortID: UUID?
    public let itemTypeIDAtReview: UUID?
    public let templateIDAtReview: UUID?
    public let skillAtReview: Skill?
    public let contentKindVersion: String?
    public let elapsedSeconds: Double
    public let elapsedModelDays: Double
    public let parameterSetID: UUID?
    public let memoryAfter: MemoryState
    public let predictedRetrievability: Double?
    public let rawIntervalDays: Double?
    public let operationalIntervalSeconds: Int
    public let modelVersion: String
    public let timingPolicyVersion: String
    public let intervalPolicyVersion: String
    public let finalDueAt: Date
    public let constraintReason: String?

    public init(
        presetID: UUID?,
        deckIDAtReview: UUID?,
        cohortID: UUID? = nil,
        itemTypeIDAtReview: UUID? = nil,
        templateIDAtReview: UUID? = nil,
        skillAtReview: Skill? = nil,
        contentKindVersion: String? = nil,
        elapsedSeconds: Double,
        elapsedModelDays: Double,
        parameterSetID: UUID?,
        memoryAfter: MemoryState,
        predictedRetrievability: Double?,
        rawIntervalDays: Double?,
        operationalIntervalSeconds: Int,
        modelVersion: String,
        timingPolicyVersion: String,
        intervalPolicyVersion: String,
        finalDueAt: Date,
        constraintReason: String? = nil
    ) {
        self.presetID = presetID
        self.deckIDAtReview = deckIDAtReview
        self.cohortID = cohortID
        self.itemTypeIDAtReview = itemTypeIDAtReview
        self.templateIDAtReview = templateIDAtReview
        self.skillAtReview = skillAtReview
        self.contentKindVersion = contentKindVersion
        self.elapsedSeconds = elapsedSeconds
        self.elapsedModelDays = elapsedModelDays
        self.parameterSetID = parameterSetID
        self.memoryAfter = memoryAfter
        self.predictedRetrievability = predictedRetrievability
        self.rawIntervalDays = rawIntervalDays
        self.operationalIntervalSeconds = operationalIntervalSeconds
        self.modelVersion = modelVersion
        self.timingPolicyVersion = timingPolicyVersion
        self.intervalPolicyVersion = intervalPolicyVersion
        self.finalDueAt = finalDueAt
        self.constraintReason = constraintReason
    }
}

public struct ReviewSchedulePreviewDetail: Codable, Equatable, Sendable {
    public let rating: ReviewRating
    public let memoryBefore: MemoryState
    public let memoryAfter: MemoryState
    public let predictedRetrievability: Double
    public let rawIntervalDays: Double
    public let operationalIntervalSeconds: Int
    public let desiredRetention: Double
    public let maximumIntervalDays: Int
    public let presetID: UUID?
    public let cohortID: UUID?
    public let parameterSetID: UUID?
    public let modelVersion: String
    public let timingPolicyVersion: String
    public let intervalPolicyVersion: String
    public let finalDueAt: Date
    public let constraintReason: String?

    public init(
        rating: ReviewRating,
        memoryBefore: MemoryState,
        memoryAfter: MemoryState,
        predictedRetrievability: Double,
        rawIntervalDays: Double,
        operationalIntervalSeconds: Int,
        desiredRetention: Double,
        maximumIntervalDays: Int,
        presetID: UUID?,
        cohortID: UUID? = nil,
        parameterSetID: UUID?,
        modelVersion: String,
        timingPolicyVersion: String,
        intervalPolicyVersion: String,
        finalDueAt: Date,
        constraintReason: String?
    ) {
        self.rating = rating
        self.memoryBefore = memoryBefore
        self.memoryAfter = memoryAfter
        self.predictedRetrievability = predictedRetrievability
        self.rawIntervalDays = rawIntervalDays
        self.operationalIntervalSeconds = operationalIntervalSeconds
        self.desiredRetention = desiredRetention
        self.maximumIntervalDays = maximumIntervalDays
        self.presetID = presetID
        self.cohortID = cohortID
        self.parameterSetID = parameterSetID
        self.modelVersion = modelVersion
        self.timingPolicyVersion = timingPolicyVersion
        self.intervalPolicyVersion = intervalPolicyVersion
        self.finalDueAt = finalDueAt
        self.constraintReason = constraintReason
    }
}

public enum SchedulerMigrationStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case rolledBack
    case failed
}

public struct CardSchedulingSnapshot: Codable, Equatable, Sendable {
    public let cardID: UUID
    public let memory: MemoryState
    public let memoryModelVersion: String?
    public let memoryParameterSetID: UUID?
    public let schedulingHistoryOrigin: Date?

    public init(
        cardID: UUID,
        memory: MemoryState,
        memoryModelVersion: String?,
        memoryParameterSetID: UUID?,
        schedulingHistoryOrigin: Date? = nil
    ) {
        self.cardID = cardID
        self.memory = memory
        self.memoryModelVersion = memoryModelVersion
        self.memoryParameterSetID = memoryParameterSetID
        self.schedulingHistoryOrigin = schedulingHistoryOrigin
    }
}

public struct SchedulerMigrationRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fromModelVersion: String
    public let toModelVersion: String
    public let status: SchedulerMigrationStatus
    public let startedAt: Date
    public let completedAt: Date?
    public let replayedCardCount: Int
    public let resetCardCount: Int
    public let failureReason: String?

    public init(
        id: UUID = UUID(),
        fromModelVersion: String,
        toModelVersion: String,
        status: SchedulerMigrationStatus,
        startedAt: Date,
        completedAt: Date? = nil,
        replayedCardCount: Int = 0,
        resetCardCount: Int = 0,
        failureReason: String? = nil
    ) {
        self.id = id
        self.fromModelVersion = fromModelVersion
        self.toModelVersion = toModelVersion
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.replayedCardCount = replayedCardCount
        self.resetCardCount = resetCardCount
        self.failureReason = failureReason
    }
}

public struct SchedulingHealthSnapshot: Codable, Equatable, Sendable {
    public let preset: SchedulerPreset
    public let activeParameterSet: FSRSParameterSet?
    public let lastOptimizationRun: FSRSOptimizationRun?
    public let rollbackParameterSetIDs: [UUID]
    public let legacyParametersQuarantined: Bool
    public let optimizerParityVerified: Bool
    public let latestMigration: SchedulerMigrationRecord?
    public let cohortCount: Int
    public let personalizedCohortCount: Int
    public let inheritedCohortCount: Int
    public let pendingMaintenance: Bool
    public let lastMaintenanceAt: Date?

    public var activeModelVersion: String? { activeParameterSet?.modelVersion }
    public var activeSource: FSRSParameterSource? { activeParameterSet?.source }
    public var desiredRetention: Double { preset.desiredRetention }
    public var automaticOptimizationEnabled: Bool {
        preset.automaticOptimizationEnabled
    }
    public var rollbackAvailable: Bool { !rollbackParameterSetIDs.isEmpty }

    public init(
        preset: SchedulerPreset,
        activeParameterSet: FSRSParameterSet?,
        lastOptimizationRun: FSRSOptimizationRun?,
        rollbackParameterSetIDs: [UUID],
        legacyParametersQuarantined: Bool,
        optimizerParityVerified: Bool = SchedulerPersistenceConstants.optimizerParityVerified,
        latestMigration: SchedulerMigrationRecord? = nil,
        cohortCount: Int = 1,
        personalizedCohortCount: Int = 0,
        inheritedCohortCount: Int = 0,
        pendingMaintenance: Bool = false,
        lastMaintenanceAt: Date? = nil
    ) {
        self.preset = preset
        self.activeParameterSet = activeParameterSet
        self.lastOptimizationRun = lastOptimizationRun
        self.rollbackParameterSetIDs = rollbackParameterSetIDs
        self.legacyParametersQuarantined = legacyParametersQuarantined
        self.optimizerParityVerified = optimizerParityVerified
        self.latestMigration = latestMigration
        self.cohortCount = cohortCount
        self.personalizedCohortCount = personalizedCohortCount
        self.inheritedCohortCount = inheritedCohortCount
        self.pendingMaintenance = pendingMaintenance
        self.lastMaintenanceAt = lastMaintenanceAt
    }
}
