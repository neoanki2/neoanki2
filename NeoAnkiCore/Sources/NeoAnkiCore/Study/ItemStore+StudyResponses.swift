import Foundation

public extension ItemStore {
    @discardableResult
    func completeAudioSubmission(
        _ draft: StudyResponseDraft,
        submittedAt: Date = .now
    ) async throws -> StudyResponse {
        guard let mediaStore else {
            throw DatabaseError.invalidMediaAsset("Media storage is unavailable.")
        }
        let reservationScope = UUID()
        do {
            let media = try await mediaStore.ingest(
                url: draft.fileURL,
                kind: .audio,
                reservationScope: reservationScope
            )
            guard let reservationID = media.reservationID else {
                throw DatabaseError.invalidMediaAsset("The audio reservation was not created.")
            }
            let response = try await database.completeStudyResponse(
                id: draft.id,
                cardID: draft.cardID,
                media: media,
                reservationID: reservationID,
                durationMilliseconds: draft.durationMilliseconds,
                capturedAt: draft.capturedAt,
                submittedAt: submittedAt
            )
            try? await mediaStore.releaseReservations(scopeID: reservationScope)
            return response
        } catch {
            try? await mediaStore.rollbackReservations(scopeID: reservationScope)
            throw error
        }
    }

    func studyResponse(id: UUID) async throws -> StudyResponse {
        guard let response = try await database.fetchStudyResponse(id: id) else {
            throw DatabaseError.studyResponseNotFound(id)
        }
        return response
    }

    func studyResponses(
        matching query: StudyResponseQuery = StudyResponseQuery()
    ) async throws -> [StudyResponse] {
        guard (1 ... 1_000).contains(query.limit) else {
            throw DatabaseError.queryFailed("Study response limit must be between 1 and 1000.")
        }
        var collected: [StudyResponse] = []
        var before = query.submittedBefore
        var beforeID = query.submittedBeforeID
        repeat {
            let batch = try await database.fetchStudyResponses(
                cardID: query.cardID,
                itemID: query.itemID,
                createdAfter: query.createdAfter,
                submittedBefore: before,
                submittedBeforeID: beforeID,
                limit: min(250, max(query.limit * 2, 50))
            )
            if batch.isEmpty { break }
            for response in batch {
                if let tag = query.tag {
                    guard let item = try await database.fetchItem(id: response.itemID)?.item,
                          item.tags.contains(where: {
                              $0.compare(
                                  tag.trimmingCharacters(in: .whitespacesAndNewlines),
                                  options: [.caseInsensitive, .diacriticInsensitive]
                              ) == .orderedSame
                          })
                    else { continue }
                }
                collected.append(response)
                if collected.count == query.limit { break }
            }
            guard collected.count < query.limit, let last = batch.last else { break }
            before = last.submittedAt
            beforeID = last.id
            if batch.count < min(250, max(query.limit * 2, 50)) { break }
        } while true
        return collected
    }

    @discardableResult
    func deleteStudyResponse(id: UUID, asOf now: Date = .now) async throws -> Bool {
        let deleted = try await database.deleteStudyResponse(id: id)
        if deleted { _ = try? await collectMediaGarbage(asOf: now) }
        return deleted
    }

    func studyResponseMediaBytes(id: UUID) async throws -> (StudyResponse, MediaAsset, Data) {
        let response = try await studyResponse(id: id)
        let (asset, bytes) = try await mediaBytes(hash: response.mediaHash)
        return (response, asset, bytes)
    }

    func ordinaryMediaReferenceCount(hash: String) async throws -> Int {
        try await database.ordinaryMediaReferenceCount(hash: hash)
    }

    func isStudyResponseMediaHash(_ hash: String) async throws -> Bool {
        try await database.isStudyResponseMediaHash(hash)
    }

    func studyResponseCount(cardIDs: Set<UUID>) async throws -> Int {
        try await database.countStudyResponses(cardIDs: cardIDs)
    }

    func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int {
        try await database.countStudyResponses(itemIDs: itemIDs)
    }

    func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int {
        try await database.countStudyResponses(templateIDs: templateIDs)
    }
}
