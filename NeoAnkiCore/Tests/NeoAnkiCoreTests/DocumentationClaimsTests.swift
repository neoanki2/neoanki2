import Foundation
import Testing

@testable import NeoAnkiCore

private struct DocumentationClaims: Decodable {
    struct Evidence: Decodable {
        let article: String
        let source: String
    }

    struct Media: Decodable {
        let article: String
        let source: String
        let maximumBytes: [String: Int]
        let allowedExtensions: [String: [String]]
    }

    struct ItemImport: Decodable {
        let article: String
        let source: String
        let maximumPayloadBytes: Int
        let maximumRows: Int
        let maximumFieldsPerRow: Int
        let maximumFieldBytes: Int
        let csvEncoding: String
    }

    struct PortableDeck: Decodable {
        let article: String
        let source: String
        let formatVersion: Int
        let maximumFileBytes: Int64
        let maximumDecks: Int
        let maximumItemTypes: Int
        let maximumItems: Int
        let maximumFieldsPerType: Int
        let maximumTemplatesPerType: Int
        let maximumTagsPerItem: Int
        let maximumMediaAssets: Int
        let maximumTotalMediaBytes: Int64
    }

    struct AuthoredDeck: Decodable {
        let article: String
        let source: String
        let maximumSourceBytes: Int
        let maximumTotalSourceBytes: Int
        let maximumLineBytes: Int
        let maximumParts: Int
    }

    struct Scheduling: Decodable {
        let article: String
        let source: String
        let minimumReviewOutcomes: Int
        let minimumReviewsPerCardForOutcome: Int
    }

    struct Scheduler: Decodable {
        let article: String
        let source: String
        let model: String
        let minimumIntervalDays: Int
        let defaultRequestRetention: Double
        let defaultMaximumIntervalDays: Int
    }

    let schemaVersion: Int
    let media: Media
    let itemImport: ItemImport
    let portableDeck: PortableDeck
    let authoredDeck: AuthoredDeck
    let scheduling: Scheduling
    let scheduler: Scheduler
}

private func documentationClaims() throws -> DocumentationClaims {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repositoryRoot.appendingPathComponent("docs/claims.json")
    return try JSONDecoder().decode(
        DocumentationClaims.self,
        from: Data(contentsOf: url)
    )
}

@Test func documentationClaimsMatchProductionConstants() throws {
    let claims = try documentationClaims()
    #expect(claims.schemaVersion == 1)

    let mediaKinds: [(String, MediaKind)] = [
        ("audio", .audio),
        ("image", .image),
        ("gif", .gif),
        ("video", .video),
    ]
    for (name, kind) in mediaKinds {
        #expect(claims.media.maximumBytes[name] == MediaValidation.maxBytes(for: kind))
        #expect(Set(claims.media.allowedExtensions[name] ?? []) == MediaValidation.allowedExtensions(for: kind))
    }

    #expect(claims.itemImport.maximumPayloadBytes == ImportLimits.maxPayloadBytes)
    #expect(claims.itemImport.maximumRows == ImportLimits.maxRows)
    #expect(claims.itemImport.maximumFieldsPerRow == ImportLimits.maxFieldsPerRow)
    #expect(claims.itemImport.maximumFieldBytes == ImportLimits.maxFieldStringBytes)
    #expect(claims.itemImport.csvEncoding == "UTF-8")
    #expect(throws: ImportError.self) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(Data([0xFF, 0xFE]))
    }

    let portable = PortableDeckLimits.default
    #expect(claims.portableDeck.formatVersion == PortableDeck.version)
    #expect(claims.portableDeck.maximumFileBytes == portable.maximumFileBytes)
    #expect(claims.portableDeck.maximumDecks == portable.maximumDecks)
    #expect(claims.portableDeck.maximumItemTypes == portable.maximumItemTypes)
    #expect(claims.portableDeck.maximumItems == portable.maximumItems)
    #expect(claims.portableDeck.maximumFieldsPerType == portable.maximumFieldsPerType)
    #expect(claims.portableDeck.maximumTemplatesPerType == portable.maximumTemplatesPerType)
    #expect(claims.portableDeck.maximumTagsPerItem == portable.maximumTagsPerItem)
    #expect(claims.portableDeck.maximumMediaAssets == portable.maximumMediaAssets)
    #expect(claims.portableDeck.maximumTotalMediaBytes == portable.maximumTotalMediaBytes)

    let authored = AuthoredDeckLimits.default
    #expect(claims.authoredDeck.maximumSourceBytes == authored.maximumSourceBytes)
    #expect(claims.authoredDeck.maximumTotalSourceBytes == authored.maximumTotalSourceBytes)
    #expect(claims.authoredDeck.maximumLineBytes == authored.maximumLineBytes)
    #expect(claims.authoredDeck.maximumParts == authored.maximumParts)

    #expect(
        claims.scheduling.minimumReviewOutcomes
            == FSRSOptimizer.defaultMinimumObservations
    )
    #expect(
        claims.scheduling.minimumReviewsPerCardForOutcome
            == FSRSOptimizer.minimumReviewsPerCardForOutcome
    )

    let scheduler = FSRSScheduler.Parameters()
    #expect(claims.scheduler.model == "FSRS-\(FSRSScheduler.Parameters.modelVersion)")
    #expect(
        claims.scheduler.minimumIntervalDays
            == FSRSScheduler.Parameters.minimumInterval
    )
    #expect(
        claims.scheduler.defaultRequestRetention
            == scheduler.requestRetention
    )
    #expect(
        claims.scheduler.defaultMaximumIntervalDays
            == scheduler.maximumInterval
    )
}
