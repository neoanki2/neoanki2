import CryptoKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore

private enum SyncPayload: Codable, Equatable {
    case library(UUID)
    case deck(Deck)
    case itemType(ItemType)
    case item(SynchronizedItemRecord)
    case card(Card)
    case review(SynchronizedReviewRecord)
    case reviewRevert(ReviewRevertRecord)
    case itemTypeMembership(ItemTypeMembershipRecord)
    case schedulingSettings(SchedulingSettingsRecord)
    case portableTypeMapping(PortableItemTypeMappingRecord)
    case metadata(kind: String, id: String)
}

public enum SQLiteLibrarySyncError: Error, LocalizedError, Sendable {
    case unknownResourceKind(String)
    case missingResource(String)
    case invalidPayload(String)
    case invalidAsset(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownResourceKind(kind): "Unsupported synchronized resource kind: \(kind)."
        case let .missingResource(id): "Synchronized resource \(id) no longer exists."
        case let .invalidPayload(id): "Synchronized resource \(id) did not pass validation."
        case let .invalidAsset(id): "Synchronized media \(id) failed its size, signature, or hash check."
        }
    }
}

protocol MediaSyncAdapter: LibrarySyncAdapter {
    func prioritizeMedia(in scope: DeckScope?) async
    func encode(changes: [LibraryChange], deviceID: String,
                knownMedia: [String: SyncAssetDescriptor]) async throws -> [SyncRecordEnvelope]
    func encodeForIncrementalSync(changes: [LibraryChange], deviceID: String,
                baseline: [String: SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope]
    func materializeUpload(_ record: SyncRecordEnvelope) async throws -> SyncRecordEnvelope
    func hasLocalMedia(_ record: SyncRecordEnvelope) async -> Bool
    func reviewsWithLocalDependencies(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope]
    func orderedMedia(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope]
    func applyLibraryChanges(_ records: [SyncRecordEnvelope], expectedCursor: Int64) async throws -> Int64?
}

/// Production bridge between the typed SQLite repository and durable sync
/// envelopes. Domain objects are decoded and validated before repository
/// mutation; assets are staged and content-address verified before ingestion.
public actor SQLiteLibrarySyncAdapter: MediaSyncAdapter {
    private let repository: SQLiteLibraryRepository
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var echoedResources: [String: SyncRecordEnvelope] = [:]
    private var statisticsAliases: [StatisticsEvent] = []
    private var learningTimeAliases: [LearningTimeItemAlias] = []
    private var conflictCopies: [SyncConflictCopy] = []
    private var mediaPriority: DeckScope?

    public init(repository: SQLiteLibraryRepository) {
        self.repository = repository
        encoder.outputFormatting = [.sortedKeys]
    }

    public func encode(changes: [LibraryChange], deviceID: String) async throws -> [SyncRecordEnvelope] {
        try await encode(changes: changes, deviceID: deviceID, consumeEchoes: true)
    }

    func prioritizeMedia(in scope: DeckScope?) {
        if case .deck = scope { mediaPriority = scope }
        else { mediaPriority = nil }
    }

    func encode(changes: [LibraryChange], deviceID: String,
                knownMedia: [String: SyncAssetDescriptor]) async throws -> [SyncRecordEnvelope] {
        try await encode(changes: changes, deviceID: deviceID, consumeEchoes: true, knownMedia: knownMedia)
    }

    func encodeForIncrementalSync(changes: [LibraryChange], deviceID: String,
                                  baseline: [String: SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope] {
        try await encode(changes: changes, deviceID: deviceID, consumeEchoes: false,
            baseline: baseline, deferMedia: true)
    }

    private func encode(
        changes: [LibraryChange], deviceID: String, consumeEchoes: Bool,
        knownMedia: [String: SyncAssetDescriptor] = [:], baseline: [String: SyncRecordEnvelope] = [:],
        deferMedia: Bool = false
    ) async throws -> [SyncRecordEnvelope] {
        var records: [SyncRecordEnvelope] = []
        records.reserveCapacity(changes.count)
        for change in changes {
            try Task.checkCancellation()
            let echoKey = key(kind: change.resourceType, id: change.resourceID)
            guard let kind = LibraryResourceKind(rawValue: change.resourceType) else {
                throw SQLiteLibrarySyncError.unknownResourceKind(change.resourceType)
            }
            // Learner recordings and their private-only media never leave the
            // device. The caller still advances its durable change cursor.
            if kind == .studyResponse { continue }
            if kind == .media,
               try await repository.isStudyResponseMediaHash(change.resourceID),
               try await repository.ordinaryMediaReferenceCount(hash: change.resourceID) == 0 {
                continue
            }
            if change.isTombstone {
                if baseline[echoKey]?.isTombstone == true { continue }
                if consumeEchoes, echoedResources.removeValue(forKey: echoKey)?.isTombstone == true { continue }
                records.append(.init(
                    id: change.resourceID,
                    resourceKind: kind.rawValue,
                    revision: change.revision,
                    deviceID: deviceID,
                    order: change.cursor,
                    isTombstone: true,
                    payload: Data()
                ))
                continue
            }
            if consumeEchoes, kind == .media,
               let known = knownMedia[change.resourceID] ?? echoedResources[echoKey]?.asset,
               let asset = try await repository.mediaAsset(hash: change.resourceID),
               known.hash == asset.hash, known.signature == asset.hash,
               known.byteSize == asset.byteSize, known.contentType == contentType(for: asset.kind),
               known.fileExtension == asset.fileExtension {
                echoedResources.removeValue(forKey: echoKey)
                continue
            }
            let encoded = try await payload(kind: kind, id: change.resourceID, deferMedia: deferMedia)
            let bytes = try encoder.encode(encoded.payload)
            if let accepted = baseline[echoKey], !accepted.isTombstone, accepted.asset == encoded.asset,
               accepted.payload == bytes || (try? decoder.decode(SyncPayload.self, from: accepted.payload)) == encoded.payload {
                continue
            }
            if consumeEchoes, let echo = echoedResources.removeValue(forKey: echoKey),
               !echo.isTombstone, echo.asset == encoded.asset,
               (echo.payload == bytes || (try? decoder.decode(SyncPayload.self, from: echo.payload)) == encoded.payload) {
                continue
            }
            records.append(.init(
                id: change.resourceID,
                resourceKind: kind.rawValue,
                revision: change.revision,
                deviceID: deviceID,
                order: change.cursor,
                isTombstone: false,
                payload: bytes,
                asset: encoded.asset,
                stagedFileURL: encoded.fileURL
            ))
        }
        return records
    }

    public func applyRemote(_ records: [SyncRecordEnvelope], origin: LibraryChangeOrigin) async throws {
        _ = try await applyRemote(records, expectedCursor: nil)
    }

    func applyLibraryChanges(_ records: [SyncRecordEnvelope], expectedCursor: Int64) async throws -> Int64? {
        try await applyRemote(records, expectedCursor: expectedCursor)
    }

    func reviewsWithLocalDependencies(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope] {
        var ready: [SyncRecordEnvelope] = []
        var reviewIDs: Set<UUID> = []
        for record in records where record.resourceKind == LibraryResourceKind.review.rawValue && !record.isTombstone {
            guard case let .review(review)? = try? decoder.decode(SyncPayload.self, from: record.payload) else { continue }
            do { _ = try await repository.card(id: review.log.cardID) }
            catch DatabaseError.cardNotFound { continue }
            reviewIDs.insert(review.log.id)
            ready.append(record)
        }
        for record in records where record.resourceKind == LibraryResourceKind.reviewRevert.rawValue && !record.isTombstone {
            guard case let .reviewRevert(revert)? = try? decoder.decode(SyncPayload.self, from: record.payload) else { continue }
            if !reviewIDs.contains(revert.reviewLogID) {
                do { _ = try await repository.synchronizedReviewRecord(id: revert.reviewLogID) }
                catch DatabaseError.reviewLogNotFound { continue }
            }
            ready.append(record)
        }
        return ready
    }

    private func applyRemote(_ records: [SyncRecordEnvelope], expectedCursor: Int64?) async throws -> Int64? {
        guard !records.isEmpty else { return expectedCursor }
        let aliases = try await repository.syncItemTypeAliases()
        let records = try normalizeRemote(
            records, against: [], canonicalLibraryID: try await repository.libraryID(),
            sourceLibraryID: nil, knownAliases: [], typeRemap: aliases, dropAliasedTypes: false
        )
        var mutations: [SynchronizedLibraryMutation] = []
        var media: [(url: URL?, reference: MediaRef, byteSize: Int)] = []
        var incomingItems: [Item] = []
        var incomingDecks: [Deck] = []
        for record in dependencyOrdered(records) {
            guard let kind = LibraryResourceKind(rawValue: record.resourceKind) else {
                throw SQLiteLibrarySyncError.unknownResourceKind(record.resourceKind)
            }
            if kind == .studyResponse { continue }
            if record.isTombstone {
                mutations.append(.tombstone(kind: kind, id: record.id))
            } else {
                let payload: SyncPayload
                do { payload = try decoder.decode(SyncPayload.self, from: record.payload) }
                catch { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
                switch payload {
                case .library:
                    break
                case let .deck(value):
                    mutations.append(.deck(value))
                    incomingDecks.append(value)
                case let .itemType(value):
                    try ItemTypeValidation.validate(value)
                    mutations.append(.itemType(value))
                case let .item(value):
                    mutations.append(.item(value.item, createdAt: value.createdAt, updatedAt: value.updatedAt))
                    incomingItems.append(value.item)
                case let .card(value): mutations.append(.card(value))
                case let .review(value): mutations.append(.review(value))
                case let .reviewRevert(value): mutations.append(.reviewRevert(value))
                case let .itemTypeMembership(value): mutations.append(.itemTypeMembership(value))
                case let .schedulingSettings(value): mutations.append(.schedulingSettings(value))
                case let .portableTypeMapping(value): mutations.append(.portableTypeMapping(value))
                case .metadata:
                    guard let asset = record.asset, asset.hash == record.id, asset.signature == asset.hash,
                          let size = Int(exactly: asset.byteSize), size >= 0,
                          let kind = MediaKind(rawValue: asset.contentType) else {
                        throw SQLiteLibrarySyncError.invalidAsset(record.id)
                    }
                    media.append((record.stagedFileURL, MediaRef(kind: kind, assetHash: asset.hash,
                        fileExtension: asset.fileExtension), size))
                }
            }
        }
        try await installMedia(media, items: incomingItems, decks: incomingDecks)
        try Task.checkCancellation()
        // Materialize incoming files before synchronized items reference them.
        // The repository reconciles reference counts in the same transaction
        // as the item batch, so subsequent orphan collection cannot delete
        // a newly synchronized but locally uncounted asset.
        let appliedCursor = try await repository.applySynchronizedBatch(mutations, expectedChangeCursor: expectedCursor)
        if expectedCursor == nil {
            for record in records {
                echoedResources[key(kind: record.resourceKind, id: record.id)] = record
            }
        }
        return appliedCursor
    }

    func orderedMedia(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope] {
        let ordered = records.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        guard let scope = mediaPriority else { return ordered }
        let priorities = try await priorityMediaHashes(scope: scope, items: [], decks: [])
        return ordered.filter { priorities.contains($0.id) } + ordered.filter { !priorities.contains($0.id) }
    }

    func materializeUpload(_ record: SyncRecordEnvelope) async throws -> SyncRecordEnvelope {
        guard !record.isTombstone, record.stagedFileURL == nil else { return record }
        let materialized = try await payload(kind: .media, id: record.id)
        guard materialized.asset == record.asset else {
            if let url = materialized.fileURL { try? FileManager.default.removeItem(at: url) }
            throw SQLiteLibrarySyncError.invalidAsset(record.id)
        }
        return SyncRecordEnvelope(id: record.id, resourceKind: record.resourceKind,
            revision: record.revision, deviceID: record.deviceID, order: record.order,
            isTombstone: false, payload: record.payload, asset: record.asset, stagedFileURL: materialized.fileURL)
    }

    func hasLocalMedia(_ record: SyncRecordEnvelope) async -> Bool {
        guard let asset = record.asset, let kind = MediaKind(rawValue: asset.contentType),
              let store = await repository.mediaStore() else { return false }
        let reference = MediaRef(kind: kind, assetHash: asset.hash, fileExtension: asset.fileExtension)
        guard let url = try? await store.resolve(reference),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size == asset.byteSize
    }

    private func installMedia(
        _ media: [(url: URL?, reference: MediaRef, byteSize: Int)], items: [Item], decks: [Deck]
    ) async throws {
        var remaining = media[...]
        var orderedFor: DeckScope?
        while !remaining.isEmpty {
            try Task.checkCancellation()
            if let scope = mediaPriority, scope != orderedFor {
                let hashes = try await priorityMediaHashes(scope: scope, items: items, decks: decks)
                remaining = (remaining.filter { hashes.contains($0.reference.assetHash) }
                    + remaining.filter { !hashes.contains($0.reference.assetHash) })[...]
                orderedFor = scope
            }
            // Bound memory and SQLite lock time. Still allow one large video
            // to make progress on its own.
            var size = 0
            let batch = remaining.prefix(32).prefix { file in
                guard size == 0 || file.byteSize <= 16 * 1024 * 1024 - size else { return false }
                size += file.byteSize
                return true
            }
            do {
                try await repository.installSynchronizedMedia(Array(batch))
            } catch DatabaseError.invalidMediaAsset(let hash) {
                throw SQLiteLibrarySyncError.invalidAsset(hash)
            }
            remaining = remaining.dropFirst(batch.count)
        }
    }

    private func priorityMediaHashes(scope: DeckScope, items: [Item], decks: [Deck]) async throws -> Set<String> {
        guard case let .deck(id, includeDescendants) = scope else { return [] }
        var deckIDs: Set<UUID> = [id]
        if includeDescendants {
            var summaries = Dictionary(uniqueKeysWithValues: try await repository.synchronizedDecks().map { ($0.id, $0) })
            for deck in decks {
                summaries[deck.id] = deck
            }
            deckIDs = DeckTree.descendantIDs(of: id, in: summaries.values.map {
                DeckSummary(id: $0.id, name: $0.name, parentID: $0.parentID, itemCount: 0, dueCount: 0)
            })
        }
        let incoming = items.lazy.filter { $0.deckID.map(deckIDs.contains) ?? false }
            .flatMap { $0.fields.compactMap { $0.value.mediaReference?.assetHash } }
        return try await repository.synchronizedMediaHashes(deckIDs: deckIDs).union(incoming)
    }

    public func initialMerge(remote: [SyncRecordEnvelope], deviceID: String) async throws -> [SyncRecordEnvelope] {
        let localChanges = try await allLocalChanges()
        let local = try await encode(changes: localChanges, deviceID: deviceID, consumeEchoes: false)
        let canonicalLibraryID = try await repository.libraryID()
        let knownAliases = try await repository.libraryAliases(canonicalID: canonicalLibraryID)
        let remoteLibraryIDs = remote.compactMap { record -> UUID? in
            guard record.resourceKind == LibraryResourceKind.library.rawValue,
                  !record.isTombstone,
                  let payload = try? decoder.decode(SyncPayload.self, from: record.payload),
                  case let .library(id) = payload else { return nil }
            return id
        }
        for alias in remoteLibraryIDs where alias != canonicalLibraryID {
            try await repository.recordLibraryAlias(alias, canonicalID: canonicalLibraryID)
        }
        // Equivalent schemas with distinct UUIDs are independent identities.
        // Choosing a different canonical type on each replica prevents cloud
        // convergence. Honor durable legacy aliases, but create no new aliases
        // from structural similarity alone.
        let typeRemap = try await repository.syncItemTypeAliases()
        let normalizedRemote = try normalizeRemote(
            remote,
            against: local,
            canonicalLibraryID: canonicalLibraryID,
            sourceLibraryID: remoteLibraryIDs.first,
            knownAliases: knownAliases, typeRemap: typeRemap
        )
        let canonicalLocalIdentity = local.filter {
            $0.resourceKind == LibraryResourceKind.library.rawValue && $0.id == canonicalLibraryID.uuidString
        }.max { $0.order < $1.order }
        let merge = SyncMergePolicy.merge(
            local: local.filter { $0.resourceKind != LibraryResourceKind.library.rawValue }
                + [canonicalLocalIdentity].compactMap { $0 },
            server: normalizedRemote.filter { $0.resourceKind != LibraryResourceKind.library.rawValue }
        )
        conflictCopies.append(contentsOf: merge.conflictCopies)
        try await applyRemote(merge.accepted, origin: .initialMerge)
        try await repository.recordLearningTimeAliases(learningTimeAliases)
        learningTimeAliases = []
        try await repository.recordStatisticsEvents(statisticsAliases)
        statisticsAliases = []
        let serverByKey = Dictionary(
            remote.map { (key(kind: $0.resourceKind, id: $0.id), $0) },
            uniquingKeysWith: { $0.order >= $1.order ? $0 : $1 }
        )
        // Incoming records already exist on the server. Upload only additions
        // and canonicalized payloads, avoiding a full-library echo on first sync.
        return merge.accepted.filter { accepted in
            guard let server = serverByKey[key(kind: accepted.resourceKind, id: accepted.id)] else { return true }
            return server.payload != accepted.payload || server.isTombstone != accepted.isTombstone
                || server.asset != accepted.asset
        }.map {
            SyncRecordEnvelope(
                id: $0.id,
                resourceKind: $0.resourceKind,
                revision: $0.revision,
                deviceID: deviceID,
                order: $0.order,
                isTombstone: $0.isTombstone,
                payload: $0.payload,
                asset: $0.asset,
                stagedFileURL: $0.stagedFileURL
            )
        }
    }

    private func allLocalChanges() async throws -> [LibraryChange] {
        // The journal is incremental: pre-migration resources and pruned
        // history are absent. Initial merge needs the complete revision index.
        try await repository.resourceRevisionSnapshot().enumerated().map { index, revision in
            LibraryChange(
                cursor: Int64(index + 1), transactionID: UUID(), sequence: index,
                eventType: "snapshot", resourceType: revision.resourceType,
                resourceID: revision.resourceID, revision: revision.revision,
                isTombstone: revision.isDeleted, occurredAt: revision.updatedAt
            )
        }
    }

    private func normalizeRemote(
        _ remote: [SyncRecordEnvelope],
        against local: [SyncRecordEnvelope],
        canonicalLibraryID: UUID,
        sourceLibraryID: UUID?,
        knownAliases: Set<UUID>,
        typeRemap: [UUID: UUID],
        dropAliasedTypes: Bool = true
    ) throws -> [SyncRecordEnvelope] {
        let collisionKinds = Set([
            LibraryResourceKind.deck.rawValue,
            LibraryResourceKind.itemType.rawValue,
            LibraryResourceKind.item.rawValue,
            LibraryResourceKind.card.rawValue,
            LibraryResourceKind.review.rawValue,
            LibraryResourceKind.reviewRevert.rawValue,
        ])
        let localByKey = Dictionary(
            local.map { ("\($0.resourceKind):\($0.id)", $0) },
            uniquingKeysWith: { $0.order >= $1.order ? $0 : $1 }
        )
        var collisionRemaps: [String: [UUID: UUID]] = [:]
        if let sourceLibraryID, sourceLibraryID != canonicalLibraryID {
            for record in remote where collisionKinds.contains(record.resourceKind) {
                guard let id = UUID(uuidString: record.id),
                      typeRemap[id] == nil || record.resourceKind != LibraryResourceKind.itemType.rawValue,
                      let localRecord = localByKey["\(record.resourceKind):\(record.id)"],
                      localRecord.payload != record.payload || localRecord.isTombstone != record.isTombstone
                else { continue }
                let replacement = deterministicID(
                    sourceLibraryID: sourceLibraryID,
                    resourceKind: record.resourceKind,
                    originalID: id
                )
                // Once libraries are linked, differing values are ordinary
                // sync conflicts. Reuse a prior collision remap, but never
                // manufacture another identity during a retry or re-upload.
                guard !knownAliases.contains(sourceLibraryID)
                    || localByKey["\(record.resourceKind):\(replacement.uuidString)"] != nil else { continue }
                collisionRemaps[record.resourceKind, default: [:]][id] = replacement
                statisticsAliases.append(StatisticsEvent(id:"alias:\(sourceLibraryID):\(record.resourceKind):\(id)",kind:"alias",occurredAt:Date(timeIntervalSince1970:0),cardID:id,itemID:replacement,interaction:record.resourceKind,sourceLibraryID:sourceLibraryID))
                if record.resourceKind == LibraryResourceKind.item.rawValue {
                    learningTimeAliases.append(LearningTimeItemAlias(sourceLibraryID: sourceLibraryID,
                        originalItemID: id, resolvedItemID: replacement))
                }
            }
        }

        func mapped(_ id: UUID, kind: LibraryResourceKind) -> UUID {
            if kind == .itemType, let canonical = typeRemap[id] { return canonical }
            return collisionRemaps[kind.rawValue]?[id] ?? id
        }

        return try remote.compactMap { record in
            try validateEnvelope(record)
            if record.isTombstone {
                let components = record.id.split(separator: ":", omittingEmptySubsequences: false)
                let replacement = components.enumerated().map { index, component -> String in
                    guard let id = UUID(uuidString: String(component)) else { return String(component) }
                    if record.resourceKind == LibraryResourceKind.itemTypeMembership.rawValue {
                        let isDeck = components.first != "library" && components.first != "scope" && index == 1
                        return mapped(id, kind: isDeck ? .deck : .itemType).uuidString
                    }
                    if record.resourceKind == LibraryResourceKind.portableTypeMapping.rawValue,
                       index == 0, id == sourceLibraryID { return canonicalLibraryID.uuidString }
                    return (collisionRemaps[record.resourceKind]?[id]
                        ?? (record.resourceKind == LibraryResourceKind.itemType.rawValue ? typeRemap[id] : nil)
                        ?? id).uuidString
                }.joined(separator: ":")
                guard replacement != record.id else { return record }
                return SyncRecordEnvelope(
                    id: replacement,
                    resourceKind: record.resourceKind,
                    revision: record.revision,
                    deviceID: record.deviceID,
                    order: record.order,
                    isTombstone: true,
                    payload: record.payload,
                    asset: record.asset,
                    stagedFileURL: record.stagedFileURL
                )
            }
            let payload = try decoder.decode(SyncPayload.self, from: record.payload)
            let transformed: SyncPayload
            var transformedID = record.id
            switch payload {
            case let .itemType(type) where dropAliasedTypes && typeRemap[type.id] != nil:
                return nil
            case let .deck(deck):
                let value = Deck(
                    id: mapped(deck.id, kind: .deck),
                    name: deck.name,
                    parentID: deck.parentID.map { mapped($0, kind: .deck) },
                    newCardsPerDay: deck.newCardsPerDay,
                    includeInAllDecksStudy: deck.includeInAllDecksStudy
                )
                transformed = .deck(value); transformedID = value.id.uuidString
            case let .itemType(type):
                let value = ItemType(
                    id: mapped(type.id, kind: .itemType),
                    name: type.name,
                    fields: type.fields,
                    templates: type.templates,
                    lists: type.lists
                )
                transformed = .itemType(value); transformedID = value.id.uuidString
            case let .item(record):
                let item = record.item
                let value = Item(
                    id: mapped(item.id, kind: .item),
                    itemTypeID: mapped(item.itemTypeID, kind: .itemType),
                    fields: item.fields,
                    tags: item.tags,
                    deckID: item.deckID.map { mapped($0, kind: .deck) }
                )
                transformed = .item(SynchronizedItemRecord(
                    item: value,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )); transformedID = value.id.uuidString
            case let .card(card):
                let value = Card(
                    id: mapped(card.id, kind: .card),
                    itemID: mapped(card.itemID, kind: .item),
                    templateID: card.templateID,
                    skill: card.skill,
                    memory: card.memory,
                    memoryModelVersion: card.memoryModelVersion,
                    memoryParameterSetID: card.memoryParameterSetID,
                    schedulingHistoryOrigin: card.schedulingHistoryOrigin,
                    isSuspended: card.isSuspended,
                    deckID: card.deckID.map { mapped($0, kind: .deck) },
                    occlusionGroup: card.occlusionGroup, clozeGroup: card.clozeGroup,
                    rowSelections: card.rowSelections
                )
                transformed = .card(value); transformedID = value.id.uuidString
            case let .review(review):
                let log = review.log
                let value = SynchronizedReviewRecord(
                    log: ReviewLog(
                        id: mapped(log.id, kind: .review),
                        cardID: mapped(log.cardID, kind: .card),
                        reviewedAt: log.reviewedAt,
                        rating: log.rating,
                        elapsedDays: log.elapsedDays,
                        scheduledDays: log.scheduledDays,
                        phaseBefore: log.phaseBefore,
                        durationMs: log.durationMs,
                        sequence: log.sequence,
                        schedulingAudit: log.schedulingAudit,
                        vocabularyPrompt: log.vocabularyPrompt
                    ),
                    memoryBefore: review.memoryBefore,
                    introductionContext: review.introductionContext.map {
                        .init(deckID: $0.deckID.map { mapped($0, kind: .deck) }, studyDay: $0.studyDay)
                    }
                )
                transformed = .review(value); transformedID = value.log.id.uuidString
            case let .reviewRevert(revert):
                let value = ReviewRevertRecord(
                    id: mapped(revert.id, kind: .reviewRevert),
                    reviewLogID: mapped(revert.reviewLogID, kind: .review),
                    revertedAt: revert.revertedAt
                )
                transformed = .reviewRevert(value); transformedID = value.id.uuidString
            case let .itemTypeMembership(membership):
                switch membership {
                case let .typeSettings(value):
                    let remapped = ItemTypeSettings(itemTypeID: mapped(value.itemTypeID, kind: .itemType), isShared: value.isShared, isEditable: value.isEditable)
                    let result = ItemTypeMembershipRecord.typeSettings(remapped)
                    transformed = .itemTypeMembership(result); transformedID = result.id
                case let .deckSettings(value):
                    let remapped = DeckItemTypeSettings(deckID: mapped(value.deckID, kind: .deck), inherits: value.inherits, itemTypeIDs: value.itemTypeIDs.map { mapped($0, kind: .itemType) }, defaultItemTypeID: value.defaultItemTypeID.map { mapped($0, kind: .itemType) })
                    let result = ItemTypeMembershipRecord.deckSettings(remapped)
                    transformed = .itemTypeMembership(result); transformedID = result.id
                case let .library(itemTypeID):
                    let value = ItemTypeMembershipRecord.library(itemTypeID: mapped(itemTypeID, kind: .itemType))
                    transformed = .itemTypeMembership(value); transformedID = value.id
                case let .included(rootDeckID, itemTypeID, ordinal):
                    let value = ItemTypeMembershipRecord.included(rootDeckID: mapped(rootDeckID, kind: .deck), itemTypeID: mapped(itemTypeID, kind: .itemType), ordinal: ordinal)
                    transformed = .itemTypeMembership(value); transformedID = value.id
                case let .policy(deckID, itemTypeID, ordinal, isDefault):
                    let value = ItemTypeMembershipRecord.policy(deckID: mapped(deckID, kind: .deck), itemTypeID: mapped(itemTypeID, kind: .itemType), ordinal: ordinal, isDefault: isDefault)
                    transformed = .itemTypeMembership(value); transformedID = value.id
                }
            case let .portableTypeMapping(mapping):
                let value = PortableItemTypeMappingRecord(
                    originLibraryID: mapping.originLibraryID == sourceLibraryID ? canonicalLibraryID : mapping.originLibraryID,
                    originTypeID: mapping.originTypeID,
                    schemaDigest: mapping.schemaDigest,
                    localTypeID: mapped(mapping.localTypeID, kind: .itemType)
                )
                transformed = .portableTypeMapping(value); transformedID = value.id
            default:
                return record
            }
            // Retain the original bytes when identity normalization is a no-op.
            // Date round-trips can otherwise change a payload by a floating-point
            // fraction and cause thousands of unnecessary uploads/conflicts.
            if transformed == payload && transformedID == record.id { return record }
            return SyncRecordEnvelope(
                id: transformedID,
                resourceKind: record.resourceKind,
                revision: record.revision,
                deviceID: record.deviceID,
                order: record.order,
                isTombstone: record.isTombstone,
                payload: try encoder.encode(transformed),
                asset: record.asset,
                stagedFileURL: record.stagedFileURL
            )
        }
    }

    private func validateEnvelope(_ record: SyncRecordEnvelope) throws {
        guard let kind = LibraryResourceKind(rawValue: record.resourceKind) else {
            throw SQLiteLibrarySyncError.unknownResourceKind(record.resourceKind)
        }
        if kind == .studyResponse { return }
        if record.isTombstone {
            if [.library, .deck, .itemType, .item, .card, .review, .reviewRevert].contains(kind),
               UUID(uuidString: record.id) == nil { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
            return
        }
        let payload: SyncPayload
        do { payload = try decoder.decode(SyncPayload.self, from: record.payload) }
        catch { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
        let expected: (LibraryResourceKind, String)
        switch payload {
        case let .library(id): expected = (.library, id.uuidString)
        case let .deck(value): expected = (.deck, value.id.uuidString)
        case let .itemType(value): expected = (.itemType, value.id.uuidString)
        case let .item(value): expected = (.item, value.item.id.uuidString)
        case let .card(value): expected = (.card, value.id.uuidString)
        case let .review(value): expected = (.review, value.log.id.uuidString)
        case let .reviewRevert(value): expected = (.reviewRevert, value.id.uuidString)
        case let .itemTypeMembership(value): expected = (.itemTypeMembership, value.id)
        case let .schedulingSettings(value): expected = (.schedulingSettings, value.id)
        case let .portableTypeMapping(value): expected = (.portableTypeMapping, value.id)
        case let .metadata(name, id):
            guard name == LibraryResourceKind.media.rawValue else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
            expected = (.media, id)
        }
        guard kind == expected.0, record.id == expected.1 else { throw SQLiteLibrarySyncError.invalidPayload(record.id) }
    }

    private func deterministicID(
        sourceLibraryID: UUID,
        resourceKind: String,
        originalID: UUID
    ) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("neoanki2:\(sourceLibraryID.uuidString):\(resourceKind):\(originalID.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
    }

    public func preservedConflictCopies() async -> [SyncConflictCopy] { conflictCopies }

    public func restoreConflictCopy(_ copy: SyncConflictCopy) async throws {
        let payload: SyncPayload
        do { payload = try decoder.decode(SyncPayload.self, from: copy.payload) }
        catch { throw SQLiteLibrarySyncError.invalidPayload(copy.originalResourceID) }
        switch payload {
        case let .deck(deck):
            if let original = try await existingDeck(id: deck.id), original == deck { break }
            if try await existingDeck(id: copy.id) != nil { break }
            let restored = Deck(
                id: copy.id,
                name: "\(deck.name) (Recovered)",
                parentID: deck.parentID,
                newCardsPerDay: deck.newCardsPerDay,
                includeInAllDecksStudy: deck.includeInAllDecksStudy
            )
            _ = try await repository.createDeck(restored)
        case let .item(record):
            let item = record.item
            if let original = try await existingItem(id: item.id), original == item { break }
            if try await existingItem(id: copy.id) != nil { break }
            let restored = Item(
                id: copy.id,
                itemTypeID: item.itemTypeID,
                fields: item.fields,
                tags: item.tags,
                deckID: item.deckID
            )
            _ = try await repository.createItem(restored, asOf: .now)
        case let .itemType(type):
            if let original = try await existingItemType(id: type.id), original == type { break }
            if try await existingItemType(id: copy.id) != nil { break }
            let restored = ItemType(
                id: copy.id,
                name: "\(type.name) (Recovered)",
                fields: type.fields,
                templates: type.templates,
                    lists: type.lists
            )
            try ItemTypeValidation.validate(restored)
            _ = try await repository.createItemType(restored)
        default:
            throw SQLiteLibrarySyncError.invalidPayload(copy.originalResourceID)
        }
        conflictCopies.removeAll { $0.id == copy.id }
    }

    private func existingDeck(id: UUID) async throws -> Deck? {
        do { return try await repository.deck(id: id) }
        catch DatabaseError.deckNotFound { return nil }
    }

    private func existingItem(id: UUID) async throws -> Item? {
        do { return try await repository.itemRecord(id: id).item }
        catch DatabaseError.itemNotFound { return nil }
    }

    private func existingItemType(id: UUID) async throws -> ItemType? {
        do { return try await repository.itemType(id: id) }
        catch DatabaseError.itemTypeNotFound { return nil }
    }

    private func payload(kind: LibraryResourceKind, id: String, deferMedia: Bool = false) async throws -> (payload: SyncPayload, asset: SyncAssetDescriptor?, fileURL: URL?) {
        switch kind {
        case .library:
            return (.library(try await repository.libraryID()), nil, nil)
        case .deck:
            guard let uuid = UUID(uuidString: id) else { throw SQLiteLibrarySyncError.invalidPayload(id) }
            return (.deck(try await repository.deck(id: uuid)), nil, nil)
        case .itemType:
            guard let uuid = UUID(uuidString: id), let type = try await repository.loadItemTypes().itemTypes.first(where: { $0.id == uuid }) else { throw SQLiteLibrarySyncError.missingResource(id) }
            return (.itemType(type), nil, nil)
        case .item:
            guard let uuid = UUID(uuidString: id) else { throw SQLiteLibrarySyncError.invalidPayload(id) }
            return (.item(try await repository.synchronizedItemRecord(id: uuid)), nil, nil)
        case .card:
            guard let uuid = UUID(uuidString: id) else { throw SQLiteLibrarySyncError.invalidPayload(id) }
            return (.card(try await repository.card(id: uuid)), nil, nil)
        case .review:
            guard let uuid = UUID(uuidString: id) else { throw SQLiteLibrarySyncError.invalidPayload(id) }
            return (.review(try await repository.synchronizedReviewRecord(id: uuid)), nil, nil)
        case .reviewRevert:
            guard let uuid = UUID(uuidString: id) else { throw SQLiteLibrarySyncError.invalidPayload(id) }
            return (.reviewRevert(try await repository.reviewRevertRecord(id: uuid)), nil, nil)
        case .studyResponse:
            throw SQLiteLibrarySyncError.unknownResourceKind(kind.rawValue)
        case .media:
            if deferMedia {
                guard let asset = try await repository.mediaAsset(hash: id) else { throw SQLiteLibrarySyncError.invalidAsset(id) }
                return (.metadata(kind: kind.rawValue, id: id), SyncAssetDescriptor(hash: asset.hash,
                    byteSize: Int64(asset.byteSize), signature: asset.hash, fileExtension: asset.fileExtension,
                    contentType: contentType(for: asset.kind)), nil)
            }
            let (asset, bytes) = try await repository.mediaBytes(hash: id)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == asset.hash, bytes.count == asset.byteSize else { throw SQLiteLibrarySyncError.invalidAsset(id) }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("neoanki-sync-\(UUID().uuidString)")
                .appendingPathExtension(asset.fileExtension)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let descriptor = SyncAssetDescriptor(
                hash: asset.hash,
                byteSize: Int64(asset.byteSize),
                signature: digest,
                fileExtension: asset.fileExtension,
                contentType: contentType(for: asset.kind)
            )
            return (.metadata(kind: kind.rawValue, id: id), descriptor, url)
        case .itemTypeMembership:
            return (.itemTypeMembership(try await repository.itemTypeMembershipRecord(id: id)), nil, nil)
        case .schedulingSettings:
            return (.schedulingSettings(try await repository.schedulingSettingsRecord(id: id)), nil, nil)
        case .portableTypeMapping:
            return (.portableTypeMapping(try await repository.portableItemTypeMappingRecord(id: id)), nil, nil)
        }
    }

    private func dependencyOrdered(_ records: [SyncRecordEnvelope]) -> [SyncRecordEnvelope] {
        let order: [String: Int] = ["library": 0, "deck": 1, "itemType": 2, "itemTypeMembership": 3, "item": 4, "card": 5, "review": 6, "reviewRevert": 7, "media": 8, "schedulingSettings": 9, "portableTypeMapping": 10]
        return records.sorted { (order[$0.resourceKind] ?? 99, $0.order) < (order[$1.resourceKind] ?? 99, $1.order) }
    }
    private func key(kind: String, id: String) -> String { "\(kind):\(id)" }
    private func contentType(for kind: MediaKind) -> String {
        switch kind { case .audio: "audio"; case .image: "image"; case .gif: "gif"; case .video: "video" }
    }
}
