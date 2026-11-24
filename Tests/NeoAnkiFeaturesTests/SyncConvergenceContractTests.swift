import CryptoKit
import Foundation
import NeoAnkiApplication
@testable import NeoAnkiCloudSync
import NeoAnkiCore
import NeoAnkiFeatures
import Observation
import Testing

private func contractRequire(_ condition: Bool, _ marker: String, _ detail: String) throws {
    guard condition else { throw SyncContractFailure(marker: marker, detail: detail) }
}

struct ContractStep: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case push, lostPush, foreground, beforeSend, partialAcknowledgement, failedFetch, incomingMove, outgoingMove }
    let mode: Mode
    let cardIndex: Int
    var reviewCount = 1
    var media = false
    var deleteType = false
    var legacyMetadata = false
}

struct ContractPlan: Codable, Sendable, CustomTestStringConvertible {
    var schemaVersion = 1
    let scenario: String
    let seed: UInt64
    var steps: [ContractStep]
    var failure: String?
    var completedSteps: Int?
    var testDescription: String { "\(scenario)-seed-\(seed)" }

    static func campaigns() -> [ContractPlan] {
        let env = ProcessInfo.processInfo.environment
        if let path = env["NEOANKI_SYNC_CONTRACT_REPLAY"] {
            do {
                var plan = try JSONDecoder().decode(ContractPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                plan.failure = nil
                return [plan]
            }
            catch { return [.init(scenario: "invalid-replay", seed: 0, steps: [], failure: String(describing: error))] }
        }
        let count = min(64, max(1, Int(env["NEOANKI_SYNC_CONTRACT_SEEDS"] ?? "4") ?? 4))
        let steps = min(200, max(1, Int(env["NEOANKI_SYNC_CONTRACT_STEPS"] ?? "12") ?? 12))
        let fixed: [UInt64] = [1, 7, 42, 0xc0ffee]
        let seeds: [UInt64]
        if let single = env["NEOANKI_SYNC_CONTRACT_SEED"].flatMap(UInt64.init) { seeds = [single] }
        else if let base = env["NEOANKI_SYNC_CONTRACT_SEED_BASE"].flatMap(UInt64.init) {
            seeds = (0..<count).map { base &+ UInt64($0) }
        } else { seeds = (0..<count).map { $0 < fixed.count ? fixed[$0] : UInt64($0) } }
        return seeds.map { seed in
            var random = ContractRandom(state: seed)
            let choices: [ContractStep.Mode] = [.push, .lostPush, .beforeSend, .partialAcknowledgement, .failedFetch, .incomingMove]
            let generated = (0..<steps).map { index in
                ContractStep(mode: index == 0 ? .incomingMove : choices[Int(random.next() % UInt64(choices.count))],
                    cardIndex: index * 3, reviewCount: Int(random.next() % 3) + 1, media: index == 0, deleteType: index == 0, legacyMetadata: random.next() & 1 == 0)
            }
            return ContractPlan(scenario: "generated", seed: seed, steps: generated)
        }
    }
}

private struct ContractRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    mutating func uuid() -> UUID {
        let hex = Array(String(format: "%016llx%016llx", next(), next()))
        return UUID(uuidString: [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
            String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-"))!
    }
}

/// Observe the actual UI-facing summary. No refresh calls repair the view in a
/// measured path; removing the service's library-change event must fail it.
@MainActor
private final class ContractVisibleObserver {
    private weak var model: LibraryFeatureModel?
    private let events: SyncLibraryChanges
    private var stopped = false
    init(model: LibraryFeatureModel, events: SyncLibraryChanges) {
        self.model = model; self.events = events; arm()
    }
    func stop() { stopped = true }
    private func arm() {
        guard !stopped, let model else { return }
        withObservationTracking {
            _ = model.allDecksSummary
            _ = model.isRefreshing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.arm()
                await self.events.publish()
            }
        }
    }
}

@MainActor
private final class ContractReplica {
    let name: String
    let directory: URL
    let repository: SQLiteLibraryRepository
    let metadata: SyncMetadataStore
    let transport: SyncContractTransport
    let service: OfflineFirstSyncService
    let model: LibraryFeatureModel
    private let observer: ContractVisibleObserver
    private let clock: SyncContractClock
    private var pushes: Task<Void, Never>?
    private var publications: Task<Void, Never>?
    private(set) var inboundPublications = 0

