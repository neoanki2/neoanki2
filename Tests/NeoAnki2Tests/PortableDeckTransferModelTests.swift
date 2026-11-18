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

private actor PortableDeckExportGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseExport: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            releaseExport = continuation
            entered = true
            let pending = entryWaiters
            entryWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() { releaseExport?.resume(); releaseExport = nil }
}

@Test @MainActor func portableDeckExportTracksBusyStateAndScopedAccess() async {
    let access = PortableDeckScopedAccessSpy()
    let destination = URL(fileURLWithPath: "/tmp/example.neodeck")
    let gate = PortableDeckExportGate()
    let model = PortableDeckTransferModel(
        scopedAccess: access,
        importOperation: { _, _ in
            throw PortableDeckError.invalidPackage("Unused")
        },
        exportOperation: { _, _ in
            await gate.hold()
        }
    )

    let task = Task { await model.exportDeck(id: UUID(), to: destination) }
    await gate.waitUntilEntered()

    #expect(model.isBusy)
    await gate.release()
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
