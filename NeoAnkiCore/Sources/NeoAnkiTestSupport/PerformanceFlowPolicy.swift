import Foundation

/// Policy helpers for opt-in performance suites.
public enum PerformanceFlowPolicy {
    public static var allowsSlowScales: Bool {
        ProcessInfo.processInfo.environment["NEOANKI_PERF_ALLOW_SLOW"] == "1"
    }

    public static func isEnabled(flow: String?, scale: PerformanceScale) -> Bool {
        guard scale == .large || scale == .stress else { return true }
        guard allowsSlowScales else { return false }
        _ = flow
        return true
    }
}
