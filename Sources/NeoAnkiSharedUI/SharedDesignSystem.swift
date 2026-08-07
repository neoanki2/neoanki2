import NeoAnkiApplication
import SwiftUI

/// Cross-platform semantic tokens. It intentionally uses system colors and
/// text styles so Dynamic Type, contrast, and platform appearance remain native.
public enum SharedDesignSystem {
    public static let readingColumnMax: CGFloat = 600
    public static let minimumTouchTarget: CGFloat = 44
    public static let compactSpacing: CGFloat = 8
    public static let standardSpacing: CGFloat = 16
    public static let sectionSpacing: CGFloat = 24

    public static var accent: Color { .accentColor }
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
    func neoAnkiTouchTarget() -> some View {
        frame(
            minWidth: SharedDesignSystem.minimumTouchTarget,
            minHeight: SharedDesignSystem.minimumTouchTarget
        )
        .contentShape(Rectangle())
    }
}