    init(name: String, directory: URL, repository: SQLiteLibraryRepository,
         cloud: SyncContractCloud, clock: SyncContractClock) {
        self.name = name; self.directory = directory; self.repository = repository; self.clock = clock
        let metadata = SyncMetadataStore(directory: directory.appendingPathComponent("sync"))
        self.metadata = metadata
        let transport = SyncContractTransport(cloud: cloud, deviceID: name, metadata: metadata)
        self.transport = transport
        let service = OfflineFirstSyncService(repository: repository,
            adapter: SQLiteLibrarySyncAdapter(repository: repository), transport: transport, metadataStore: metadata,
            timing: clock.timing(for: name), backupURL: { directory.appendingPathComponent("backup.sqlite") })
        self.service = service
        let model = LibraryFeatureModel(library: repository, syncService: service,
            settingsStore: VolatileMobileSettingsStore(syncEnabled: true))
        self.model = model
        observer = ContractVisibleObserver(model: model, events: clock.events)
    }
    func start(cloud: SyncContractCloud) async {
        let events = await service.libraryChanges()
        publications = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled, let self else { return }
                self.inboundPublications += 1
                await self.clock.events.publish()
            }
        }
        await model.bootstrap()
        let stream = await cloud.pushes(for: name)
        pushes = Task { [service] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                // Represents delivery of a push hint. Payloads still use the
                // production token reader and durable inbox, not this stream.
                await service.synchronizeAndWait()
            }
        }
    }
    func stop() async {
        observer.stop()
        publications?.cancel()
        publications = nil
        pushes?.cancel()
        await pushes?.value
        pushes = nil
        await model.setSyncEnabled(false)
    }
}

private struct ContractLedger {
    var reviews: [UUID: SynchronizedReviewRecord] = [:]
    var cards: [UUID: Card] = [:]
    var dueIDs: Set<UUID> = []
    var media: [(reference: MediaRef, bytes: Data)] = []
    var deletedType: UUID?
}

@MainActor
private final class ContractFixture {
    let root: URL
    let cloud: SyncContractCloud
    let clock: SyncContractClock
    let domainTime: Date
    let unusedType: UUID
    let originalCardIDs: Set<UUID>
    var phone: ContractReplica
    var mac: ContractReplica
    var ledger = ContractLedger()
    var completedSteps = 0

