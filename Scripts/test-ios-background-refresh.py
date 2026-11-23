#!/usr/bin/env python3
"""Exercise the production refresh callbacks with Swift 6 executor checking.

BackgroundTasks is unavailable on macOS, so lightweight stand-ins deliver its
callbacks on dispatch queues. Compile the actual iOS coordinator unchanged;
this catches inherited actor isolation in both launch and expiration handlers.
No app, Simulator, or physical device is launched.
"""

from pathlib import Path
import resource
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
STAND_INS = r"""
import Foundation

final class Callback: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

class BGTask: NSObject, @unchecked Sendable {
    var expirationHandler: (@convention(block) () -> Void)?
    private let lock = NSLock()
    private var results: [Bool] = []
    func setTaskCompleted(success: Bool) {
        lock.withLock { results.append(success) }
    }
    var completions: [Bool] { lock.withLock { results } }
}
final class BGAppRefreshTask: BGTask, @unchecked Sendable {}
final class BGProcessingTask: BGTask, @unchecked Sendable {}
class BGTaskRequest {
    let identifier: String
    var earliestBeginDate: Date?
    init(identifier: String) { self.identifier = identifier }
}
final class BGAppRefreshTaskRequest: BGTaskRequest {}
final class BGProcessingTaskRequest: BGTaskRequest { var requiresNetworkConnectivity = false }

@MainActor final class BGTaskScheduler {
    static let shared = BGTaskScheduler()
    private var registrations: [String: (queue: DispatchQueue?, handler: (BGTask) -> Void)] = [:]
    private(set) var requests: [BGTaskRequest] = []
    func register(forTaskWithIdentifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping @convention(block) (BGTask) -> Void) -> Bool {
        registrations[forTaskWithIdentifier] = (queue, launchHandler)
        return true
    }
    func submit(_ request: BGTaskRequest) throws { requests.append(request) }
    func deliver(_ task: BGTask, identifier: String) async {
        let (queue, handler) = registrations[identifier]!
        let callback = Callback { handler(task) }
        await withCheckedContinuation { continuation in
            (queue ?? DispatchQueue(label: "com.apple.BGTaskScheduler.test")).async {
                callback.body()
                continuation.resume()
            }
        }
    }
}

@MainActor final class LibraryFeatureModel {
    enum LoadState { case loading, ready, failed }
    enum SyncStatus { case syncing, current }
    var loadState = LoadState.loading
    var syncStatus = SyncStatus.current
    var failBootstrap = false
    var bootstrapCount = 0
    var syncEnabled = true
    var refreshCount = 0
    var syncCount = 0
    var holdBootstrap = false
    var holdSync = false
    var continuation: CheckedContinuation<Void, Never>?
    var finishedCanceledSync = false
    func bootstrap(startSync: Bool? = nil) async {
        precondition(startSync == false, "The background task must own its sync lifetime")
        bootstrapCount += 1
        loadState = failBootstrap ? .failed : .ready
        if holdBootstrap { await withCheckedContinuation { continuation = $0 } }
    }
    func refresh() async {
        precondition(loadState == .ready, "Background refresh must initialize the library first")
        refreshCount += 1
    }
    func synchronize() async {
        precondition(loadState == .ready, "Background sync must initialize the library first")
        syncCount += 1
        if holdSync { await withCheckedContinuation { continuation = $0 } }
        finishedCanceledSync = Task.isCancelled
    }
}
"""

HARNESS = r"""
@main struct Regression {
    @MainActor static func main() async throws {
        let expires = CommandLine.arguments.contains("expire")
        let fails = CommandLine.arguments.contains("fail-startup")
        let processing = CommandLine.arguments.contains("processing")
        let disabled = CommandLine.arguments.contains("disabled")
        let model = LibraryFeatureModel()
        model.failBootstrap = fails
        model.holdBootstrap = expires && !processing
        model.holdSync = expires && processing
        model.syncEnabled = !disabled
        IOSBackgroundRefresh.shared.register(model: model)
        let scheduler = BGTaskScheduler.shared
        let task: BGTask = processing ? BGProcessingTask() : BGAppRefreshTask()
        let identifier = processing ? "com.neoanki2.ios.library-processing" : "com.neoanki2.ios.refresh"
        await scheduler.deliver(task, identifier: identifier)
        if expires {
            for _ in 0..<1_000 {
                if model.continuation != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let continuation = model.continuation,
                  let expiration = task.expirationHandler else {
                fatalError("Refresh did not start or expiration was not installed")
            }
            let callback = Callback(expiration)
            await withCheckedContinuation { expired in
                DispatchQueue.global().async {
                    callback.body()
                    expired.resume()
                }
            }
            continuation.resume()
        }
        for _ in 0..<1_000 {
            let rescheduled = scheduler.requests.contains { $0 is BGProcessingTaskRequest }
            if !task.completions.isEmpty, !model.holdSync || (model.finishedCanceledSync && rescheduled) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(model.bootstrapCount == 1)
        precondition(model.refreshCount == (!expires && !fails && disabled && !processing ? 1 : 0))
        precondition(model.syncCount == (!fails && !disabled && !model.holdBootstrap ? 1 : 0))
        precondition(model.finishedCanceledSync == model.holdSync)
        precondition(task.completions == [!expires && !fails])
        let requests = scheduler.requests.compactMap { $0 as? BGProcessingTaskRequest }
        precondition(requests.count == (!disabled && ((!processing && !fails && !expires) || model.holdSync) ? 1 : 0))
        precondition(requests.allSatisfy { $0.identifier == "com.neoanki2.ios.library-processing"
            && $0.requiresNetworkConnectivity })
        print(expires ? "expired refresh completed unsuccessfully" : "refresh and sync completed")
    }
}
"""


def disable_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class BackgroundRefreshRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="neoanki-background-refresh-")
        cls.addClassCleanup(cls.directory.cleanup)
        folder = Path(cls.directory.name)
        source = (ROOT / "Platforms/iOS/IOSPlatformServices.swift").read_text()
        coordinator = source[source.index("@MainActor final class IOSBackgroundRefresh") :]
        swift = folder / "Regression.swift"
        swift.write_text(STAND_INS + coordinator + HARNESS)
        cls.binary = folder / "Regression"
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True,
        ).strip()
        result = subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-O",
             "-Xfrontend", "-enable-actor-data-race-checks",
             "-sdk", sdk, str(swift), "-o", str(cls.binary)],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_scenario(self, *args):
        result = subprocess.run(
            [str(self.binary), *args], capture_output=True, text=True, timeout=10,
            preexec_fn=disable_core_dump,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cold_background_launch_opens_library_on_main_actor(self):
        self.run_scenario()

    def test_background_expiration_cancels_before_sync(self):
        self.run_scenario("expire")

    def test_initial_open_failure_does_not_start_refresh_or_sync(self):
        self.run_scenario("fail-startup")

    def test_refresh_still_updates_local_state_when_sync_is_disabled(self):
        self.run_scenario("disabled")

    def test_media_processing_wakes_a_cold_app(self):
        self.run_scenario("processing")

    def test_expired_media_processing_requeues_the_background_task(self):
        self.run_scenario("processing", "expire")


if __name__ == "__main__":
    unittest.main()
