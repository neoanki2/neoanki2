import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

/// Legacy entry point kept for direct invocations:
/// `NEOANKI_RUN_PORTABLE_BENCHMARKS=10000 swift test --filter portableDeckImportBenchmark`
/// Prefer `./Scripts/run-performance-tests.sh` with `NEOANKI_PERF_SCALE=large|stress`.
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
    _ = try await PerformanceFixtures.seedBasicItems(count: itemCount, in: source)
    for item in try await source.listItems() {
        _ = try await source.updateItemDeck(itemID: item.id, deckID: deck.id)
    }

    let packageURL = directory.appendingPathComponent("benchmark.neodeck")
    let exportMeasurement = try await PerformanceHarness.measure(
        flow: "portable-deck-export-legacy",
        metadata: ["item_count": "\(itemCount)"]
    ) {
        try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
        let packageBytes = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return ["package_bytes": "\(packageBytes)"]
    }
    _ = exportMeasurement

    let destinationRoot = directory.appendingPathComponent("destination", isDirectory: true)
    let destination = try ItemStore(
        databaseURL: destinationRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: destinationRoot)
    )
    try await destination.bootstrap()

    let measurement = try await PerformanceHarness.measure(
        flow: "portable-deck-import-legacy",
        metadata: [
            "item_count": "\(itemCount)",
            "package_bytes": exportMeasurement.metadata["package_bytes"] ?? "0",
        ]
    ) {
        let result = try await PortableDeck.importDeck(from: packageURL, into: destination)
        #expect(result.itemCount == itemCount)
        #expect(try await destination.listItems().count == itemCount)
        return ["imported_items": "\(result.itemCount)"]
    }
    #expect(measurement.durationSeconds < Double(itemCount) / 500.0 + 5.0)
}

/// Isolates the export cost of a tiny selected deck from the size of the
/// unrelated library around it.
@Test func portableDeckScopedExportBenchmark() async throws {
    guard let rawCount = ProcessInfo.processInfo.environment[
        "NEOANKI_RUN_PORTABLE_SCOPED_EXPORT_BENCHMARK"
    ],
          let unrelatedItemCount = Int(rawCount),
          unrelatedItemCount > 0
    else { return }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portable-scoped-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
    let source = try ItemStore(
        databaseURL: sourceRoot.appendingPathComponent("library.sqlite"),
        mediaStore: MediaStore(rootDirectory: sourceRoot)
    )
    try await source.bootstrap()
    _ = try await PerformanceFixtures.seedBasicItems(count: unrelatedItemCount, in: source)
    let deck = try await source.createDeck(Deck(name: "Selected"))
    let itemType = try await source.defaultItemType()
    for index in 0..<10 {
        _ = try await source.createItem(Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(
                    fieldID: itemType.fields[0].id,
                    value: .text("Selected question \(index)")
                ),
                FieldValue(
                    fieldID: itemType.fields[1].id,
                    value: .text("Selected answer \(index)")
                ),
            ],
            deckID: deck.id
        ))
    }

    let packageURL = directory.appendingPathComponent("selected.neodeck")
    let measurement = try await PerformanceHarness.measure(
        flow: "portable-deck-export-selected-from-large-library",
        metadata: [
            "selected_item_count": "10",
            "unrelated_item_count": "\(unrelatedItemCount)",
        ]
    ) {
        try await PortableDeck.export(deckID: deck.id, from: source, to: packageURL)
        let packageBytes = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return ["package_bytes": "\(packageBytes)"]
    }
    #expect(measurement.durationSeconds < Double(unrelatedItemCount) / 2_000.0 + 2.0)
}
