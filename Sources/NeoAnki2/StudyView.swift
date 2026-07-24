import NeoAnkiCore
import SwiftUI

struct StudyView: View {
    @Bindable var model: StudyModel
    @Binding var endSessionTrigger: Bool
    let onEndSession: () -> Void

    @State private var showGradeGuide = false
    @State private var showEndSessionConfirm = false

    private let readingColumnMaxWidth: CGFloat = 600

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
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.startSession()
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
        VStack(spacing: 12) {
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
            Label("You're Caught Up", systemImage: "checkmark.circle")
        } description: {
            Text("No cards are due right now. Add items to create new study cards.")
        } actions: {
            Button("Back to Items") {
                onEndSession()
            }
            .accessibilityIdentifier("studyDone")
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
            .accessibilityIdentifier("studyDone")
        }
    }

    @ViewBuilder
    private func activeCardView(_ card: DueCard) -> some View {
        VStack(spacing: 0) {
            studyHeader

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    if cardHasUnsupportedContent(card) {
                        unsupportedContentView
                    } else if card.template.interaction != .reveal {
                        unsupportedInteractionView(card.template.interaction)
                    } else {
                        revealCardContent(card)
                    }
                }
                .frame(maxWidth: readingColumnMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
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
            Text(model.progressLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Progress, \(model.progressLabel)")

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
            .accessibilityIdentifier("endStudySession")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func revealCardContent(_ card: DueCard) -> some View {
        SideContentView(side: card.template.prompt, item: card.item)
            .font(.title)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

        if model.isAnswerRevealed {
            Divider()
            SideContentView(side: card.template.answer, item: card.item)
                .font(.title2)
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
                .accessibilityIdentifier("skipCard")
            } else if model.isAnswerRevealed {
                gradeButtons
            } else {
                Button("Show Answer") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        model.revealAnswer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityIdentifier("showAnswer")
                .accessibilityLabel("Show answer")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var gradeButtons: some View {
        HStack(spacing: 12) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button(rating.studyButtonTitle) {
                    Task { await model.grade(rating) }
                }
                .buttonStyle(.bordered)
                .help(rating.studyTooltip)
                .keyboardShortcut(rating.studyKeyboardShortcut, modifiers: [])
                .disabled(model.isGrading)
                .accessibilityLabel(rating.studyAccessibilityLabel)
                .accessibilityIdentifier(rating.gradeAccessibilityIdentifier)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12))
            .accessibilityLabel("Error, \(message)")
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
