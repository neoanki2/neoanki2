import AVFoundation
import AVKit
import ImageIO
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

#if os(iOS)
struct StudySessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: StudyFeatureModel
    @Bindable var model: MobileAppModel
    @State private var confirmsEnd = false
    @State private var isEditing = false
    @State private var loadedItem: (item: Item, itemType: ItemType)?
    @State private var recorder = MobileStudyRecorder()
    @State private var confirmsDeleteDraft = false
    @State private var showsSchedulingDetails = false
    @AccessibilityFocusState private var answerFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if session.isComplete {
                    ContentUnavailableView {
                        Label("Session Complete", systemImage: "checkmark.circle")
                    } description: {
                        Text("\(session.completion.reviews) reviews · \(session.completion.uniqueCards) cards · \(session.completion.uniqueItems) items")
                    } actions: {
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                } else if let card = session.currentCard {
                    studyCard(card)
                }
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("End") { confirmsEnd = true }
                }
                if !session.isComplete {
                    ToolbarItem(placement: .principal) {
                        Text("\(session.remainingCount) remaining")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityLabel("\(session.remainingCount) cards remaining")
                    }
                }
                if !session.isComplete {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { Task { await session.undoLastGrade() } }.disabled(!session.canUndo)
                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Skip Card", systemImage: "forward") { session.skip() }
                            Button("Edit Current Item", systemImage: "pencil") { Task { await openEditor() } }
                        }
                    }
                }
            }
            .alert("Could Not Save", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.error?.message ?? "Please try again.")
            }
        }
        .interactiveDismissDisabled(session.isGrading || session.isCompletingSubmission || recorder.hasRecording)
        .confirmationDialog("End this study session?", isPresented: $confirmsEnd) {
            Button("End Session", role: .destructive) { recorder.cleanup(); dismiss() }
            Button("Keep Studying", role: .cancel) {}
        } message: {
            Text(recorder.hasRecording
                ? "The unsaved audio draft will be permanently discarded. Completed work is already saved."
                : "Your completed work is already saved.")
        }
        .confirmationDialog("Delete this audio draft?", isPresented: $confirmsDeleteDraft) {
            Button("Delete Draft", role: .destructive) { recorder.cleanup() }
            Button("Keep Draft", role: .cancel) {}
        } message: {
            Text("This recording has not been saved and cannot be recovered.")
        }
        .sheet(isPresented: $showsSchedulingDetails) {
            if let card = session.currentCard {
                MobileSchedulingExplanationView(
                    card: card,
                    previews: session.schedulePreviews,
                    health: session.schedulingHealth
                )
            }
        }
        .sheet(isPresented: $isEditing) {
            if let loadedItem {
                ItemEditMobileView(model: model, loaded: loadedItem) { updated in
                    self.loadedItem = updated
                    Task { await session.reloadCurrentItem() }
                }
            }
        }
        .onDisappear { recorder.cleanup() }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { session.error != nil },
            set: { if !$0 { session.dismissError() } }
        )
    }

    private func studyCard(_ card: DueCard) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 16)

                MobileSideView(
                    side: card.template.prompt,
                    item: card.item,
                    mediaStore: session.mediaStore,
                    isAnswerRevealed: session.isAnswerRevealed
                )
                .font(.largeTitle)
                .accessibilityElement(children: .combine)

                if !session.isAnswerRevealed {
                    interaction(for: card)
                } else if let evaluation = session.answerEvaluation {
                    Label(evaluationLabel(evaluation), systemImage: evaluation == .correct ? "checkmark.circle" : "info.circle")
                        .font(.headline)
                        .accessibilityAddTraits(.isSummaryElement)
                }

                if session.isAnswerRevealed {
                    Divider()
                        .padding(.vertical, 4)

                    MobileSideView(
                        side: card.template.answer,
                        item: card.item,
                        mediaStore: session.mediaStore,
                        isAnswerRevealed: true
                    )
                    .font(.title)
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused($answerFocused)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer(minLength: 80)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .safeAreaInset(edge: .bottom) {
            studyActions
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: session.isAnswerRevealed)
        .onChange(of: session.isAnswerRevealed) { _, revealed in
            if revealed { answerFocused = true }
        }
    }

    @ViewBuilder
    private var studyActions: some View {
        if let card = session.currentCard, card.template.interaction == .audioSubmission {
            if session.isCompletingSubmission {
                ProgressView("Saving response…")
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button {
                    guard let draft = recorder.submissionDraft(cardID: card.id) else { return }
                    Task {
                        if await session.completeAudioSubmission(draft) { recorder.cleanup() }
                    }
                } label: {
                    Label("Save & Complete", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(recorder.submissionDraft(cardID: card.id) == nil)
                .accessibilityHint("Saves this recording locally and completes the card without grading it")
            }
        } else if session.isAnswerRevealed {
            if session.isGrading {
                ProgressView("Saving review…")
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        gradeButton("Again", rating: .again, hint: "I did not remember")
                        gradeButton("Hard", rating: .hard, hint: "I remembered with difficulty")
                        gradeButton("Good", rating: .good, hint: "I remembered correctly")
                        gradeButton("Easy", rating: .easy, hint: "I remembered immediately")
                    }
                    HStack(spacing: 16) {
                        Menu("Grade Help", systemImage: "questionmark.circle") {
                            Text("Again — not remembered")
                            Text("Hard — remembered with difficulty")
                            Text("Good — correctly remembered")
                            Text("Easy — immediate recall")
                        }
                        Button("Scheduling Details", systemImage: "info.circle") {
                            showsSchedulingDetails = true
                        }
                        .disabled(session.schedulePreviews.isEmpty)
                    }
                }
            }
        } else {
            Button {
                session.performPrimaryAction()
            } label: {
                Label(primaryActionLabel, systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func interaction(for card: DueCard) -> some View {
        switch card.template.interaction {
        case .reveal, .cloze:
            EmptyView()
        case .type:
            TextField("Type your answer", text: Binding(get: { session.typedAnswer }, set: { session.updateTypedAnswer($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).submitLabel(.done).onSubmit { session.performPrimaryAction() }
                .frame(maxWidth: 520).accessibilityLabel("Typed answer")
        case .choose:
            VStack(spacing: 8) {
                ForEach(session.choiceOptions, id: \.self) { option in
                    Button { session.selectChoice(option) } label: {
                        HStack { Text(option).multilineTextAlignment(.leading); Spacer(); if session.selectedChoice == option { Image(systemName: "checkmark.circle.fill") } }
                            .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 12)
                    }.buttonStyle(.bordered).accessibilityAddTraits(session.selectedChoice == option ? .isSelected : [])
                }
            }.frame(maxWidth: 520)
        case .arrange:
            VStack(spacing: 8) {
                ForEach(Array(session.arrangedItems.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Button(value) { session.selectArrangementItem(at: index) }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        Button("Up", systemImage: "chevron.up") { session.selectArrangementItem(at: index); session.moveSelectedArrangementItem(by: -1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(index == 0)
                        Button("Down", systemImage: "chevron.down") { session.selectArrangementItem(at: index); session.moveSelectedArrangementItem(by: 1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(index == session.arrangedItems.count - 1)
                    }
                }
            }.frame(maxWidth: 560)
        case .record:
            VStack(spacing: 10) {
                Button(recorder.isRecording ? "Stop Recording" : "Record Answer", systemImage: recorder.isRecording ? "stop.circle" : "mic") {
                    Task { if recorder.isRecording { recorder.stop(); session.performPrimaryAction() } else { await recorder.start() } }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if recorder.hasRecording { Button("Play My Recording", systemImage: "play") { recorder.play() } }
                if let message = recorder.errorMessage { Text(message).foregroundStyle(.secondary) }
            }
        case .audioSubmission:
            VStack(spacing: 12) {
                Label("Saved response", systemImage: "lock.fill")
                    .font(.headline)
                Text("This recording stays in your local library and is not synced to the cloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(recorder.durationLabel)
                    .font(.system(.title2, design: .monospaced).monospacedDigit())
                    .accessibilityLabel("Recording duration \(recorder.durationLabel)")

                if recorder.isRecording {
                    Button("Stop Recording", systemImage: "stop.circle.fill") { recorder.stop() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(minHeight: 44)
                } else if recorder.hasRecording {
                    Button(recorder.isPlaying ? "Stop Playback" : "Play Recording", systemImage: recorder.isPlaying ? "stop.fill" : "play.fill") { recorder.togglePlayback() }
                        .frame(minHeight: 44)
                    Button("Record Again", systemImage: "arrow.counterclockwise") {
                        Task { await recorder.start(persistentSubmission: true) }
                    }
                    .frame(minHeight: 44)
                    Button("Delete Draft", systemImage: "trash", role: .destructive) { confirmsDeleteDraft = true }
                        .frame(minHeight: 44)
                } else {
                    Button("Start Recording", systemImage: "mic.fill") {
                        Task { await recorder.start(persistentSubmission: true) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(minHeight: 44)
                }
                if let message = recorder.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.red)
                }
            }
        }
        if let message = session.interactionMessage { Text(message).font(.subheadline).foregroundStyle(.secondary) }
    }

    private var primaryActionLabel: String {
        switch session.currentCard?.template.interaction {
        case .type: "Check Answer"
        case .choose: "Check Choice"
        case .arrange: "Check Order"
        case .record: "Compare Recording"
        case .audioSubmission: "Save & Complete"
        default: "Show Answer"
        }
    }

    private func evaluationLabel(_ value: NeoAnkiCore.AnswerEvaluation) -> String {
        switch value { case .correct: "Correct"; case .incorrect: "Compare with the answer"; case .unavailable: "Self-grade this answer" }
    }

    private func openEditor() async {
        guard let itemID = session.currentCard?.item.id else { return }
        loadedItem = try? await model.item(id: itemID)
        isEditing = loadedItem != nil
    }

    private func gradeButton(
        _ title: String,
        rating: ReviewRating,
        hint: String
    ) -> some View {
        let preview = session.schedulePreviews[rating]
        return Button {
            Task { await session.grade(rating) }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                Text(compactInterval(preview))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(session.isGrading || session.isLoadingSchedulePreviews)
        .accessibilityLabel("\(title), \(accessibleInterval(preview))")
        .accessibilityHint(hint)
    }

    private func compactInterval(_ preview: ReviewSchedulePreview?) -> String {
        guard let preview else { return "—" }
        let seconds = preview.intervalSeconds
        if seconds < 1 { return "Now" }
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 86_400 { return "\(max(1, Int((seconds / 3_600).rounded())))h" }
        return "\(max(1, Int((seconds / 86_400).rounded())))d"
    }

    private func accessibleInterval(_ preview: ReviewSchedulePreview?) -> String {
        guard let preview else { return "schedule loading" }
        let seconds = preview.intervalSeconds
        if seconds < 1 { return "next review immediately" }
        if seconds < 3_600 {
            let value = max(1, Int((seconds / 60).rounded()))
            return "next review in \(value) minutes"
        }
        if seconds < 86_400 {
            let value = max(1, Int((seconds / 3_600).rounded()))
            return "next review in \(value) hours"
        }
        let value = max(1, Int((seconds / 86_400).rounded()))
        return "next review in \(value) days"
    }
}

private struct MobileSchedulingExplanationView: View {
    @Environment(\.dismiss) private var dismiss
    let card: DueCard
    let previews: [ReviewRating: ReviewSchedulePreview]
    let health: LibrarySchedulingHealth?

    var body: some View {
        NavigationStack {
            List {
                Section("Current Memory") {
                    LabeledContent("Stability", value: "\(memoryBefore.stability.formatted(.number.precision(.fractionLength(3)))) days")
                    LabeledContent("Difficulty", value: memoryBefore.difficulty.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Model days", value: "\(elapsedModelDays)")
                }
                Section("Possible Answers") {
                    ForEach(ReviewRating.allCases, id: \.self) { rating in
                        if let preview = previews[rating] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(title(rating)).font(.headline)
                                    Spacer()
                                    Text(interval(preview)).font(.headline.monospacedDigit())
                                }
                                Text("Stability \(memoryTransition(preview)) · difficulty \(difficultyTransition(preview))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Recall \(preview.predictedRetrievability.formatted(.percent.precision(.fractionLength(1)))) · raw \(preview.rawIntervalDays.formatted(.number.precision(.fractionLength(3)))) days")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Applied \(preview.operationalIntervalSeconds) seconds · due \(preview.finalDueAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section("Policy") {
                    LabeledContent("Desired retention", value: retentionDescription)
                    LabeledContent("Memory model", value: representativePreview?.modelVersion ?? "Unavailable")
                    LabeledContent("Parameter set", value: representativePreview?.parameterSetID?.uuidString.lowercased() ?? "Unavailable")
                    LabeledContent("Elapsed-time policy", value: representativePreview?.timingPolicyVersion ?? "Unavailable")
                    LabeledContent("Interval policy", value: representativePreview?.intervalPolicyVersion ?? "Unavailable")
                    Text("Raw is the model interval. Applied is the operational interval after the displayed policy and constraint.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scheduling Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private var elapsedModelDays: Int {
        guard let last = memoryBefore.lastReview,
              let reference = previews.values.first?.reviewedAt else { return 0 }
        return Int(max(0, reference.timeIntervalSince(last)) / 86_400)
    }

    private var representativePreview: ReviewSchedulePreview? { previews[.good] ?? previews.values.first }
    private var memoryBefore: MemoryState { representativePreview?.memoryBefore ?? card.card.memory }
    private var retentionDescription: String {
        health?.desiredRetention.formatted(.percent.precision(.fractionLength(0...1))) ?? "Unavailable"
    }

    private func memoryTransition(_ preview: ReviewSchedulePreview) -> String {
        "\(preview.memoryBefore.stability.formatted(.number.precision(.fractionLength(3)))) → \(preview.memoryAfter.stability.formatted(.number.precision(.fractionLength(3)))) days"
    }

    private func difficultyTransition(_ preview: ReviewSchedulePreview) -> String {
        "\(preview.memoryBefore.difficulty.formatted(.number.precision(.fractionLength(2)))) → \(preview.memoryAfter.difficulty.formatted(.number.precision(.fractionLength(2))))"
    }

    private func title(_ rating: ReviewRating) -> String {
        switch rating { case .again: "Again"; case .hard: "Hard"; case .good: "Good"; case .easy: "Easy" }
    }

    private func interval(_ preview: ReviewSchedulePreview) -> String {
        let seconds = preview.intervalSeconds
        if seconds < 1 { return "Now" }
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 86_400 { return "\(max(1, Int((seconds / 3_600).rounded())))h" }
        return "\(max(1, Int((seconds / 86_400).rounded())))d"
    }
}

@MainActor @Observable
private final class MobileStudyRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var url: URL?
    private var responseID: UUID?
    private var capturedAt: Date?
    private var elapsedTask: Task<Void, Never>?
    private var isPersistentSubmission = false
    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var hasRecording = false
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var errorMessage: String?

    var durationLabel: String {
        let total = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func start(persistentSubmission: Bool = false) async {
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else {
            errorMessage = persistentSubmission
                ? "Microphone access was denied. Allow it in Settings to record this response."
                : "Microphone access was denied. You can reveal and self-grade without recording."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            cleanup()
            let responseID = UUID()
            let stem = persistentSubmission ? "neoanki-audio-submission" : "neoanki-recording"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem)-\(responseID.uuidString).m4a")
            var settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            if persistentSubmission { settings[AVEncoderBitRateKey] = 64_000 }
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record(forDuration: persistentSubmission ? 30 * 60 : 12 * 60 * 60)
            audioRecorder = recorder
            self.url = url
            self.responseID = responseID
            capturedAt = .now
            isPersistentSubmission = persistentSubmission
            elapsedSeconds = 0
            isRecording = true
            errorMessage = nil
            elapsedTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.isRecording else { return }
                    let elapsed = self.audioRecorder?.currentTime ?? self.elapsedSeconds
                    self.elapsedSeconds = self.isPersistentSubmission
                        ? min(30 * 60, elapsed)
                        : elapsed
                    if self.isPersistentSubmission,
                       let url = self.url,
                       (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        >= MediaValidation.maxBytes(for: .audio) {
                        self.stop()
                        self.errorMessage = "Recording stopped at the 20 MB limit. You can play it or save it."
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func stop() {
        elapsedSeconds = max(elapsedSeconds, audioRecorder?.currentTime ?? 0)
        audioRecorder?.stop(); audioRecorder = nil; elapsedTask?.cancel(); elapsedTask = nil
        isRecording = false; hasRecording = url != nil
    }
    func togglePlayback() {
        if isPlaying { player?.stop(); player = nil; isPlaying = false; return }
        guard let url else { return }
        do { player = try AVAudioPlayer(contentsOf: url); isPlaying = player?.play() == true }
        catch { errorMessage = "The recording could not be played. Record it again and retry." }
    }
    func play() { togglePlayback() }
    func submissionDraft(cardID: UUID) -> StudyResponseDraft? {
        guard isPersistentSubmission, !isRecording, let responseID, let url, let capturedAt, hasRecording else { return nil }
        return StudyResponseDraft(id: responseID, cardID: cardID, fileURL: url, durationMilliseconds: max(1, Int(elapsedSeconds * 1_000)), capturedAt: capturedAt)
    }
    func cleanup() {
        audioRecorder?.stop(); player?.stop(); elapsedTask?.cancel()
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil; responseID = nil; capturedAt = nil; elapsedTask = nil
        isRecording = false; isPlaying = false; hasRecording = false; elapsedSeconds = 0
        isPersistentSubmission = false
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.elapsedSeconds = max(self.elapsedSeconds, recorder.currentTime)
            self.audioRecorder = nil; self.elapsedTask?.cancel(); self.elapsedTask = nil
            self.isRecording = false; self.hasRecording = flag && self.url != nil
            if !flag { self.errorMessage = "The recording stopped before it could be saved. Please try again." }
        }
    }
}

struct MobileSideView: View {
    let side: Side
    let item: Item
    let mediaStore: MediaStore?
    let isAnswerRevealed: Bool

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(SideContent.resolvedSlots(for: side, from: item).enumerated()), id: \.offset) { _, slot in
                MobileContentValueView(
                    value: slot.value,
                    mediaStore: mediaStore,
                    mediaBehavior: slot.presentation.media,
                    revealMode: slot.presentation.reveal,
                    isAnswerRevealed: isAnswerRevealed
                )
            }
        }
    }
}

struct MobileContentValueView: View {
    let value: ContentValue
    var mediaStore: MediaStore? = nil
    var mediaBehavior: MediaBehavior = .default
    var revealMode: RevealMode = .always
    var isAnswerRevealed = true

    var body: some View {
        if shouldConceal {
            Label("Content hidden until answer", systemImage: "eye.slash")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        } else {
            switch value {
            case let .text(text, _):
                Text(text)
            case let .rich(spans):
                Text(Self.attributed(spans))
            case let .number(number):
                Text(number, format: .number)
            case let .cloze(text, blanks):
                Text(isAnswerRevealed ? text : Self.concealedCloze(text, blanks: blanks))
            case let .media(reference):
                MobileResolvedMediaView(reference: reference, store: mediaStore, behavior: mediaBehavior)
            case .empty:
                Text("No content")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shouldConceal: Bool {
        !isAnswerRevealed && (revealMode == .hiddenUntilAnswer || revealMode == .blurred)
    }

    private func symbol(for kind: MediaKind) -> String {
        switch kind {
        case .audio: "waveform"
        case .image: "photo"
        case .gif: "photo.stack"
        case .video: "video"
        }
    }

    private static func concealedCloze(_ text: String, blanks: [ClozeSpan]) -> String {
        var result = text
        for blank in blanks.sorted(by: { $0.start > $1.start }) {
            guard blank.start >= 0,
                  blank.length >= 0,
                  let start = result.index(result.startIndex, offsetBy: blank.start, limitedBy: result.endIndex),
                  let end = result.index(start, offsetBy: blank.length, limitedBy: result.endIndex)
            else { continue }
            result.replaceSubrange(start..<end, with: "____")
        }
        return result
    }

    private static func attributed(_ spans: [Span]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var value = AttributedString(span.text)
            var intent: InlinePresentationIntent = []
            if span.styles.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if span.styles.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { value.inlinePresentationIntent = intent }
            if span.styles.contains(.underline) { value.underlineStyle = .single }
            if span.styles.contains(.strikethrough) { value.strikethroughStyle = .single }
            if span.styles.contains(.highlight) { value.backgroundColor = .yellow.opacity(0.35) }
            if span.styles.contains(.code) { value.font = .system(.body, design: .monospaced) }
            if let color = span.textColor { value.foregroundColor = semanticColor(color) }
            if let size = span.textSize {
                value.font = size == .large ? .title3 : .caption
            }
            if let link = span.link, let url = URL(string: link) { value.link = url }
            result.append(value)
        }
        return result
    }

    private static func semanticColor(_ color: Span.TextColor) -> Color {
        switch color {
        case .red: .red; case .orange: .orange; case .yellow: .yellow; case .green: .green
        case .mint: .mint; case .teal: .teal; case .cyan: .cyan; case .blue: .blue
        case .indigo: .indigo; case .purple: .purple; case .pink: .pink; case .brown: .brown
        case .gray: .gray
        }
    }
}

private struct MobileResolvedMediaView: View {
    let reference: MediaRef
    let store: MediaStore?
    let behavior: MediaBehavior
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                MobileAnimatedImage(image: image).scaledToFit().frame(maxHeight: 420)
            } else if let player {
                VideoPlayer(player: player).frame(minHeight: reference.kind == .audio ? 64 : 220)
            } else if failed {
                Label(reference.altText ?? "Media unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView().accessibilityLabel("Loading \(reference.altText ?? "media")")
            }
        }
        .accessibilityLabel(reference.altText ?? "Media")
        .task(id: reference.assetHash) { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        guard let store else { failed = true; return }
        do {
            let resolved = try await store.resolve(reference)
            url = resolved
            switch reference.kind {
            case .image, .gif:
                image = UIImage(data: try Data(contentsOf: resolved, options: [.mappedIfSafe]))
                failed = image == nil
            case .audio, .video:
                let player = AVPlayer(url: resolved)
                self.player = player
                if behavior == .autoplay || behavior == .loop { player.play() }
                if behavior == .loop {
                    NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
                        player.seek(to: .zero); player.play()
                    }
                }
            }
        } catch { failed = true }
    }
}

private struct MobileAnimatedImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.startAnimating()
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) { view.image = image; view.startAnimating() }
}
#endif
