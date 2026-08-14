import CryptoKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore

private enum SyncPayload: Codable {
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
    private var echoedResources: [String: Int] = [:]
    private var conflictCopies: [SyncConflictCopy] = []

    public init(repository: SQLiteLibraryRepository) {
        self.repository = repository
        encoder.outputFormatting = [.sortedKeys]
    }

    public func encode(changes: [LibraryChange], deviceID: String) async throws -> [SyncRecordEnvelope] {
        var records: [SyncRecordEnvelope] = []
        records.reserveCapacity(changes.count)
        for change in changes {
            let echoKey = key(kind: change.resourceType, id: change.resourceID)
            if let count = echoedResources[echoKey], count > 0 {
                if count == 1 { echoedResources.removeValue(forKey: echoKey) }
                else { echoedResources[echoKey] = count - 1 }
                continue
            }
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
            records.append(.init(
                id: change.resourceID,
                resourceKind: kind.rawValue,
                revision: change.revision,
                deviceID: deviceID,
                order: change.cursor,
                isTombstone: false,
                payload: try encoder.encode(encoded.payload),
                asset: encoded.asset,
                stagedFileURL: encoded.fileURL
            ))
        }
        return records
    }

    public func applyRemote(_ records: [SyncRecordEnvelope], origin: LibraryChangeOrigin) async throws {
        _ = origin
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
            echoedResources[key(kind: record.resourceKind, id: record.id), default: 0] += 1
        }
    }

    public func initialMerge(remote: [SyncRecordEnvelope], deviceID: String) async throws -> [SyncRecordEnvelope] {
        let localChanges = try await allLocalChanges()
        let local = try await encode(changes: localChanges, deviceID: deviceID)
        let canonicalLibraryID = try await repository.libraryID()
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
        let normalizedRemote = try normalizeRemote(
            remote,
            against: local,
            canonicalLibraryID: canonicalLibraryID,
            sourceLibraryID: remoteLibraryIDs.first
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
        return merge.accepted.map {
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
        var result: [LibraryChange] = []
        var cursor: Int64 = 0
        while true {
            let page = try await repository.changes(after: cursor, limit: 1_000)
            guard !page.isEmpty else { return result }
            result.append(contentsOf: page)
            cursor = page[page.count - 1].cursor
            if page.count < 1_000 { return result }
        }
    }

    private func normalizeRemote(
        _ remote: [SyncRecordEnvelope],
        against local: [SyncRecordEnvelope],
        canonicalLibraryID: UUID,
        sourceLibraryID: UUID?
    ) throws -> [SyncRecordEnvelope] {
        var localByDigest: [String: UUID] = [:]
        for record in local where record.resourceKind == LibraryResourceKind.itemType.rawValue && !record.isTombstone {
            guard let payload = try? decoder.decode(SyncPayload.self, from: record.payload),
                  case let .itemType(type) = payload else { continue }
            localByDigest[try PortableItemTypeIdentity.schemaDigest(of: type)] = type.id
        }
        var typeRemap: [UUID: UUID] = [:]
        for record in remote where record.resourceKind == LibraryResourceKind.itemType.rawValue && !record.isTombstone {
            guard let payload = try? decoder.decode(SyncPayload.self, from: record.payload),
                  case let .itemType(type) = payload,
                  let canonical = localByDigest[try PortableItemTypeIdentity.schemaDigest(of: type)],
                  canonical != type.id else { continue }
            typeRemap[type.id] = canonical
        }

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
                collisionRemaps[record.resourceKind, default: [:]][id] = deterministicID(
                    sourceLibraryID: sourceLibraryID,
                    resourceKind: record.resourceKind,
                    originalID: id
                )
            }
        }

        func mapped(_ id: UUID, kind: LibraryResourceKind) -> UUID {
            if kind == .itemType, let canonical = typeRemap[id] { return canonical }
            return collisionRemaps[kind.rawValue]?[id] ?? id
        }

        return try remote.compactMap { record in
            if record.isTombstone {
                guard let id = UUID(uuidString: record.id),
                      let replacement = collisionRemaps[record.resourceKind]?[id]
                else { return record }
                return SyncRecordEnvelope(
                    id: replacement.uuidString,
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
            case let .itemType(type) where typeRemap[type.id] != nil:
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
                    isSuspended: card.isSuspended,
                    deckID: card.deckID.map { mapped($0, kind: .deck) },
                    clozeGroup: card.clozeGroup
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
                        sequence: log.sequence
                    ),
                    memoryBefore: review.memoryBefore
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
            let restored = Deck(
                id: UUID(),
                name: "\(deck.name) (Recovered)",
                parentID: deck.parentID,
                newCardsPerDay: deck.newCardsPerDay
            )
            _ = try await repository.createDeck(restored)
        case let .item(record):
            let item = record.item
            let restored = Item(
                id: UUID(),
                itemTypeID: item.itemTypeID,
                fields: item.fields,
                tags: item.tags,
                deckID: item.deckID
            )
            _ = try await repository.createItem(restored, asOf: .now)
        case let .itemType(type):
            let restored = ItemType(
                id: UUID(),
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
