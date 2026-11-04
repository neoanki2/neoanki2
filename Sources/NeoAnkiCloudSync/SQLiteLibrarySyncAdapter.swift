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

/// Production bridge between the typed SQLite repository and durable sync
/// envelopes. Domain objects are decoded and validated before repository
/// mutation; assets are staged and content-address verified before ingestion.
public actor SQLiteLibrarySyncAdapter: LibrarySyncAdapter {
    private let repository: SQLiteLibraryRepository
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var echoedResources: [String: SyncRecordEnvelope] = [:]
    private var conflictCopies: [SyncConflictCopy] = []

    public init(repository: SQLiteLibraryRepository) {
        self.repository = repository
        encoder.outputFormatting = [.sortedKeys]
    }

    public func encode(changes: [LibraryChange], deviceID: String) async throws -> [SyncRecordEnvelope] {
        try await encode(changes: changes, deviceID: deviceID, consumeEchoes: true)
    }

    private func encode(
        changes: [LibraryChange], deviceID: String, consumeEchoes: Bool
    ) async throws -> [SyncRecordEnvelope] {
        var records: [SyncRecordEnvelope] = []
        records.reserveCapacity(changes.count)
        for change in changes {
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
            let encoded = try await payload(kind: kind, id: change.resourceID)
            let bytes = try encoder.encode(encoded.payload)
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
        _ = origin
        let aliases = try await repository.syncItemTypeAliases()
        let records = try normalizeRemote(
            records, against: [], canonicalLibraryID: try await repository.libraryID(),
            sourceLibraryID: nil, knownAliases: [], typeRemap: aliases, dropAliasedTypes: false
        )
        // Validate all assets before any domain row commits. A corrupt media
        // envelope must not leave the accompanying item/deck partially applied.
        for record in records where record.resourceKind == LibraryResourceKind.media.rawValue && !record.isTombstone {
            try validateAsset(record)
        }
        var mutations: [SynchronizedLibraryMutation] = []
        var media: [(SyncPayload, SyncRecordEnvelope)] = []
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
                case let .deck(value): mutations.append(.deck(value))
                case let .itemType(value):
                    try ItemTypeValidation.validate(value)
                    mutations.append(.itemType(value))
                case let .item(value): mutations.append(.item(value.item, createdAt: value.createdAt, updatedAt: value.updatedAt))
                case let .card(value): mutations.append(.card(value))
                case let .review(value): mutations.append(.review(value))
                case let .reviewRevert(value): mutations.append(.reviewRevert(value))
                case let .itemTypeMembership(value): mutations.append(.itemTypeMembership(value))
                case let .schedulingSettings(value): mutations.append(.schedulingSettings(value))
                case let .portableTypeMapping(value): mutations.append(.portableTypeMapping(value))
                case .metadata: media.append((payload, record))
                }
            }
        }
        try await repository.applySynchronizedBatch(mutations)
        for (payload, envelope) in media { try await apply(payload, envelope: envelope) }
        for record in records {
            echoedResources[key(kind: record.resourceKind, id: record.id)] = record
        }
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
                        let isDeck = components.first != "library" && index == 1
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
                    newCardsPerDay: deck.newCardsPerDay
                )
                transformed = .deck(value); transformedID = value.id.uuidString
            case let .itemType(type):
                let value = ItemType(
                    id: mapped(type.id, kind: .itemType),
                    name: type.name,
                    fields: type.fields,
                    templates: type.templates
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
                    occlusionGroup: card.occlusionGroup, clozeGroup: card.clozeGroup
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
                        schedulingAudit: log.schedulingAudit
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

    private func validateAsset(_ envelope: SyncRecordEnvelope) throws {
        guard let descriptor = envelope.asset, let url = envelope.stagedFileURL,
              descriptor.hash == envelope.id, descriptor.byteSize >= 0 else {
            throw SQLiteLibrarySyncError.invalidAsset(envelope.id)
        }
        guard let kind = MediaKind(rawValue: descriptor.contentType) else {
            throw SQLiteLibrarySyncError.invalidAsset(envelope.id)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        do {
            try MediaValidation.validate(data: data, kind: kind, fileExtension: descriptor.fileExtension)
            _ = try MediaValidation.inferredExtension(data: data, expectedKind: kind)
        } catch { throw SQLiteLibrarySyncError.invalidAsset(envelope.id) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == descriptor.byteSize, digest == descriptor.hash, digest == descriptor.signature else {
            throw SQLiteLibrarySyncError.invalidAsset(envelope.id)
        }
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
                newCardsPerDay: deck.newCardsPerDay
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
                templates: type.templates
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

    private func payload(kind: LibraryResourceKind, id: String) async throws -> (payload: SyncPayload, asset: SyncAssetDescriptor?, fileURL: URL?) {
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
            let (asset, bytes) = try await repository.mediaBytes(hash: id)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == asset.hash, bytes.count == asset.byteSize else { throw SQLiteLibrarySyncError.invalidAsset(id) }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("neoanki-sync-\(UUID().uuidString)")
                .appendingPathExtension(asset.fileExtension)
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
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

    private func apply(_ payload: SyncPayload, envelope: SyncRecordEnvelope) async throws {
        switch payload {
        case .library:
            break // Library identity is aliased during merge, never overwritten.
        case let .deck(deck):
            if (try? await repository.deck(id: deck.id)) != nil { _ = try await repository.updateDeck(deck) }
            else { _ = try await repository.createDeck(deck) }
        case let .itemType(type):
            try ItemTypeValidation.validate(type)
            if try await repository.loadItemTypes().itemTypes.contains(where: { $0.id == type.id }) {
                _ = try await repository.updateItemType(type, asOf: .now)
            } else { _ = try await repository.createItemType(type) }
        case let .item(record):
            guard try await repository.loadItemTypes().itemTypes.contains(where: { $0.id == record.item.itemTypeID }) else {
                throw SQLiteLibrarySyncError.invalidPayload(envelope.id)
            }
            try await repository.applySynchronizedBatch([.item(record.item, createdAt: record.createdAt, updatedAt: record.updatedAt)])
        case let .card(card):
            try await repository.applySynchronizedCard(card)
        case let .review(record):
            try await repository.applySynchronizedBatch([.review(record)])
        case let .reviewRevert(record):
            try await repository.applySynchronizedBatch([.reviewRevert(record)])
        case let .itemTypeMembership(record):
            try await repository.applySynchronizedBatch([.itemTypeMembership(record)])
        case let .schedulingSettings(record):
            try await repository.applySynchronizedBatch([.schedulingSettings(record)])
        case let .portableTypeMapping(record):
            try await repository.applySynchronizedBatch([.portableTypeMapping(record)])
        case .metadata:
            if let descriptor = envelope.asset, let url = envelope.stagedFileURL {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == descriptor.byteSize, digest == descriptor.hash, digest == descriptor.signature else {
                    throw SQLiteLibrarySyncError.invalidAsset(envelope.id)
                }
                let kind: MediaKind = switch descriptor.contentType {
                case "audio": .audio
                case "video": .video
                case "gif": .gif
                default: .image
                }
                let reserved = try await repository.reserveMedia(data: data, kind: kind, altText: nil, reservationID: UUID(), asOf: .now)
                guard reserved.reference.assetHash == descriptor.hash else { throw SQLiteLibrarySyncError.invalidAsset(envelope.id) }
            }
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
