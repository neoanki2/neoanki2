import Accessibility
import Observation
import AVKit
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

@MainActor @Observable private final class ContextPreviewPlayback {
    var requestID = UUID()
    private var player: AVPlayer?
    private var preparation: Task<Void, Never>?
    func begin() -> (request: UUID, previous: Task<Void, Never>?) {
        player?.pause(); player = nil
        let previous = preparation; previous?.cancel(); preparation = nil
        requestID = UUID()
        return (requestID, previous)
    }
    func track(_ task: Task<Void, Never>, request: UUID) {
        guard request == requestID else { task.cancel(); return }
        preparation = task
    }
    func attach(_ player: AVPlayer, request: UUID) {
        guard request == requestID else { player.pause(); return }
        self.player = player; player.play()
    }
}

// A deck and an expression are the only inputs. Language, meanings, spans, and speech are automatic.
public struct LearnInContextView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: LearnInContextModel
    @State private var previewPlayback = ContextPreviewPlayback()
    @FocusState private var expressionFocused: Bool
    private let deckID: UUID?
    private let expression: String
    private let language: String?
    private let meaning: String?

    public init(library: any LibraryRepository, rootURL: URL, deckID: UUID? = nil,
                expression: String = "", language: String? = nil, meaning: String? = nil,
                onSaved: @escaping @MainActor () async -> Void = {}) {
        _model = State(initialValue: LearnInContextModel(library: library, rootURL: rootURL, onSaved: onSaved))
        self.deckID = deckID; self.expression = expression; self.language = language; self.meaning = meaning
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Deck", selection: $model.draft.deckID) {
                            Text("Choose Deck").tag(UUID?.none)
                            ForEach(model.decks) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("context-deck")
                        if model.decks.isEmpty {
                            Text("Create a deck in the library before adding cards.").foregroundStyle(.secondary)
                        }
                        TextField("Word or phrase", text: Binding(get: { model.draft.target.expression }, set: model.updateExpression))
                        .textFieldStyle(.roundedBorder).focused($expressionFocused)
                        .submitLabel(model.selectedExamples.isEmpty ? .go : .done)
                        .onSubmit {
                            if model.selectedExamples.isEmpty, canFindExamples { model.findExamples() }
                            expressionFocused = false
                        }
                        .accessibilityLabel("Word or phrase")
                        .accessibilityIdentifier("context-expression")
                        if model.selectedExamples.isEmpty {
                            Button("Find Examples", systemImage: "text.magnifyingglass") {
                                model.findExamples(); expressionFocused = false
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canFindExamples)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("context-find-examples")
                        }
                    }
                    if let status = model.status {
                        HStack {
                            ProgressView()
                            Text(status)
                            Spacer()
                            if !model.isSaving {
                                Button { model.cancel() } label: { Text("Cancel").frame(minHeight: 44) }
                            }
                        }.font(.subheadline).accessibilityIdentifier("context-progress")
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).accessibilityIdentifier("context-error")
                    }
                    if let message = model.successMessage {
                        HStack(alignment: .firstTextBaseline) {
                            Text(message).accessibilityIdentifier("context-success")
                            if !model.lastSavedIDs.isEmpty {
                                Button { Task { await model.undoSave() } } label: { Text("Undo").frame(minHeight: 44) }
                                    .accessibilityIdentifier("context-undo-save")
                            }
                        }
                    }
                    ForEach(model.selectedExamples) { example in
                        VStack(alignment: .leading, spacing: 8) {
                            ContextOccurrences.richText(example.sentence, spans: example.spans).reduce(Text("")) { result, span in
                                result + (span.styles.contains(.bold) ? Text(span.text).bold() : Text(span.text))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(example.meaning ?? model.draft.target.meaning).font(.subheadline).foregroundStyle(.secondary)
                            ContextInlinePlayback(model: model, example: example, sourceLabel: sourceLabel(example))
                            Divider()
                        }.accessibilityElement(children: .contain)
                    }
                    if let reason = unavailableSpeechMessage {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.selectedExamples.isEmpty {
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            Spacer()
                            Button(model.isSaving ? "Adding Cards…" : "Add \(model.cardCount) Card\(model.cardCount == 1 ? "" : "s")") {
                                Task { await model.save() }
                            }
                            .buttonStyle(.borderedProminent).disabled(!model.canSave)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("context-add-cards")
                        }.padding(16)
                    }.background(.bar)
                }
            }
            .navigationTitle("Learn in Context")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.cancel(); dismiss() }.disabled(model.isSaving)
                }
            }
            .disabled(model.isSaving || model.isLoading)
            .task {
                await model.start(deckID: deckID, expression: expression, language: language, meaning: meaning)
                expressionFocused = model.selectedExamples.isEmpty
            }
            .onChange(of: model.draft) { _, _ in model.checkpoint() }
            .onChange(of: model.focusGeneration) { _, _ in expressionFocused = true }
            .onChange(of: model.successMessage) { _, value in
                if let value { AccessibilityNotification.Announcement(value).post() }
            }
            .onChange(of: model.errorMessage) { _, value in
                if let value { AccessibilityNotification.Announcement(value).post() }
            }
            .onChange(of: model.isWorking) { _, working in
                if !working, model.errorMessage == nil, !model.selectedExamples.isEmpty {
                    AccessibilityNotification.Announcement("\(model.selectedExamples.count) examples ready.").post()
                }
            }
            .onDisappear { model.cancel() }
        }
        .environment(previewPlayback)
        .controlSize(.large)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 600, minHeight: 400, idealHeight: 620)
        #endif
    }
    private var canFindExamples: Bool {
        !model.draft.target.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.draft.deckID != nil && !model.isWorking && !model.isSaving && !model.isLoading
    }
    private var unavailableSpeechMessage: String? {
        let reasons = Set(model.selectedExamples.filter { $0.mediaURL == nil }.compactMap { model.speechAvailability(for: $0).reason })
        guard !reasons.isEmpty else { return nil }
        return reasons.count == 1 ? reasons.first : "Some examples have no installed voice. You can still add their text cards."
    }
    private func sourceLabel(_ example: ContextExample) -> String {
        let origin = example.provenance.origin == .generated ? "Generated example" : example.provenance.sourceName
        return origin + (example.mediaURL != nil ? " · Original recording" : (model.speechAvailability(for: example) == .available ? " · Synthesized voice" : ""))
    }
}