    private init(root: URL, cloud: SyncContractCloud, clock: SyncContractClock, domainTime: Date,
                 unusedType: UUID, originalCardIDs: Set<UUID>, phone: ContractReplica, mac: ContractReplica) {
        self.root = root; self.cloud = cloud; self.clock = clock; self.domainTime = domainTime
        self.unusedType = unusedType; self.originalCardIDs = originalCardIDs
        self.phone = phone; self.mac = mac
    }
    static func make(root: URL, plan: ContractPlan) async throws -> ContractFixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domainTime = Date.now
        let clock = SyncContractClock(origin: domainTime)
        let cloud = try SyncContractCloud(directory: root.appendingPathComponent("server"))
        let phonePath = root.appendingPathComponent("phone")
        try FileManager.default.createDirectory(at: phonePath, withIntermediateDirectories: true)
        let phoneRepository = try SQLiteLibraryRepository(databaseURL: phonePath.appendingPathComponent("library.sqlite"))
        try await phoneRepository.bootstrap()
        var random = ContractRandom(state: plan.seed)
        for index in 0..<(max(1, plan.steps.map { $0.cardIndex + $0.reviewCount }.max() ?? 1) + 1) {
            let item = Item(id: random.uuid(), itemTypeID: BuiltInItemTypes.basicID, fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Contract prompt \(index)")),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Contract answer \(index)")),
            ])
            _ = try await phoneRepository.createItem(item, asOf: domainTime.addingTimeInterval(-60))
        }
        let unused = try ItemTypeBuilder.makeItemType(name: "Unused contract type", fields: [
            FieldDef(name: "Prompt", type: .text, isRequired: true),
            FieldDef(name: "Answer", type: .text, isRequired: true),
        ])
        _ = try await phoneRepository.createItemType(unused)
        let phone = ContractReplica(name: "phone", directory: phonePath, repository: phoneRepository, cloud: cloud, clock: clock)
        await phone.start(cloud: cloud)
        let macPath = root.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: macPath, withIntermediateDirectories: true)
        let macRepository = try SQLiteLibraryRepository(databaseURL: macPath.appendingPathComponent("library.sqlite"))
        let mac = ContractReplica(name: "mac", directory: macPath, repository: macRepository, cloud: cloud, clock: clock)
        await mac.start(cloud: cloud)
        // Setup only. Measured edits below never invoke synchronization/refresh.
        await phone.service.synchronizeAndWait()
        await mac.service.synchronizeAndWait()
        _ = try await clock.pollRequest(deviceID: "phone")
        _ = try await clock.pollRequest(deviceID: "mac")
        let cards = try await phoneRepository.cards()
        let fixture = ContractFixture(root: root, cloud: cloud, clock: clock, domainTime: domainTime,
            unusedType: unused.id, originalCardIDs: Set(cards.map(\.id)), phone: phone, mac: mac)
        fixture.ledger.cards = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        fixture.ledger.dueIDs = Set(cards.map(\.id))
        try contractRequire(mac.model.allDecksSummary.dueNow == cards.count, "SYNC_CONTRACT_SETUP", "Initial visible summary did not load")
        return fixture
    }
    func close() async { await phone.stop(); await mac.stop() }

    func move(_ device: ContractReplica, legacy: Bool) async throws -> ContractReplica {
        await device.stop()
        if legacy {
            // Encode the previous installation's absolute URLs as old releases
            // did. Never rebase them in the fixture: production load must do it.
            let old = try await device.metadata.load()
            try PropertyListEncoder().encode(old).write(to: device.directory.appendingPathComponent("sync/cloud-sync-metadata.plist"))
        }
        let moved = root.appendingPathComponent("\(device.name)-update-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: device.directory, to: moved)
        let repository = try SQLiteLibraryRepository(databaseURL: moved.appendingPathComponent("library.sqlite"))
        let reopened = ContractReplica(name: device.name, directory: moved, repository: repository, cloud: cloud, clock: clock)
        await reopened.start(cloud: cloud)
        return reopened
    }

    func run(_ step: ContractStep) async throws {
        let controlledPush = step.mode != .push
        let baselinePublications = mac.inboundPublications
        await cloud.setPushesEnabled(!controlledPush, for: "mac")
        if step.mode == .beforeSend || step.mode == .outgoingMove { await phone.transport.inject(.beforeSend) }
        if step.mode == .partialAcknowledgement { await phone.transport.inject(.afterPartialSend) }
        let cards = ledger.cards.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let inactiveFetches = await mac.transport.fetchCount()
        if step.mode == .foreground { await mac.service.setForeground(false) }
        if step.mode == .incomingMove {
            // The receiver is suspended while this mixed batch reaches cloud.
            // A lifecycle start below stages it before reconstructing the app.
            await mac.service.stop()
        }
        if step.deleteType {
            _ = try await phone.repository.deleteItemType(id: unusedType)
            ledger.deletedType = unusedType
        }
        if step.media {
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            let asset = try await phone.repository.reserveMedia(data: bytes, kind: .image, altText: "Contract PNG", asOf: domainTime)
            ledger.media.append((asset.reference, bytes))
        }
        for index in step.cardIndex..<(step.cardIndex + step.reviewCount) {
            let card = cards[index]
            let review = try await phone.repository.submitReview(cardID: card.id, rating: .easy,
                asOf: domainTime, durationMilliseconds: completedSteps + 1)
            ledger.reviews[review.reviewLogID] = try await phone.repository.synchronizedReviewRecord(id: review.reviewLogID)
            ledger.dueIDs.remove(card.id)
        }
        let expectedCards = try await phone.repository.cards()
        ledger.cards = Dictionary(uniqueKeysWithValues: expectedCards.map { ($0.id, $0) })
        let sourceDue = Set(try await phone.repository.dueCards(scope: .allDecks, asOf: domainTime).map(\.id))
        try contractRequire(sourceDue == ledger.dueIDs, "SYNC_CONTRACT_LEDGER", "Source does not match independent easy-review due-set ledger")
        let cursor = try await phone.repository.currentChangeCursor()
        let debounce = try await clock.localRequest(deviceID: "phone")
        try contractRequire(debounce.duration == .milliseconds(250), "SYNC_CONTRACT_DEBOUNCE", "Committed change must register the 250ms upload window")
        clock.advance(to: debounce.deadline)
        try await waitForSender(cursor: cursor, acceptsInjectedFailure: step.mode == .beforeSend
            || step.mode == .partialAcknowledgement || step.mode == .outgoingMove)

        if step.mode == .outgoingMove {
            let queued = try await phone.metadata.load().pendingOutbound ?? []
            try contractRequire(queued.contains { $0.asset != nil }, "SYNC_CONTRACT_OUTBOUND_RELOCATION", "No image queued before moving sender")
            for media in ledger.media {
                try contractRequire(try await cloud.assetData(id: media.reference.assetHash) == nil,
                    "SYNC_CONTRACT_OUTBOUND_RELOCATION", "Server already owns media, so this case would not test reopening queued bytes")
            }
            phone = try await move(phone, legacy: step.legacyMetadata)
        } else if !(try await phone.metadata.load().pendingOutbound ?? []).isEmpty {
            let poll = try await clock.pollRequest(deviceID: "phone")
            try contractRequire(poll.deadline - clock.elapsed() <= .seconds(3), "SYNC_CONTRACT_RECOVERY", "Sender recovery exceeds poll budget")
            clock.advance(to: poll.deadline)
            try await waitForSender(cursor: cursor, acceptsInjectedFailure: false)
        }

        if step.mode == .incomingMove {
            await mac.transport.inject(.afterFetchStaged)
            await mac.service.start()
            let metadata = try await mac.metadata.load()
            try contractRequire(!metadata.stagedInbound.isEmpty, "SYNC_CONTRACT_ASSET_RELOCATION", "No durable inbox staged before moving receiver")
            try contractRequire(try await cloud.activeLeaseCount() == 0, "SYNC_CONTRACT_ASSET_RELOCATION", "Transient downloads must already be expired")
            mac = try await move(mac, legacy: step.legacyMetadata)
        } else if step.mode == .lostPush || step.mode == .failedFetch {
            if step.mode == .failedFetch {
                await mac.transport.inject(.fetch)
                let beforeFetch = clock.completed("mac")
                await cloud.deliverPush(to: "mac")
                try await clock.waitForCompletion(deviceID: "mac", after: beforeFetch)
            }
            let poll = try await clock.pollRequest(deviceID: "mac")
            try contractRequire(poll.duration == .seconds(3), "SYNC_CONTRACT_POLL_DEADLINE", "Recovery poll interval changed")
            let beforeFetch = await mac.transport.fetchCount()
            clock.advance(to: poll.deadline - .milliseconds(1))
            try contractRequire(await mac.transport.fetchCount() == beforeFetch, "SYNC_CONTRACT_POLL_DEADLINE", "Receiver fetched before its recovery timer")
            clock.advance(by: .milliseconds(1))
        } else if step.mode == .foreground {
            clock.advance(by: .seconds(3))
            try contractRequire(!clock.hasPoll(deviceID: "mac"), "SYNC_CONTRACT_FOREGROUND", "Inactive receiver retained a recovery timer")
            try contractRequire(await mac.transport.fetchCount() == inactiveFetches, "SYNC_CONTRACT_FOREGROUND", "Inactive receiver fetched without a push")
            await mac.service.setForeground(true)
        } else if controlledPush {
            await cloud.deliverPush(to: "mac")
        }
        try await waitForReceiver()
        if step.mode == .push || step.mode == .foreground {
            try await syncContractWatch("SYNC_CONTRACT_VISIBLE") { @MainActor in
                let events = await self.clock.events.stream()
                var observer = events.makeAsyncIterator()
                while !Task.isCancelled {
                    if self.mac.inboundPublications > baselinePublications { return }
                    guard await observer.next() != nil else { break }
                }
                throw CancellationError()
            }
        }
        try await verifyLedger()
        await cloud.setPushesEnabled(true, for: "mac")
        completedSteps += 1
    }

    private func waitForSender(cursor: Int64, acceptsInjectedFailure: Bool) async throws {
        try await syncContractWatch("SYNC_CONTRACT_AUTOMATIC_SEND") { @MainActor in
            let stream = await self.clock.events.stream()
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled {
                let metadata = try await self.phone.metadata.load()
                let pending = !(metadata.pendingOutbound ?? []).isEmpty
                let status = await self.phone.service.status()
                if metadata.outboundCursor >= cursor {
                    if case .current = status, !pending { return }
                    if acceptsInjectedFailure, case .offline = status, pending { return }
                }
                let issues = await self.phone.service.issues()
                if !issues.isEmpty {
                    throw SyncContractFailure(marker: "SYNC_CONTRACT_DATA", detail: issues.map(\.summary).joined(separator: "; "))
                }
                guard await iterator.next() != nil else { break }
            }
            throw CancellationError()
        }
    }

    private func waitForReceiver() async throws {
        try await syncContractWatch("SYNC_CONTRACT_VISIBLE") { @MainActor in
            let stream = await self.clock.events.stream()
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled {
                let issues = await self.mac.service.issues()
                if !issues.isEmpty {
                    throw SyncContractFailure(marker: "SYNC_CONTRACT_DATA", detail: issues.map(\.summary).joined(separator: "; "))
                }
                var arrived = true
                for id in self.ledger.reviews.keys {
                    if (try? await self.mac.repository.synchronizedReviewRecord(id: id)) == nil { arrived = false; break }
                }
                let metadata = try await self.mac.metadata.load()
                let sender = try await self.phone.metadata.load()
                if arrived, self.mac.model.allDecksSummary.dueNow == self.ledger.dueIDs.count,
                   !self.mac.model.isRefreshing,
                   metadata.stagedInbound.isEmpty, (metadata.pendingOutbound ?? []).isEmpty,
                   sender.stagedInbound.isEmpty, (sender.pendingOutbound ?? []).isEmpty,
                   case .current = await self.mac.service.status(),
                   case .current = await self.phone.service.status() { return }
                guard await iterator.next() != nil else { break }
            }
            throw CancellationError()
        }
    }

    private func verifyLedger() async throws {
        for device in [phone, mac] {
            let marker = "SYNC_CONTRACT_DATA"
            let actual = try await device.repository.cards()
            try contractRequire(Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) }) == ledger.cards,
                marker, "\(device.name): card memory/suspension/deck state differs from pre-transport writer state")
            let due = Set(try await device.repository.dueCards(scope: .allDecks, asOf: domainTime).map(\.id))
            try contractRequire(due == ledger.dueIDs, marker, "\(device.name): due card identities differ")
            let revisions = try await device.repository.resourceRevisionSnapshot()
            try contractRequire(revisions.filter { $0.resourceType == "review" && !$0.isDeleted }.count == ledger.reviews.count,
                marker, "\(device.name): lost or fabricated review identity")
            for (id, expected) in ledger.reviews {
                try contractRequire(try await device.repository.synchronizedReviewRecord(id: id) == expected,
                    marker, "\(device.name): immutable review changed or disappeared")
            }
            if let deleted = ledger.deletedType {
                try contractRequire(try await device.repository.loadItemTypes().itemTypes.allSatisfy { $0.id != deleted }, marker, "Deleted item type survived")
            }
            for media in ledger.media {
                let expectedHash = SHA256.hash(data: media.bytes).map { String(format: "%02x", $0) }.joined()
                try contractRequire(media.reference.assetHash == expectedHash, marker, "Independent media hash differs")
                try contractRequire(try await cloud.assetData(id: expectedHash) == media.bytes, marker, "Cloud did not own exact source bytes")
                guard let store = await device.repository.mediaStore() else { throw SyncContractFailure(marker: marker, detail: "Missing MediaStore") }
                let url = try await store.resolve(media.reference)
                try contractRequire(try Data(contentsOf: url) == media.bytes, marker, "\(device.name): destination image bytes changed")
            }
            let metadata = try await device.metadata.load()
            try contractRequire(metadata.stagedInbound.isEmpty && (metadata.pendingOutbound ?? []).isEmpty && metadata.issues.isEmpty,
                marker, "\(device.name): completed convergence retained work/issues")
        }
        try contractRequire(try await cloud.activeLeaseCount() == 0, "SYNC_CONTRACT_DATA", "Transport download lease leaked")
    }
}

