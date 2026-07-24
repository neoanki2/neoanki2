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

    // MARK: - Card content

    /// Rich-text `.highlight` spans on the study stage — system find-highlight, adapts to Light/Dark/Increased Contrast.
    static var contentHighlightBackground: Color { Color(nsColor: .findHighlightColor) }

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

    // MARK: - Typography
    //
    // Semantic styles bumped one step above the baseline in DESIGN.md for better
    // desk-distance readability while preserving hierarchy and Dynamic Type support.

    enum Typography {
        static let cardPrompt = Font.largeTitle
        static let cardAnswer = Font.title
        static let cardSecondary = Font.title2

        static let uiTitle = Font.title2.weight(.semibold)
        static let uiSection = Font.title3.weight(.semibold)
        static let uiBody = Font.body
        static let uiSecondary = Font.callout
        static let uiCaption = Font.subheadline
        static let uiHint = Font.subheadline

        static let emptyIcon = Font.system(.largeTitle, design: .default, weight: .light)
        static let emptyTitle = Font.body.weight(.semibold)
        static let emptyMessage = Font.subheadline

        static var richTextPointSize: CGFloat {
            NSFont.preferredFont(forTextStyle: .body).pointSize
        }

        static var cardPromptPointSize: CGFloat {
            NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
        }

        static var cardAnswerPointSize: CGFloat {
            NSFont.preferredFont(forTextStyle: .title1).pointSize
        }

        static var cardSecondaryPointSize: CGFloat {
            NSFont.preferredFont(forTextStyle: .title2).pointSize
        }

        static var richTextFont: NSFont {
            NSFont.systemFont(ofSize: richTextPointSize)
        }
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(DesignSystem.Typography.uiCaption)
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

    func neoAnkiFormTypography() -> some View {
        font(DesignSystem.Typography.uiBody)
    }
}

// MARK: - Sidebar Empty State

struct SidebarEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?
    var actionIdentifier: String?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Spacer(minLength: DesignSystem.Spacing.xl)

            Image(systemName: systemImage)
                .font(DesignSystem.Typography.emptyIcon)
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(spacing: DesignSystem.Spacing.rowTight) {
                Text(title)
                    .font(DesignSystem.Typography.emptyTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(DesignSystem.Typography.emptyMessage)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(message)")

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, DesignSystem.Spacing.xs)
                    .accessibilityIdentifier(actionIdentifier ?? actionTitle)
            }

            Spacer(minLength: DesignSystem.Spacing.xl)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
