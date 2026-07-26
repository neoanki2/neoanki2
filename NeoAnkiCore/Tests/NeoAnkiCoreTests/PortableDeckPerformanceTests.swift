import Darwin
import Foundation
import Testing
@testable import NeoAnkiCore

/// Opt-in benchmark:
/// `NEOANKI_RUN_PORTABLE_BENCHMARKS=10000 swift test --filter portableDeckImportBenchmark`
/// Repeat with `100000` for the large regression fixture.
@Test func portableDeckImportBenchmark() async throws {
    guard let rawCount = ProcessInfo.processInfo.environment["NEOANKI_RUN_PORTABLE_BENCHMARKS"],
          let itemCount = Int(rawCount),
          [10_000, 100_000].contains(itemCount)
    else { return }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portable-deck-benchmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
    let source = try ItemStore(
        databaseURL: sourceRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: sourceRoot)
    )
    try await source.bootstrap()
    let deck = try await source.createDeck(Deck(name: "Benchmark"))
    let type = try await source.defaultItemType()
    let now = Date.now
    let entries = (0..<itemCount).map { index in
        let item = Item(
            itemTypeID: type.id,
            fields: [
                FieldValue(fieldID: type.fields[0].id, value: .text("Question \(index)")),
                FieldValue(fieldID: type.fields[1].id, value: .text("Answer \(index)")),
            ],
            tags: ["benchmark"],
            deckID: deck.id
        )
        return (item: item, cards: CardGenerator.cards(for: item, type: type, now: now))
    }
    try await source.database.insertItemsWithCards(entries, createdAt: now, updatedAt: now)

    let packageURL = directory.appendingPathComponent("benchmark.neodeck")
    let exportStart = ContinuousClock.now
    try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
    let exportDuration = exportStart.duration(to: .now)

    let destinationRoot = directory.appendingPathComponent("destination", isDirectory: true)
    let destination = try ItemStore(
        databaseURL: destinationRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: destinationRoot)
    )
    try await destination.bootstrap()
    let importStart = ContinuousClock.now
    let result = try await PortableDeck.importDeck(from: packageURL, into: destination)
    let importDuration = importStart.duration(to: .now)
    let packageBytes = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    var usage = rusage()
    _ = getrusage(RUSAGE_SELF, &usage)

    print(
        "portable-deck-benchmark items=\(itemCount) package_bytes=\(packageBytes) "
            + "peak_rss_bytes=\(usage.ru_maxrss) "
            + "export=\(exportDuration) import=\(importDuration)"
    )
    #expect(result.itemCount == itemCount)
    #expect(try await destination.listItems().count == itemCount)
    // Initial guardrail: at least 500 imported items/second plus fixed startup allowance.
    #expect(importDuration < .seconds(Double(itemCount) / 500.0 + 5.0))
}
