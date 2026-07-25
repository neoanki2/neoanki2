import Foundation

/// Locale-aware, finite-only rendering shared by card content and item summaries.
public enum ContentNumberRendering {
    public static let invalidNumber = "Invalid number"

    public static func string(
        from number: Double,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard number.isFinite else { return invalidNumber }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 15
        return formatter.string(from: NSNumber(value: number)) ?? invalidNumber
    }
}
