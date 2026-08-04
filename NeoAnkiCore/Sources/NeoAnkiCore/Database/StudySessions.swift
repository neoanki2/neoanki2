import Foundation

public enum StudySessionState: String, Codable, Sendable, Equatable {
    case active
    case ended
}

public struct StudySessionRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let clientID: UUID
    public let scope: DeckScope
    public let state: StudySessionState
    public let revision: Int
    public let currentCardID: UUID?
    public let createdAt: Date
    public let lastActivityAt: Date

    public init(
        id: UUID,
        clientID: UUID,
        scope: DeckScope,
        state: StudySessionState,
        revision: Int,
        currentCardID: UUID?,
        createdAt: Date,
        lastActivityAt: Date
    ) {
        self.id = id
        self.clientID = clientID
        self.scope = scope
        self.state = state
        self.revision = revision
        self.currentCardID = currentCardID
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}

struct StoredStudyScope: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case allDecks, unassigned, deck
    }

    let kind: Kind
    let deckID: UUID?
    let includeDescendants: Bool?

    init(_ scope: DeckScope) {
        switch scope {
        case .allDecks:
            kind = .allDecks
            deckID = nil
            includeDescendants = nil
        case .unassigned:
            kind = .unassigned
            deckID = nil
            includeDescendants = nil
        case let .deck(id, includeDescendants):
            kind = .deck
            deckID = id
            self.includeDescendants = includeDescendants
        }
    }

    var scope: DeckScope? {
        switch kind {
        case .allDecks: .allDecks
        case .unassigned: .unassigned
        case .deck:
            deckID.map { .deck($0, includeDescendants: includeDescendants ?? false) }
        }
    }
}

public extension ItemStore {
    func createStudySession(
        id: UUID = UUID(),
        clientID: UUID,
        scope: DeckScope,
        now: Date = .now
    ) async throws -> StudySessionRecord {
        if case let .deck(deckID, _) = scope {
            guard try await database.fetchDeck(id: deckID) != nil else {
                throw DatabaseError.deckNotFound(deckID)
            }
        }
        try await database.insertStudySession(
            id: id,
            clientID: clientID,
            scope: StoredStudyScope(scope),
            now: now
        )
        guard let session = try await database.fetchStudySession(id: id) else {
            throw DatabaseError.studySessionNotFound(id)
        }
        return session
    }

    func studySession(id: UUID) async throws -> StudySessionRecord {
        guard let session = try await database.fetchStudySession(id: id) else {
            throw DatabaseError.studySessionNotFound(id)
        }
        return session
    }

    /// Atomically selects and reserves one eligible due card. Returning the
    /// existing reservation makes retrying `next` safe before grading/skipping.
    func reserveNextStudyCard(
        sessionID: UUID,
        now: Date = .now,
        reservationLifetime: TimeInterval = 24 * 60 * 60
    ) async throws -> DueCard? {
        let session = try await studySession(id: sessionID)
        guard session.state == .active else {
            throw DatabaseError.studyConflict("The study session has ended.")
        }
        let cardScope: CardScope
        switch session.scope {
        case .allDecks:
            cardScope = .all
        case .unassigned:
            cardScope = .unassigned
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let tree = try await deckTreeSummaries()
                cardScope = .decks(DeckTree.descendantIDs(of: deckID, in: tree))
            } else {
                cardScope = .decks([deckID])
            }
        }
        let studyDay = try await studyDayKey(asOf: now)
        guard let card = try await database.reserveNextStudyCard(
            sessionID: sessionID,
            scope: cardScope,
            asOf: now,
            studyDay: studyDay,
            expiresAt: now.addingTimeInterval(reservationLifetime)
        ) else {
            return nil
        }
        return try await hydrateDueCards([card]).first
    }

    @discardableResult
    func skipReservedStudyCard(sessionID: UUID, cardID: UUID, now: Date = .now) async throws -> Bool {
        try await database.releaseStudyCard(
            sessionID: sessionID,
            cardID: cardID,
            now: now
        )
    }

    func endStudySession(id: UUID, now: Date = .now) async throws {
        try await database.endStudySession(id: id, now: now)
    }

    func submitReservedReview(
        sessionID: UUID,
        cardID: UUID,
        rating: ReviewRating,
        reviewLogID: UUID = UUID(),
        now: Date = .now,
        durationMs: Int = 0
    ) async throws -> ReviewSubmission {
        guard durationMs >= 0 else {
            throw DatabaseError.studyConflict("Review duration cannot be negative.")
        }
        guard var card = try await database.fetchCard(id: cardID) else {
            throw DatabaseError.cardNotFound(cardID)
        }
        let memoryBefore = card.memory
        let phaseBefore = card.memory.phase
        let elapsedDays = card.memory.lastReview.map {
            max(now.timeIntervalSince($0) / 86_400, 0)
        } ?? 0
        let scheduledDays = max(
            card.memory.lastReview.map { card.memory.due.timeIntervalSince($0) / 86_400 } ?? 0,
            0
        )
        let scheduler: any Scheduler = schedulerOverride
            ?? LearningScheduler(parameters: fsrsParameters)
        let nextMemory = scheduler.schedule(card.memory, rating: rating, now: now)
        card.memory = nextMemory
        let log = ReviewLog(
            id: reviewLogID,
            cardID: card.id,
            reviewedAt: now,
            rating: rating,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            phaseBefore: phaseBefore,
            durationMs: durationMs
        )
        let introducedDeckID = phaseBefore == .new ? card.deckID : nil
        let introductionStudyDay = introducedDeckID == nil
            ? nil
            : StudyDay.key(
                for: now,
                rolloverMinutes: try await studyDayRolloverMinutes()
            )
        try await database.persistReservedReview(
            sessionID: sessionID,
            cardID: cardID,
            memoryBefore: memoryBefore,
            memoryAfter: nextMemory,
            log: log,
            introducedDeckID: introducedDeckID,
            introductionStudyDay: introductionStudyDay,
            now: now
        )
        return ReviewSubmission(memory: nextMemory, reviewLogID: log.id)
    }
}