private struct ContextInlinePlayback: View {
    @Environment(ContextPreviewPlayback.self) private var playback
    @Bindable var model: LearnInContextModel
    let example: ContextExample
    let sourceLabel: String
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var task: Task<Void, Never>?
    @State private var preparing = false
    @State private var requestID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                playButton
                Spacer()
                Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
            }
            if example.mediaKind == .video, let player {
                VideoPlayer(player: player).frame(height: 200)
            }
        }
        .onChange(of: playback.requestID) { _, value in if value != requestID { task?.cancel(); player?.pause() } }
        .onDisappear { task?.cancel(); player?.pause(); if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }
    }
    private var playButton: some View {
        Button {
            task?.cancel(); player?.pause(); preparing = true
            let (request, previous) = playback.begin(); requestID = request
            let nextTask = Task { @MainActor in
                defer { preparing = false }
                do {
                    // Wait for the previous sentence's synthesis to release the shared voice
                    // before starting another one. Cancelling its AVPlayer alone is too late.
                    await previous?.value
                    try Task.checkCancellation()
                    let url: URL
                    if let original = example.mediaURL { url = original }
                    else {
                        let asset = try await model.preparedAudio(for: example)
                        try Task.checkCancellation()
                        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
                        url = FileManager.default.temporaryDirectory.appendingPathComponent("context-preview-\(UUID()).caf")
                        try asset.data.write(to: url); temporaryURL = url
                    }
                    let item = AVPlayerItem(url: url)
                    if let end = example.clipEnd { item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600) }
                    let next = AVPlayer(playerItem: item)
                    if let start = example.clipStart { await next.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
                    try Task.checkCancellation(); player = next; playback.attach(next, request: request)
                } catch { if !Task.isCancelled { model.report(error) } }
            }
            task = nextTask; playback.track(nextTask, request: request)
        } label: {
            Label(preparing ? "Preparing…" : (example.mediaKind == .video ? "Play Video" : "Play"), systemImage: "play.fill")
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .disabled(preparing || (example.mediaURL == nil && model.speechAvailability(for: example) != .available))
        .accessibilityLabel("Play \(example.mediaKind == .video ? "video" : "sentence"): \(example.sentence)")
    }
}

