import SwiftUI

enum DesignSystem {
    // MARK: - Accent

    /// The user's macOS accent, including its Light, Dark, and Increased Contrast variants.
    static var accent: Color { Color(nsColor: .controlAccentColor) }

    // MARK: - Surfaces

    static var sidebarBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var detailBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static func errorBannerBackground(contrast: ColorSchemeContrast) -> Color {
        Color(nsColor: .systemRed).opacity(contrast == .increased ? 0.22 : 0.12)
    }

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
        /// Half step, and the only one. It binds a label to the line directly
        /// beneath it; anything that separates two ideas uses `xs` or larger.
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
    // Semantic styles only, so every surface scales with Dynamic Type. The card
    // sizes here are the ones DESIGN.md and .impeccable/design.json record; UI
    // chrome must not borrow them.

    enum Typography {
        static let cardPrompt = Font.largeTitle
        static let cardAnswer = Font.title
        static let cardSecondary = Font.title2

        /// The one number a pane exists to deliver. Bold rather than large,
        /// because card sizes belong to the card — so whatever sits near this
        /// has to be quieter than a section heading for the weight to read.
        static let uiDisplay = Font.title2.weight(.bold)

        static let uiTitle = Font.title2.weight(.semibold)
        static let uiSection = Font.title3.weight(.semibold)
        static let uiBody = Font.body

        /// The two lines of a sidebar scope row: a name and the counts under it.
        /// Denser than `uiBody`/`uiCaption` because a list row is not prose.
        static let uiRowTitle = Font.headline
        static let uiRowMeta = Font.caption

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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(DesignSystem.Typography.uiCaption)
            .foregroundStyle(.primary)
            .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignSystem.errorBannerBackground(contrast: colorSchemeContrast))
            .accessibilityLabel("Error, \(message)")
            .accessibilityFocused($isAccessibilityFocused)
            .task(id: message) {
                if AccessibilityNotifier.shared.post(.errorBanner(message)) != nil {
                    isAccessibilityFocused = true
                }
            }
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
    var contentIdentifier: String?

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

            // An empty surface has exactly one thing worth doing, so this is the
            // primary forward action and is sized like one.
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, DesignSystem.Spacing.xs)
                    .accessibilityIdentifier(actionIdentifier ?? actionTitle)
            }

            Spacer(minLength: DesignSystem.Spacing.xl)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(OptionalAccessibilityIdentifier(identifier: contentIdentifier))
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier, !identifier.isEmpty {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
