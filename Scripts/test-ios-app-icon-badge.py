#!/usr/bin/env python3
"""Run the production iOS badge adapter headlessly with notification stand-ins."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
STAND_INS = r"""
import Foundation

enum UNAuthorizationStatus: Sendable { case notDetermined, authorized, denied }
struct UNNotificationSettings: Sendable { let authorizationStatus: UNAuthorizationStatus }
struct UNAuthorizationOptions: OptionSet, Sendable {
    let rawValue: Int
    static let badge = Self(rawValue: 1)
    static let alert = Self(rawValue: 2)
    static let sound = Self(rawValue: 4)
}
enum TestError: Error { case unavailable }
actor UNUserNotificationCenter {
    static let shared = UNUserNotificationCenter()
    nonisolated static func current() -> UNUserNotificationCenter { shared }
    var status: UNAuthorizationStatus = .notDetermined
    var requests: [UNAuthorizationOptions] = []
    var counts: [Int] = []
    var failAuthorization = false
    var failWrite = false
    var holdWrite = false
    var writeContinuation: CheckedContinuation<Void, Never>?
    func configure(status: UNAuthorizationStatus, failAuthorization: Bool = false,
                   failWrite: Bool = false, holdWrite: Bool = false) {
        self.status = status
        self.failAuthorization = failAuthorization
        self.failWrite = failWrite
        self.holdWrite = holdWrite
    }
    func notificationSettings() async -> UNNotificationSettings {
        .init(authorizationStatus: status)
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requests.append(options)
        if failAuthorization { throw TestError.unavailable }
        return status != .denied
    }
    func setBadgeCount(_ count: Int) async throws {
        if failWrite { throw TestError.unavailable }
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation { writeContinuation = $0 }
        }
        counts.append(count)
    }
    func releaseWrite() { writeContinuation?.resume(); writeContinuation = nil }
}
"""
HARNESS = r"""
@main struct Regression {
    static func main() async throws {
        let center = UNUserNotificationCenter.current()
        let publisher = IOSAppIconBadgePublisher()
        switch CommandLine.arguments[1] {
        case "counts":
            // Existing alert/sound authorization must still request badges.
            await center.configure(status: .authorized)
            try await publisher.publish(AppIconBadge(dueCount: 0))
            let initialRequests = await center.requests
            precondition(initialRequests.isEmpty)
            try await publisher.publish(AppIconBadge(dueCount: 12_345))
            try await publisher.publish(AppIconBadge(dueCount: 1))
            try await publisher.publish(AppIconBadge(dueCount: -1))
            let requests = await center.requests
            let counts = await center.counts
            precondition(requests == [.badge])
            precondition(counts == [0, 12_345, 1, 0])
        case "denied":
            await center.configure(status: .denied)
            try await publisher.publish(AppIconBadge(dueCount: 2))
            let requests = await center.requests
            let counts = await center.counts
            precondition(requests.isEmpty && counts.isEmpty)
            // A later change in Settings must recover without restarting.
            await center.configure(status: .authorized)
            try await publisher.publish(AppIconBadge(dueCount: 2))
            let recovered = await center.counts
            precondition(recovered == [2])
        case "retry":
            await center.configure(status: .authorized, failAuthorization: true)
            do {
                try await publisher.publish(AppIconBadge(dueCount: 2))
                fatalError("Expected authorization failure")
            } catch TestError.unavailable {}
            await center.configure(status: .authorized, failWrite: true)
            do {
                try await publisher.publish(AppIconBadge(dueCount: 2))
                fatalError("Expected badge write failure")
            } catch TestError.unavailable {}
            await center.configure(status: .authorized)
            try await publisher.publish(AppIconBadge(dueCount: 3))
            let counts = await center.counts
            precondition(counts == [3])
        case "ordering":
            await center.configure(status: .authorized, holdWrite: true)
            let first = Task { try await publisher.publish(AppIconBadge(dueCount: 5)) }
            for _ in 0..<1_000 {
                if await center.writeContinuation != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let held = await center.writeContinuation != nil
            precondition(held)
            let second = Task { try await publisher.publish(AppIconBadge(dueCount: 0)) }
            // Give the newer call time to reach its await while the first is held.
            try await Task.sleep(for: .milliseconds(20))
            await center.releaseWrite()
            try await first.value
            try await second.value
            let counts = await center.counts
            precondition(counts == [5, 0])
        default: fatalError("Unknown scenario")
        }
    }
}
"""


class AppIconBadgeRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="neoanki-ios-badge-")
        cls.addClassCleanup(cls.directory.cleanup)
        folder = Path(cls.directory.name)
        source = (ROOT / "Platforms/iOS/IOSPlatformServices.swift").read_text()
        start = source.index("actor IOSAppIconBadgePublisher:")
        end = source.index("actor AppGroupWidgetPublisher:", start)
        policy = (ROOT / "Sources/NeoAnkiApplication/AppIconBadge.swift").read_text()
        swift = folder / "Regression.swift"
        swift.write_text(STAND_INS + policy + source[start:end] + HARNESS)
        cls.binary = folder / "Regression"
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True,
        ).strip()
        result = subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
             "-sdk", sdk, str(swift), "-o", str(cls.binary)],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_scenario(self, scenario):
        result = subprocess.run(
            [str(self.binary), scenario], capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_count_permission_and_clearing(self):
        self.run_scenario("counts")

    def test_permission_denial_and_settings_recovery(self):
        self.run_scenario("denied")

    def test_failed_authorization_and_writes_can_retry(self):
        self.run_scenario("retry")

    def test_overlapping_refreshes_cannot_restore_stale_count(self):
        self.run_scenario("ordering")


if __name__ == "__main__":
    unittest.main()