@MainActor
private func runContract(_ plan: ContractPlan) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-contract-\(UUID().uuidString)")
    var fixture: ContractFixture?
    do {
        if let failure = plan.failure { throw SyncContractFailure(marker: "SYNC_CONTRACT_REPLAY", detail: failure) }
        try contractRequire(plan.schemaVersion == 1 && (1...200).contains(plan.steps.count)
            && plan.steps.allSatisfy { $0.cardIndex >= 0 && (1...3).contains($0.reviewCount)
                && $0.cardIndex <= 600 - $0.reviewCount },
            "SYNC_CONTRACT_REPLAY", "Trace must contain 1...200 steps, 1...3 reviews per step, and card indices within 0..<600")
        let created = try await ContractFixture.make(root: root, plan: plan)
        fixture = created
        for step in plan.steps { try await created.run(step) }
        await created.close()
        try FileManager.default.removeItem(at: root)
    } catch {
        if let fixture { await fixture.close() }
        var failed = plan; failed.failure = String(describing: error); failed.completedSteps = fixture?.completedSteps
        let output = ProcessInfo.processInfo.environment["NEOANKI_SYNC_CONTRACT_ARTIFACTS"]
            .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/sync-contract-artifacts")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let artifact = output.appendingPathComponent("contract-\(plan.seed)-\(UUID().uuidString).json")
        try JSONEncoder().encode(failed).write(to: artifact, options: .atomic)
        try? FileManager.default.removeItem(at: root)
        throw SyncContractFailure(marker: "SYNC_CONTRACT_FAILURE", detail: "seed=\(plan.seed) replay=\(artifact.path) \(error)")
    }
}

