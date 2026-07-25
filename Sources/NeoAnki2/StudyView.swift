import NeoAnkiCore
import SwiftUI

struct StudyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: StudyModel
    let scope: StudyScope
    let mediaStore: MediaStore?
    @Binding var endSessionTrigger: Bool
    let onEndSession: () -> Void

    @State private var showGradeGuide = false
    @State private var showEndSessionConfirm = false
    @State private var recording = StudyRecordingController()
    @AccessibilityFocusState private var answerAccessibilityFocused: Bool
    @AccessibilityFocusState private var recordingErrorAccessibilityFocused: Bool

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
                .accessibilityIdentifier("cancelEndStudySession")
        } message: {
            if model.cardsReviewed > 0 {
                Text("You've reviewed \(model.cardsReviewed) cards. The current card won't be saved.")
            } else {
                Text("The current card won't be saved.")
            }
        }
        .onChange(of: model.isAnswerRevealed) { _, revealed in
            guard revealed, let cardID = model.currentCard?.id else { return }
            if AccessibilityNotifier.shared.post(.answerRevealed(cardID: cardID)) != nil {
                answerAccessibilityFocused = true
            }
        }
        .focusedSceneValue(\.studyPrimaryActionHandler, primaryActionHandler)
    }

    private var primaryActionHandler: StudyPrimaryActionHandler {
        let recordingIsReady = model.currentCard?.template.interaction != .record || recording.hasRecording
        return StudyPrimaryActionHandler(
            action: {
                StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                    model.performPrimaryAction()
                }
            },
            isEnabled: canShowAnswer && recordingIsReady
        )
    }

    private var canShowAnswer: Bool {
        guard model.currentCard != nil else { return false }
        return !model.isAnswerRevealed
            && !model.isLoading
            && !model.isFinished
    }

    private var canGrade: Bool {
        guard model.currentCard != nil else { return false }
        return model.isAnswerRevealed
            && !model.isGrading
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
        .accessibilityIdentifier("studyLoading")
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
            if model.canUndoLastGrade {
                Button("Undo Last Grade") {
                    Task { await model.undoLastGrade() }
                }
                .disabled(model.isGrading)
                .accessibilityIdentifier("undoLastGrade")
            }

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
                    studyCardContent(card)
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
        .onChange(of: card.id) {
            recording.reset()
        }
        .onChange(of: recording.state) { _, state in
            guard case let .failed(message) = state else { return }
            if AccessibilityNotifier.shared.post(.recordingError(message)) != nil {
                recordingErrorAccessibilityFocused = true
            }
        }
        .onDisappear {
            recording.reset()
        }
    }

    private var studyHeader: some View {
        HStack {
            Text(model.headerLabel)
                .font(DesignSystem.Typography.uiCaption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Progress, \(model.headerLabel)")
                .accessibilityIdentifier("studyProgress")

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
    private func studyCardContent(_ card: DueCard) -> some View {
        SideContentView(
            side: card.template.prompt,
            item: card.item,
            isAnswerRevealed: model.isAnswerRevealed,
            richTextPointSize: DesignSystem.Typography.cardPromptPointSize,
            mediaStore: mediaStore,
            clozeGroup: card.card.clozeGroup
        )
            .accessibilityIdentifier("studyPrompt")
            .font(DesignSystem.Typography.cardPrompt)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

        if !model.isAnswerRevealed {
            interactionResponse(for: card)
        }

        if let message = model.interactionMessage {
            Text(message)
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("studyInteractionMessage")
        }

        if model.isAnswerRevealed {
            Divider()
            evaluationFeedback
            SideContentView(
                side: card.template.answer,
                item: card.item,
                isAnswerRevealed: true,
                richTextPointSize: DesignSystem.Typography.cardAnswerPointSize,
                mediaStore: mediaStore,
                clozeGroup: card.card.clozeGroup
            )
                .accessibilityIdentifier("studyAnswer")
                .font(DesignSystem.Typography.cardAnswer)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .accessibilityFocused($answerAccessibilityFocused)
        }
    }

    @ViewBuilder
    private func interactionResponse(for card: DueCard) -> some View {
        switch card.template.interaction {
        case .reveal, .cloze:
            EmptyView()
        case .type:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Your answer")
                    .font(DesignSystem.Typography.uiCaption)
                    .foregroundStyle(.secondary)
                TextField(
                    "Type your answer",
                    text: Binding(
                        get: { model.typedAnswer },
                        set: { model.updateTypedAnswer($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitTypedAnswer() }
                .accessibilityIdentifier("typedAnswer")
                Text("Press Return to check. You’ll still choose your own grade.")
                    .font(DesignSystem.Typography.uiHint)
                    .foregroundStyle(.tertiary)
            }
        case .choose:
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(model.choiceOptions.enumerated()), id: \.offset) { index, option in
                    Button {
                        model.selectChoice(option)
                    } label: {
                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                            Text(option)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.selectedChoice == option {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                    .help("Choose option \(index + 1) (\(index + 1))")
                    .accessibilityLabel("Option \(index + 1), \(option)")
                    .accessibilityValue(model.selectedChoice == option ? "Selected" : "")
                    .accessibilityIdentifier("choiceOption\(index)")
                }
            }
            .frame(maxWidth: .infinity)
        case .record:
            recordingResponse
        case .arrange:
            arrangementResponse
        }
    }

    @ViewBuilder
    private var evaluationFeedback: some View {
        switch model.answerEvaluation {
        case .correct:
            Label("Your response matches.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("answerCorrect")
        case .incorrect:
            Label("Compare your response with the answer.", systemImage: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("answerIncorrect")
        case .unavailable:
            Label("Automatic checking wasn’t available.", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("answerCheckUnavailable")
        case nil:
            EmptyView()
        }
    }

    private var recordingResponse: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Label(recordingStatusText, systemImage: recordingStatusIcon)
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(recordingHasError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .accessibilityFocused($recordingErrorAccessibilityFocused)

            HStack(spacing: DesignSystem.Spacing.sm) {
                if recording.state == .recording {
                    Button("Stop Recording") {
                        recording.stop()
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityIdentifier("stopRecording")
                } else {
                    Button(recording.hasRecording ? "Record Again" : "Start Recording") {
                        Task { await recording.start() }
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(recording.state == .requestingPermission)
                    .accessibilityIdentifier("startRecording")
                }

                if recording.hasRecording, recording.state != .recording {
                    Button(recording.state == .playing ? "Stop Playback" : "Play My Recording") {
                        recording.togglePlayback()
                    }
                    .keyboardShortcut("p", modifiers: [.command])
                    .accessibilityIdentifier("playRecording")
                }
            }
        }
    }

    private var arrangementResponse: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Text("Select an item, then move it into the right order.")
                .font(DesignSystem.Typography.uiHint)
                .foregroundStyle(.secondary)

            ForEach(Array(model.arrangedItems.enumerated()), id: \.offset) { index, item in
                Button {
                    model.selectArrangementItem(at: index)
                } label: {
                    HStack {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        Text(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.selectedArrangementIndex == index {
                            Image(systemName: "selection.pin.in.out")
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .modifier(ArrangementSelectionShortcut(index: index))
                .accessibilityLabel("Position \(index + 1), \(item)")
                .accessibilityValue(model.selectedArrangementIndex == index ? "Selected" : "")
                .accessibilityIdentifier("arrangementItem\(index)")
            }

            HStack {
                Button("Move Up", systemImage: "arrow.up") {
                    model.moveSelectedArrangementItem(by: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(model.selectedArrangementIndex == nil || model.selectedArrangementIndex == 0)
                .accessibilityIdentifier("moveArrangementUp")

                Button("Move Down", systemImage: "arrow.down") {
                    model.moveSelectedArrangementItem(by: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(
                    model.selectedArrangementIndex == nil
                        || model.selectedArrangementIndex == model.arrangedItems.indices.last
                )
                .accessibilityIdentifier("moveArrangementDown")
            }
        }
    }

    @ViewBuilder
    private func studyFooter(for card: DueCard) -> some View {
        HStack {
            if model.isAnswerRevealed {
                gradeButtons
            } else {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button(primaryActionTitle(for: card.template.interaction)) {
                        StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                            model.performPrimaryAction()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(card.template.interaction == .record && !recording.hasRecording)
                    .accessibilityIdentifier("primaryStudyAction")

                    if card.template.interaction != .reveal, card.template.interaction != .cloze {
                        Button("Reveal & Self-Grade") {
                            StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                                model.revealAnswer()
                            }
                        }
                        .controlSize(.large)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .help("Reveal without checking (Right Arrow)")
                        .accessibilityIdentifier("revealAndSelfGrade")
                    }
                }
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
            .accessibilityIdentifier("dismissGradeUndo")
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

    private func primaryActionTitle(for interaction: Interaction) -> String {
        switch interaction {
        case .reveal, .cloze: "Show Answer"
        case .type: "Check Answer"
        case .choose: "Check Choice"
        case .record: "Compare Recording"
        case .arrange: "Check Order"
        }
    }

    private var recordingHasError: Bool {
        if case .failed = recording.state { return true }
        return false
    }

    private var recordingStatusText: String {
        switch recording.state {
        case .idle: "Record yourself, then compare with the reference answer."
        case .requestingPermission: "Waiting for microphone permission…"
        case .recording: "Recording… press Command-R to stop."
        case .recorded: "Recording ready. Play it back before comparing."
        case .playing: "Playing your recording…"
        case let .failed(message): message
        }
    }

    private var recordingStatusIcon: String {
        switch recording.state {
        case .recording: "waveform"
        case .recorded, .playing: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .idle, .requestingPermission: "mic"
        }
    }
}

/// Binds Command-1 … Command-9 to the first nine arrangement items so the whole
/// arrange interaction (select then move with Command-Arrow) is keyboard-only.
/// Command avoids clashing with the plain 1–4 grade shortcuts, which are only
/// active once the answer is revealed.
private struct ArrangementSelectionShortcut: ViewModifier {
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(
                KeyEquivalent(Character("\(index + 1)")),
                modifiers: [.command]
            )
        } else {
            content
        }
    }
}
