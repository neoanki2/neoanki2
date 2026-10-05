import NeoAnkiApplication
import SwiftUI

private struct NeoAnkiAccessibilityReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

public extension EnvironmentValues {
    /// Isolated UI tests can exercise motion-sensitive paths without relying
    /// on undocumented SwiftUI keys. Production leaves this nil and follows
    /// the user's system Reduce Motion preference.
    var neoAnkiAccessibilityReduceMotionOverride: Bool? {
        get { self[NeoAnkiAccessibilityReduceMotionOverrideKey.self] }
        set { self[NeoAnkiAccessibilityReduceMotionOverrideKey.self] = newValue }
    }
}

/// Cross-platform semantic tokens. It intentionally uses system colors and
/// text styles so Dynamic Type, contrast, and platform appearance remain native.
public enum SharedDesignSystem {
    public static let readingColumnMax: CGFloat = 600
    public static let minimumTouchTarget: CGFloat = 44
    public static let compactSpacing: CGFloat = 8
    public static let standardSpacing: CGFloat = 16
    public static let sectionSpacing: CGFloat = 24

    public static var accent: Color { .accentColor }

    /// One blue hue with enough contrast for action text in both appearances.
    public static func mobileTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.40, green: 0.65, blue: 1)
            : Color(red: 0.12, green: 0.38, blue: 0.72)
    }
    public static var surface: Color { Color.primary.opacity(0.045) }
    public static var separator: Color { Color.primary.opacity(0.12) }
}

public struct AdaptiveReadingColumn<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: SharedDesignSystem.readingColumnMax)
            .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 24)
            .frame(maxWidth: .infinity)
    }
}

public extension View {
    /// Filled mobile actions keep white labels legible in either appearance.
    @ViewBuilder
    func neoAnkiMobilePrimaryActionTint() -> some View {
        #if os(iOS)
        tint(Color(red: 0.12, green: 0.38, blue: 0.72))
        #else
        self
        #endif
    }

    func neoAnkiTouchTarget() -> some View {
        frame(
            minWidth: SharedDesignSystem.minimumTouchTarget,
            minHeight: SharedDesignSystem.minimumTouchTarget
        )
        .contentShape(Rectangle())
    }
}
