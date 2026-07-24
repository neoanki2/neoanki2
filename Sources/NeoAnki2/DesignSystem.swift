import SwiftUI

enum DesignSystem {
    // MARK: - Accent (Study Indigo — only custom hex in the app)

    static let accentLight = Color(red: 0.29, green: 0.44, blue: 0.65) // #4A6FA5
    static let accentDark = Color(red: 0.48, green: 0.64, blue: 0.85) // #7BA4D9

    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? accentDark : accentLight
    }

    // MARK: - Surfaces

    static var sidebarBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var detailBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var errorBannerBackground: Color { Color(nsColor: .systemRed).opacity(0.12) }

    // MARK: - Layout

    static let readingColumnMaxWidth: CGFloat = 600
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 260
    static let sidebarMax: CGFloat = 340

    // MARK: - Spacing (8pt grid)

    enum Spacing {
        static let rowTight: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let studyHorizontal: CGFloat = 20
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - Motion

    static let revealDuration: Double = 0.2
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignSystem.errorBannerBackground)
            .accessibilityLabel("Error, \(message)")
    }
}

// MARK: - Reveal Animation Helper

enum StudyAnimation {
    static func revealAnswer(reduceMotion: Bool, action: () -> Void) {
        if reduceMotion {
            action()
        } else {
            withAnimation(.easeOut(duration: DesignSystem.revealDuration)) {
                action()
            }
        }
    }
}

// MARK: - Reading Column Layout

private struct ReadingColumnLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: DesignSystem.readingColumnMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.vertical, DesignSystem.Spacing.lg)
    }
}

extension View {
    func readingColumnLayout() -> some View {
        modifier(ReadingColumnLayout())
    }
}
