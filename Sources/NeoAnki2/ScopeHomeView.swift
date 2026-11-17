import NeoAnkiCore
import NeoAnkiApplication
import NeoAnkiSharedUI
import SwiftUI

/// The default detail pane: what this scope owes you right now, and one way to
/// start. Enumerating items is a separate, deliberate mode.
struct ScopeHomeView: View {
    @Bindable var itemsModel: ItemsModel
    let scope: StudyScope
    let onStudy: () -> Void
    let onBrowse: () -> Void
    let onBrowseItemsNeedingAttention: () -> Void
    let onAddItem: () -> Void

    private var summary: ScopeSummary { itemsModel.scopeSummary }

    var body: some View {
        VStack(spacing: 0) {
#if DEBUG
            if AppDatabase.isTesting, !itemsModel.isLoading {
                Text("Library ready")
                    .font(.system(size: 1))
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityIdentifier("libraryReady")
            }
#endif
            if let errorMessage = itemsModel.errorMessage, !itemsModel.isLoading {
                ErrorBanner(message: errorMessage)
            }

            Group {
                if itemsModel.isLoading {
                    ProgressView("Loading library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("scopeHomeLoading")
                } else if summary.itemCount == 0 {
                    emptyState
                } else {
                    home
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignSystem.detailBackground)
        .navigationTitle(scope.label)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                // Shortcuts live on the menu commands, which is where macOS
                // displays them; declaring them here too gives one key two owners.
                Button("Browse", systemImage: "list.bullet") {
                    onBrowse()
                }
                .disabled(summary.itemCount == 0)
                .help("Browse and search every item in this scope")
                .accessibilityIdentifier("browseToolbar")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Item", systemImage: "plus") {
                    onAddItem()
                }
                .accessibilityIdentifier("addItemToolbar")
            }
        }
    }

    // MARK: - Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                // The rhythm is deliberately uneven: the headline block gets more
                // air beneath it than the blocks below get between them, so
                // position carries hierarchy that type size is not allowed to.
                dueSection
                    .padding(.bottom, DesignSystem.Spacing.xs)
                if summary.leechCount > 0 {
                    leechCallout
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .readingColumnLayout()
        }
        .accessibilityIdentifier("scopeHome")
    }

    /// The one question this pane exists to answer, with the one action that
    /// answers it. Emphasis is weight and space — card type sizes belong to the
    /// card.
    private var dueSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // The scope name is the window's navigation title; repeating it here
            // only gave the headline something to compete with.
            Text(dueHeadline)
                .font(DesignSystem.Typography.uiDisplay)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .accessibilityLabel("\(dueHeadline) in \(scope.label)")
                .accessibilityIdentifier("scopeHomeDueHeadline")

            if summary.hasDueCards {
                Button("Study", systemImage: "play.fill") {
                    onStudy()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("studyButton")
            } else {
                Text(nextDueSentence)
                    .font(DesignSystem.Typography.uiBody)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("scopeHomeNextDue")
            }
        }
    }

    private var dueHeadline: String {
        guard summary.hasDueCards else { return "You're caught up" }
        let noun = summary.dueNow == 1 ? "card" : "cards"
        return "\(summary.dueNow) \(noun) due"
    }

    /// Replaces the disabled Study button that used to sit here explaining
    /// nothing. Cards become due on a schedule; saying when is the answer.
    private var nextDueSentence: String {
        guard let nextStudyAt = summary.nextStudyAt else {
            return "Nothing is scheduled yet. Cards become due after their first review."
        }
        // Named presentation reads as plain language ("tomorrow") where numeric
        // does not.
        let relative = nextStudyAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        if summary.nextNewCardsAt == nextStudyAt {
            return "More new cards become available \(relative)."
        }
        return "The next card is due \(relative)."
    }

    private var leechCallout: some View {
        let noun = summary.leechCount == 1 ? "card has" : "cards have"
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                leechMessage(noun: noun)
                Spacer(minLength: DesignSystem.Spacing.sm)
                reviewAffectedItemsButton
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                leechMessage(noun: noun)
                reviewAffectedItemsButton
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 1)
        }
        .accessibilityIdentifier("scopeHomeLeechCallout")
    }

    private func leechMessage(noun: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                Text("\(summary.leechCount) \(noun) been forgotten repeatedly")
                    .font(DesignSystem.Typography.uiSecondary.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(
                    "Check the affected items. Rewrite unclear content, or mark it OK if it "
                        + "still reads well. Each card has lapsed at least "
                        + "\(ScopeSummary.leechThreshold) times."
                )
                .font(DesignSystem.Typography.uiCaption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var reviewAffectedItemsButton: some View {
        Button("Review Affected Items") {
            onBrowseItemsNeedingAttention()
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Opens Browse filtered to items containing repeatedly forgotten cards")
        .accessibilityIdentifier("scopeHomeReviewAffectedItems")
    }

    // MARK: - Empty

    /// Empty states teach what the app does with what you add, rather than
    /// reporting that nothing is here.
    @ViewBuilder
    private var emptyState: some View {
        switch scope.filter {
        case .allDecks:
            SidebarEmptyState(
                title: "Nothing to Remember Yet",
                message: "Add an item and NeoAnki2 turns it into cards, then brings each one back "
                    + "just before you would forget it.",
                systemImage: "rectangle.stack.badge.plus",
                actionTitle: "Add Item",
                action: onAddItem,
                actionIdentifier: "addItemEmptyState",
                contentIdentifier: "emptyLibraryState"
            )
        case .unassigned:
            SidebarEmptyState(
                title: "No Unassigned Items",
                message: "Items you add without choosing a deck collect here.",
                systemImage: "tray",
                actionTitle: nil,
                action: nil,
                actionIdentifier: nil,
                contentIdentifier: "emptyUnassignedState"
            )
        case .deck:
            SidebarEmptyState(
                title: "No Items in This Deck",
                message: "Add an item here and its cards join this deck's reviews.",
                // Distinct from the whole-library empty state: this deck is
                // empty, the library may not be.
                systemImage: "folder.badge.plus",
                actionTitle: "Add Item",
                action: onAddItem,
                actionIdentifier: "addItemEmptyState",
                contentIdentifier: "emptyDeckState"
            )
        }
    }
}
