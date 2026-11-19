import Foundation
import NeoAnkiApplication
import NeoAnkiCore
@testable import NeoAnkiFeatures
import Observation
import Testing

@Suite @MainActor struct LibraryLifecycleTests {
    private func fixture() throws -> (URL, SQLiteLibraryRepository, HeldNativeLibraryReads, LibraryFeatureModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-lifecycle-\(UUID())")
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let reads = HeldNativeLibraryReads(base: repository)
        return (root, repository, reads, LibraryFeatureModel(library: repository,
            reads: NativeLibraryReadCoordinator(library: reads)))
    }

    @Test func cancelledRefreshDoesNotCloseAnOpenLibrary() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let readCount = await reads.readCount
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.refresh()
        }
        await refresh.value
        #expect(model.loadState == .ready)
        #expect(model.recoveryMessage == nil)
        #expect(await reads.readCount == readCount)
        #expect(!model.isRefreshing)
    }

    @Test(arguments: [false, true])
    func cancelledInFlightReadDoesNotPublishOrRepeat(fails: Bool) async throws {
        let (root, repository, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        _ = try await repository.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("New item")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]))
        let gate = await reads.arm(offsets: [1], firstFails: fails)[0]
        let refresh = Task { await model.refresh() }
        await reads.waitUntilHeld(gate)
        refresh.cancel()
        await reads.release(gate)
        await refresh.value
        #expect(model.loadState == .ready)
        #expect(model.recoveryMessage == nil)
        #expect(model.allDecksSummary.itemCount == 0, "A canceled snapshot must not be published")
        #expect(await reads.readCount == gate, "Cancellation must not repeat the read")
        #expect(!model.isRefreshing)
        // A subsequent user request can still use the read lane.
        await model.refresh()
        #expect(model.allDecksSummary.itemCount == 1)
    }

    @Test func cancelledQueuedRefreshDoesNotReadOrDisturbTheActiveRefresh() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let gate = await reads.arm(offsets: [1])[0]
        let active = Task { await model.refresh() }
        await reads.waitUntilHeld(gate)
        let queued = Task { await model.refresh() }
        while model.pendingReloadCount < 2 {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.pendingReloadCount } onChange: { continuation.resume() }
            }
        }
        queued.cancel()
        await reads.release(gate)
        await active.value
        await queued.value
        #expect(model.loadState == .ready)
        #expect(model.recoveryMessage == nil)
        #expect(await reads.readCount == gate)
        #expect(model.pendingReloadCount == 0)
        #expect(!model.isRefreshing)
    }

    @Test func refreshFailurePreservesContentAndReportsTheActualFailureWithoutRetrying() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let itemTypes = model.itemTypes
        model.section = .library
        let gate = await reads.arm(offsets: [1], firstFails: true)[0]
        let refresh = Task { await model.refresh() }
        await reads.waitUntilHeld(gate)
        await reads.release(gate)
        await refresh.value
        #expect(model.loadState == .ready)
        #expect(model.itemTypes == itemTypes)
        #expect(model.section == .library)
        #expect(model.recoveryMessage?.contains("Obsolete held home read failed") == true)
        #expect(await reads.readCount == gate)
        await model.refresh()
        #expect(model.recoveryMessage == nil)
    }

    @Test func refreshBeforeBootstrapDoesNotReadAnUninitializedDatabase() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh()
        #expect(model.loadState == .loading)
        #expect(await reads.readCount == 0)
        #expect(model.recoveryMessage == nil)
        await model.bootstrap()
        #expect(model.loadState == .ready)
    }

    @Test func reappearingSceneDoesNotReinitializeAnOpenLibrary() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let readCount = await reads.readCount
        await model.bootstrap()
        #expect(model.loadState == .ready)
        #expect(await reads.readCount == readCount)
    }

    @Test func sceneDisappearingDuringInitialReadDoesNotCancelModelOwnedStartup() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = await reads.arm(offsets: [1])[0]
        let scene = Task { await model.bootstrap() }
        await reads.waitUntilHeld(gate)
        scene.cancel()
        await reads.release(gate)
        await scene.value
        #expect(model.loadState == .ready)
        #expect(!model.itemTypes.isEmpty)
        #expect(model.recoveryMessage == nil)
        #expect(await reads.readCount == 1)
    }

    @Test func initialOpenFailureStillOffersExplicitRecovery() async throws {
        let (root, _, reads, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = await reads.arm(offsets: [1], firstFails: true)[0]
        let bootstrap = Task { await model.bootstrap() }
        await reads.waitUntilHeld(gate)
        await reads.release(gate)
        await bootstrap.value
        guard case let .failed(error) = model.loadState else {
            Issue.record("An actual initial-open failure must remain visible")
            return
        }
        #expect(error.message.contains("Obsolete held home read failed"))
        #expect(await reads.readCount == 1)
        await model.bootstrap()
        #expect(model.loadState == .ready)
    }
}
