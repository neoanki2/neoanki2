import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct StudyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StudyPreferences.usesPassFailGrades) private var usesPassFailGrades = false
    @Bindable var model: StudyModel
    @Bindable var itemsModel: ItemsModel
    @Bindable var decksModel: DecksModel
    let scope: StudyScope
    let mediaStore: MediaStore?
    @Binding var endSessionTrigger: Bool
    /// Owned by the host so the Study menu can open the editor, and so the
    /// unmodified grade shortcuts stay disabled while it is open.
    @Binding var isEditingCard: Bool
    let onEndSession: () -> Void

    @State private var showGradeGuide = false
    @State private var showEndSessionConfirm = false
    @State private var showDeleteDraftConfirm = false
    @State private var recording = StudyRecordingController()
    @AccessibilityFocusState private var answerAccessibilityFocused: Bool
    @AccessibilityFocusState private var recordingErrorAccessibilityFocused: Bool

    var body: some View {
        Group {
            if model.isLoading {
                loadingView
            } else if model.didFailToLoad {
                loadFailureView
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
                recording.reset()
                onEndSession()
            }
            .accessibilityIdentifier("confirmEndStudySession")
            Button("Continue Studying", role: .cancel) {}
                .accessibilityIdentifier("cancelEndStudySession")
        } message: {
            if model.currentCard?.template.interaction == .audioSubmission, recording.hasRecording {
                Text("The unsaved audio draft will be permanently discarded.")
            } else if model.cardsReviewed > 0 {
                Text("You've completed \(model.cardsReviewed) reviews. The current card won't be saved.")
            } else {
                Text("The current card won't be saved.")
            }
        }
        .confirmationDialog(
            "Delete this audio draft?",
            isPresented: $showDeleteDraftConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Draft", role: .destructive) { recording.reset() }
            Button("Keep Draft", role: .cancel) {}
        } message: {
            Text("This recording has not been saved and cannot be recovered.")
        }
        .onChange(of: model.isAnswerRevealed) { _, revealed in
            guard revealed, let cardID = model.currentCard?.id else { return }
            if AccessibilityNotifier.shared.post(.answerRevealed(cardID: cardID)) != nil {
                answerAccessibilityFocused = true
            }
        }
        .sheet(isPresented: $isEditingCard) {
            cardEditor
        }
        .focusedSceneValue(\.studyPrimaryActionHandler, primaryActionHandler)
    }

    /// The library's item editor, opened on the card in front of you. Saving
    /// reconciles cards the way an edit from the library does, so a correction
    /// costs the session nothing beyond the cards the edit itself retires.
    @ViewBuilder
    private var cardEditor: some View {
        if let card = model.currentCard {
            NavigationStack {
                AddItemView(
                    model: itemsModel,
                    decksModel: decksModel,
                    editingItem: card.item,
                    editingItemType: card.itemType
                ) {
                    isEditingCard = false
                    Task { await model.reloadCurrentItem() }
                }
            }
        }
    }

    private var primaryActionHandler: StudyPrimaryActionHandler {
        let interaction = model.currentCard?.template.interaction
        let recordingIsReady = interaction != .record || recording.isReadyForComparison
        return StudyPrimaryActionHandler(
            action: {
                StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                    model.performPrimaryAction()
                }
            },
            isEnabled: canShowAnswer
                && recordingIsReady
                && interaction != .audioSubmission
                && !isEditingCard
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
            && !model.isPreparingQueue
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

    /// Reached only when a session opens on an empty queue. The scope home is
    /// where "nothing is due" is answered properly, with the time the next card
    /// returns, so this state's job is to send you back there.
    private var emptyDueView: some View {
        ContentUnavailableView {
            Label("Nothing Due Right Now", systemImage: "calendar.badge.clock")
        } description: {
            Text("Leave the session to see when the next card in this scope comes back.")
        } actions: {
            Button("Back to Library") {
                onEndSession()
            }
            .accessibilityIdentifier("studyBackToLibrary")
        }
    }

    /// A queue that could not be read is not a finished session. Saying so, and
    /// offering the retry, keeps a single unreadable card from looking like the
    /// scope had nothing left to study.
    private var loadFailureView: some View {
        ContentUnavailableView {
            Label("Couldn't Load Due Cards", systemImage: "exclamationmark.triangle")
        } description: {
            Text(model.errorMessage ?? "The due cards for this scope could not be read.")
        } actions: {
            Button("Try Again") {
                Task { await model.startSession(scope: scope) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("studyRetryLoad")

            Button("Back to Library") {
                onEndSession()
            }
            .accessibilityIdentifier("studyBackToLibrary")
        }
        .accessibilityIdentifier("studyLoadFailure")
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
            .keyboardShortcut(.defaultAction)
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

            Button("Edit Card") {
                isEditingCard = true
            }
            .buttonStyle(.borderless)
            .disabled(model.isGrading || model.isPreparingQueue)
            .help("Fix or extend this card (Command-E)")
            .accessibilityIdentifier("editStudyCard")

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
                GradeGuideView(gradingMode: gradingMode)
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
                .accessibilityIdentifier("studyInteractionMessage")
        }

        if model.isAnswerRevealed {
            Divider()
            evaluationFeedback

            if card.template.interaction == .record, recording.hasRecording {
                revealedRecordingPlayback
            }

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
        case .audioSubmission:
            audioSubmissionResponse
        case .arrange:
            arrangementResponse
        }
    }

    private var audioSubmissionResponse: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Label("Saved response", systemImage: "lock.fill")
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(.secondary)
            Text("This recording stays in your local library and is not synced to the cloud.")
                .font(DesignSystem.Typography.uiHint)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(recordingDurationText)
                .font(.system(.title2, design: .monospaced).monospacedDigit())
                .accessibilityLabel("Recording duration \(recordingDurationText)")

            if recording.state == .recording {
                Button("Stop Recording", systemImage: "stop.circle.fill") { recording.stop() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityHint("Stops the current audio submission recording")
            } else if recording.hasRecording {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button(recording.state == .playing ? "Stop Playback" : "Play Recording", systemImage: recording.state == .playing ? "stop.fill" : "play.fill") {
                        recording.togglePlayback()
                    }
                    .controlSize(.large)
                    .keyboardShortcut("p", modifiers: [.command])

                    Button("Record Again", systemImage: "arrow.counterclockwise") {
                        Task { await recording.start(persistentSubmission: true) }
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: [.command])

                    Button("Delete Draft", systemImage: "trash", role: .destructive) {
                        showDeleteDraftConfirm = true
                    }
                    .controlSize(.large)
                }
            } else {
                Button("Start Recording", systemImage: "mic.fill") {
                    Task { await recording.start(persistentSubmission: true) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(recording.state == .requestingPermission)
            }

            if case let .failed(message) = recording.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.uiHint)
                    .foregroundStyle(.red)
                    .accessibilityFocused($recordingErrorAccessibilityFocused)
            }
        }
        .frame(maxWidth: 620)
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityIdentifier("stopRecording")
                } else if recording.hasRecording {
                    Button("Record Again") {
                        Task { await recording.start() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(recording.state == .requestingPermission)
                    .accessibilityIdentifier("startRecording")
                } else {
                    Button("Start Recording") {
                        Task { await recording.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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

    private var revealedRecordingPlayback: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Label(revealedRecordingStatusText, systemImage: recordingStatusIcon)
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(recordingHasError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .accessibilityFocused($recordingErrorAccessibilityFocused)

            Button(recording.state == .playing ? "Stop My Recording" : "Play My Recording") {
                recording.togglePlayback()
            }
            .controlSize(.large)
            .keyboardShortcut("p", modifiers: [.command])
            .accessibilityIdentifier("playRecording")
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
            if card.template.interaction == .audioSubmission {
                if model.isCompletingSubmission {
                    ProgressView("Saving response…")
                        .frame(minHeight: 44)
                } else {
                    Button("Save & Complete", systemImage: "checkmark.circle.fill") {
                        guard let draft = recording.submissionDraft(cardID: card.id) else { return }
                        Task {
                            if await model.completeAudioSubmission(draft) { recording.reset() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recording.submissionDraft(cardID: card.id) == nil || model.isPreparingQueue)
                    .accessibilityHint("Saves this recording locally and completes the card without grading it")
                    .accessibilityIdentifier("saveAudioSubmission")
                }
            } else if model.isAnswerRevealed {
                gradeButtons
            } else {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if card.template.interaction != .record || recording.isReadyForComparison {
                        Button(primaryActionTitle(for: card.template.interaction)) {
                            StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                                model.performPrimaryAction()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("primaryStudyAction")
                    }

                    if card.template.interaction != .reveal, card.template.interaction != .cloze {
                        Button("Reveal & Self-Grade") {
                            StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                                model.revealAnswer()
                            }
                        }
                        .controlSize(.large)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .help("Reveal without checking (Right Arrow)")
                        .disabled(
                            card.template.interaction == .record
                                && (recording.state == .recording
                                    || recording.state == .requestingPermission)
                        )
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
            ForEach(gradingMode.choices, id: \.rating) { choice in
                Button(choice.titleWithShortcut) {
                    Task { await model.grade(choice.rating) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(
                    KeyEquivalent(Character(choice.shortcutLabel)),
                    modifiers: []
                )
                .help(choice.guidance)
                .disabled(model.isGrading || model.isPreparingQueue)
                .accessibilityLabel(choice.accessibilityLabel)
                .accessibilityIdentifier(choice.rating.gradeAccessibilityIdentifier)
            }
        }
    }

    private func gradeUndoBanner(for undo: PendingGradeUndo) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Graded as \(gradingMode.title(for: undo.rating)).")
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

    private var gradingMode: StudyGradingMode {
        StudyGradingMode(usesPassFailGrades: usesPassFailGrades)
    }

    private func requestEndSession() {
        if !model.isFinished,
           (model.cardsReviewed > 0
               || (model.currentCard?.template.interaction == .audioSubmission
                   && recording.hasRecording)) {
            showEndSessionConfirm = true
        } else {
            recording.reset()
            onEndSession()
        }
    }

    private func primaryActionTitle(for interaction: Interaction) -> String {
        switch interaction {
        case .reveal, .cloze: "Show Answer"
        case .type: "Check Answer"
        case .choose: "Check Choice"
        case .record: "Reveal & Compare"
        case .audioSubmission: "Save & Complete"
        case .arrange: "Check Order"
        }
    }

    private var recordingDurationText: String {
        let total = max(0, Int(recording.elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
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

    private var revealedRecordingStatusText: String {
        switch recording.state {
        case .playing:
            "Playing your recording…"
        case let .failed(message):
            message
        case .idle, .requestingPermission, .recording, .recorded:
            "Your recording"
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
