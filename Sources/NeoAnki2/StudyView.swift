import NeoAnkiCore
import SwiftUI

struct StudyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: StudyModel
    let scope: StudyScope
    @Binding var endSessionTrigger: Bool
    let onEndSession: () -> Void

    @State private var showGradeGuide = false
    @State private var showEndSessionConfirm = false

    var body: some View {
        Group {
            if model.isLoading {
                loadingView
            } else if model.isFinished {
                finishedView
            } else if let card = model.currentCard {
                activeCardView(card)
            } else {
                emptyDueView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.detailBackground)
        .task {
            await model.startSession(scope: scope)
        }
        .onChange(of: endSessionTrigger) { _, triggered in
            guard triggered else { return }
            endSessionTrigger = false
            requestEndSession()
        }
        .confirmationDialog(
            "End study session?",
            isPresented: $showEndSessionConfirm,
            titleVisibility: .visible
        ) {
            Button("End Session", role: .destructive) {
                onEndSession()
            }
            .accessibilityIdentifier("confirmEndStudySession")
            Button("Continue Studying", role: .cancel) {}
        } message: {
            if model.cardsReviewed > 0 {
                Text("You've reviewed \(model.cardsReviewed) cards. The current card won't be saved.")
            } else {
                Text("The current card won't be saved.")
            }
        }
    }

    private var canShowAnswer: Bool {
        guard let card = model.currentCard else { return false }
        return !model.isAnswerRevealed
            && !model.isLoading
            && !model.isFinished
            && card.template.interaction == .reveal
            && !cardHasUnsupportedContent(card)
    }

    private var canGrade: Bool {
        guard let card = model.currentCard else { return false }
        return model.isAnswerRevealed
            && !model.isGrading
            && card.template.interaction == .reveal
            && !cardHasUnsupportedContent(card)
    }

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
            Text("Loading due cards…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading due cards")
    }

    private var emptyDueView: some View {
        ContentUnavailableView {
            Label("You're Caught Up", systemImage: "calendar.badge.clock")
        } description: {
            Text("No cards are due right now. Add items to create new study cards.")
        } actions: {
            Button("Back to Items") {
                onEndSession()
            }
            .accessibilityIdentifier("studyBackToItems")
        }
    }

    private var finishedView: some View {
        ContentUnavailableView {
            Label("Session Complete", systemImage: "checkmark.circle")
        } description: {
            Text(model.queue.isEmpty ? "No more due cards in this session." : model.completionSummary)
        } actions: {
            Button("Done") {
                onEndSession()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("studySessionDone")
        }
    }

    @ViewBuilder
    private func activeCardView(_ card: DueCard) -> some View {
        VStack(spacing: 0) {
            studyHeader

            Divider()

            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    if cardHasUnsupportedContent(card) {
                        unsupportedContentView
                    } else if card.template.interaction != .reveal {
                        unsupportedInteractionView(card.template.interaction)
                    } else {
                        revealCardContent(card)
                    }
                }
                .readingColumnLayout()
            }

            if let errorMessage = model.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            if let undo = model.pendingGradeUndo {
                gradeUndoBanner(for: undo)
            }

            Divider()

            studyFooter(for: card)
        }
        .onExitCommand {
            requestEndSession()
        }
    }

    private var studyHeader: some View {
        HStack {
            Text(model.headerLabel)
                .font(DesignSystem.Typography.uiCaption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Progress, \(model.headerLabel)")

            Spacer()

            Button {
                showGradeGuide = true
            } label: {
                Label("Grade Help", systemImage: "questionmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("How grading works")
            .accessibilityLabel("Grade help")
            .accessibilityIdentifier("gradeHelp")
            .popover(isPresented: $showGradeGuide, arrowEdge: .top) {
                GradeGuideView()
            }

            Button("End Session") {
                requestEndSession()
            }
            .buttonStyle(.borderless)
            .help("End session (Escape)")
            .accessibilityIdentifier("endStudySession")
        }
        .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    @ViewBuilder
    private func revealCardContent(_ card: DueCard) -> some View {
        SideContentView(
            side: card.template.prompt,
            item: card.item,
            richTextPointSize: DesignSystem.Typography.cardPromptPointSize
        )
            .font(DesignSystem.Typography.cardPrompt)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

        if model.isAnswerRevealed {
            Divider()
            SideContentView(
                side: card.template.answer,
                item: card.item,
                richTextPointSize: DesignSystem.Typography.cardAnswerPointSize
            )
                .font(DesignSystem.Typography.cardAnswer)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        }
    }

    private var unsupportedContentView: some View {
        ContentUnavailableView {
            Label("Content Not Available Yet", systemImage: "photo")
        } description: {
            Text("This card includes media or cloze content that NeoAnki2 can't display yet.")
        }
        .frame(maxWidth: .infinity)
    }

    private func unsupportedInteractionView(_ interaction: Interaction) -> some View {
        ContentUnavailableView {
            Label("Not Available Yet", systemImage: "hammer")
        } description: {
            Text("\(interactionLabel(interaction)) cards aren't supported in the app yet.")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func studyFooter(for card: DueCard) -> some View {
        HStack {
            if cardHasUnsupportedContent(card) || card.template.interaction != .reveal {
                Button("Skip Card") {
                    model.skipCurrentCard()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Skip this card (Right Arrow)")
                .accessibilityLabel("Skip card")
                .accessibilityIdentifier("skipCard")
            } else if model.isAnswerRevealed {
                gradeButtons
            } else {
                Button("Show Answer") {
                    StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                        model.revealAnswer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityIdentifier("showAnswer")
                .accessibilityLabel("Show answer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(DesignSystem.Spacing.studyHorizontal)
    }

    private var gradeButtons: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button(rating.studyButtonTitleWithShortcut) {
                    Task { await model.grade(rating) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(rating.studyTooltip)
                .keyboardShortcut(rating.studyKeyboardShortcut, modifiers: [])
                .disabled(model.isGrading)
                .accessibilityLabel(rating.studyAccessibilityLabel)
                .accessibilityIdentifier(rating.gradeAccessibilityIdentifier)
            }
        }
    }

    private func gradeUndoBanner(for undo: PendingGradeUndo) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Graded as \(undo.rating.studyButtonTitle).")
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(.secondary)

            Button("Undo") {
                Task { await model.undoLastGrade() }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: [.command])
            .accessibilityIdentifier("undoLastGrade")

            Spacer()

            Button {
                model.dismissGradeUndo()
            } label: {
                Image(systemName: "xmark")
                    .font(DesignSystem.Typography.uiCaption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss undo")
        }
        .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.sidebarBackground)
    }

    private func requestEndSession() {
        if model.cardsReviewed > 0, !model.isFinished {
            showEndSessionConfirm = true
        } else {
            onEndSession()
        }
    }

    private func cardHasUnsupportedContent(_ card: DueCard) -> Bool {
        let values = SideContent.values(for: card.template.prompt, from: card.item)
            + SideContent.values(for: card.template.answer, from: card.item)
        return values.contains { value in
            switch value {
            case .media, .cloze:
                true
            default:
                false
            }
        }
    }

    private func interactionLabel(_ interaction: Interaction) -> String {
        switch interaction {
        case .reveal: "Reveal"
        case .type: "Type-the-answer"
        case .choose: "Multiple choice"
        case .record: "Record"
        case .cloze: "Cloze"
        case .arrange: "Arrange"
        }
    }
}
