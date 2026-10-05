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
final class BGAppRefreshTaskRequest {
    var earliestBeginDate: Date?
    init(identifier: String) {}
}

@MainActor final class BGTaskScheduler {
    static let shared = BGTaskScheduler()
    private var queue: DispatchQueue?
    private var handler: (@convention(block) (BGTask) -> Void)?
    func register(forTaskWithIdentifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping @convention(block) (BGTask) -> Void) -> Bool {
        self.queue = queue
        handler = launchHandler
        return true
    }
    func submit(_ request: BGAppRefreshTaskRequest) throws {}
    func deliver(_ task: BGTask) async {
        let handler = handler!
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
    var syncEnabled = true
    var refreshCount = 0
    var syncCount = 0
    var holdRefresh = false
    var refreshContinuation: CheckedContinuation<Void, Never>?
    func refresh() async {
        refreshCount += 1
        if holdRefresh {
            await withCheckedContinuation { refreshContinuation = $0 }
        }
    }
    func synchronize() async { syncCount += 1 }
}
"""

HARNESS = r"""
@main struct Regression {
    @MainActor static func main() async throws {
        let expires = CommandLine.arguments.contains("expire")
        let model = LibraryFeatureModel()
        model.holdRefresh = expires
        IOSBackgroundRefresh.shared.register(model: model)
        let task = BGAppRefreshTask()
        await BGTaskScheduler.shared.deliver(task)
        if expires {
            for _ in 0..<1_000 {
                if model.refreshContinuation != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let continuation = model.refreshContinuation,
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
            if !task.completions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(model.refreshCount == 1)
        precondition(model.syncCount == (expires ? 0 : 1))
        precondition(task.completions == [!expires])
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

    def test_scheduler_launch_respects_main_actor(self):
        self.run_scenario()

    def test_background_expiration_cancels_before_sync(self):
        self.run_scenario("expire")


if __name__ == "__main__":
    unittest.main()