@Suite(.serialized)
@MainActor
struct SyncConvergenceContractTests {
    @Test func automaticReviewUpdatesVisibleSummaryWithoutRecoveryPoll() async throws {
        try await runContract(.init(scenario: "automatic-visible", seed: 1,
            steps: [.init(mode: .push, cardIndex: 0)]))
    }
    @Test func lostPushRecoversAtNextPollDeadline() async throws {
        try await runContract(.init(scenario: "lost-push", seed: 7,
            steps: [.init(mode: .lostPush, cardIndex: 0)]))
    }
    @Test func foregroundCatchesUpWithoutWaitingForTheNextPoll() async throws {
        try await runContract(.init(scenario: "foreground", seed: 2,
            steps: [.init(mode: .foreground, cardIndex: 0)]))
    }
    @Test(arguments: [false, true])
    func relocatedMixedBatchPreservesReviewsAndMedia(legacyMetadata: Bool) async throws {
        try await runContract(.init(scenario: "incoming-move", seed: 42,
            steps: [.init(mode: .incomingMove, cardIndex: 0, media: true, deleteType: true, legacyMetadata: legacyMetadata)]))
    }
    @Test(arguments: [false, true])
    func outboundQueueSurvivesRelocationBeforeUpload(legacyMetadata: Bool) async throws {
        try await runContract(.init(scenario: "outgoing-move", seed: 99,
            steps: [.init(mode: .outgoingMove, cardIndex: 0, media: true, legacyMetadata: legacyMetadata)]))
    }
    @Test(arguments: ContractPlan.campaigns())
    func generatedFaultCampaign(plan: ContractPlan) async throws { try await runContract(plan) }
}
