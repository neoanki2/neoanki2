import Foundation
import NeoAnkiCore
import Testing
import UniformTypeIdentifiers

@testable import NeoAnki2

@Test func deckTransferTypesRecognizeFilenameExtensions() {
    #expect(UTType.neoDeck.preferredFilenameExtension == PortableDeck.fileExtension)
    #expect(UTType.neoAnkiSource.preferredFilenameExtension == AuthoredDeck.fileExtension)
}

@MainActor
private final class PortableDeckScopedAccessSpy: SecurityScopedResourceAccessing {
    private(set) var started: [URL] = []
    private(set) var stopped: [URL] = []

    func startAccessing(_ url: URL) -> Bool {
        started.append(url)
        return true
    }

    func stopAccessing(_ url: URL) {
        stopped.append(url)
    }
}

@Test @MainActor func portableDeckExportTracksBusyStateAndScopedAccess() async {
    let access = PortableDeckScopedAccessSpy()
    let destination = URL(fileURLWithPath: "/tmp/example.neodeck")
    let model = PortableDeckTransferModel(
        scopedAccess: access,
        importOperation: { _, _ in
            throw PortableDeckError.invalidPackage("Unused")
        },
        exportOperation: { _, _ in
            try await Task.sleep(for: .milliseconds(50))
        }
    )

    let task = Task { await model.exportDeck(id: UUID(), to: destination) }
    await Task.yield()

    #expect(model.isBusy)
    #expect(await task.value)
    #expect(!model.isBusy)
    #expect(access.started == [destination])
    #expect(access.stopped == [destination])
    #expect(model.notice?.title == "Deck Exported")
}

@Test @MainActor func portableDeckImportExplainsAtomicSchemaConflict() async {
    let model = PortableDeckTransferModel(
        importOperation: { _, _ in
            throw PortableDeckError.typeConflict(
                origin: "origin",
                existingDigest: "existing",
                importedDigest: "imported"
            )
        },
        exportOperation: { _, _ in }
    )

    let result = await model.importDeck(
        from: URL(fileURLWithPath: "/tmp/conflict.neodeck")
    )

    #expect(result == nil)
    #expect(model.conflictingSource?.lastPathComponent == "conflict.neodeck")
    #expect(model.notice == nil)
}

@Test @MainActor func portableDeckExportFailureClearsBusyState() async {
    let model = PortableDeckTransferModel(
        importOperation: { _, _ in
            throw PortableDeckError.invalidPackage("Unused")
        },
        exportOperation: { _, _ in
            throw PortableDeckError.ioFailure("Disk is full.")
        }
    )

    #expect(
        await model.exportDeck(
            id: UUID(),
            to: URL(fileURLWithPath: "/tmp/failure.neodeck")
        ) == false
    )
    #expect(!model.isBusy)
    #expect(model.notice?.title == "Could Not Export Deck")
    #expect(model.notice?.message == "Disk is full.")
}

@Test @MainActor func portableDeckConflictResolutionRetriesWithUserChoice() async {
    var receivedResolutions: [PortableDeckTypeConflictResolution] = []
    let importedRoot = UUID()
    let model = PortableDeckTransferModel(
        importOperation: { _, resolution in
            receivedResolutions.append(resolution)
            if resolution == .reject {
                throw PortableDeckError.typeConflict(
                    origin: "origin",
                    existingDigest: "existing",
                    importedDigest: "imported"
                )
            }
            return PortableDeckImportResult(
                deckIDs: [importedRoot],
                itemCount: 1,
                createdItemTypeCount: 1,
                reusedItemTypeCount: 0
            )
        },
        exportOperation: { _, _ in }
    )
    let source = URL(fileURLWithPath: "/tmp/conflict.neodeck")

    #expect(await model.importDeck(from: source) == nil)
    let result = await model.resolveConflict(using: .importAsDistinctRevision)

    #expect(result?.deckIDs == [importedRoot])
    #expect(receivedResolutions == [.reject, .importAsDistinctRevision])
    #expect(model.conflictingSource == nil)
}

@Test @MainActor func authoredDeckImportDispatchesBySourceExtension() async {
    var portableCalls = 0
    var authoredCalls = 0
    let root = UUID()
    let model = PortableDeckTransferModel(
        importOperation: { _, _ in
            portableCalls += 1
            throw PortableDeckError.invalidPackage("Wrong importer")
        },
        authoredImportOperation: { _ in
            authoredCalls += 1
            return PortableDeckImportResult(
                deckIDs: [root],
                itemCount: 2,
                createdItemTypeCount: 1,
                reusedItemTypeCount: 0
            )
        },
        exportOperation: { _, _ in }
    )

    let result = await model.importDeck(
        from: URL(fileURLWithPath: "/tmp/example.neoanki", isDirectory: true)
    )

    #expect(result?.deckIDs == [root])
    #expect(portableCalls == 0)
    #expect(authoredCalls == 1)
    #expect(model.notice?.message == "2 items imported.")
}
