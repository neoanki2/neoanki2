import AVFoundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

struct SavedResponsesView: View {
    @State private var model: SavedResponsesFeatureModel
    @State private var player = SavedResponsePlayer()
    @State private var responseToDelete: StudyResponse?
    let onDone: () -> Void

    init(library: any LibraryStudyResponses, onDone: @escaping () -> Void) {
        _model = State(initialValue: SavedResponsesFeatureModel(library: library))
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.loadState {
                case .loading:
                    ProgressView("Loading saved responses…")
                case let .failed(error):
                    ContentUnavailableView {
                        Label("Could Not Load Responses", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.message)
                    } actions: {
                        Button("Try Again") { Task { await model.load() } }
                            .buttonStyle(.borderedProminent)
                    }
                case .ready where model.responses.isEmpty:
                    ContentUnavailableView(
                        "No Saved Responses",
                        systemImage: "waveform",
                        description: Text("Audio Submission responses you save while studying will appear here.")
                    )
                case .ready:
                    List(model.responses) { response in
                        responseRow(response)
                    }
                    .refreshable { await model.reload() }
                }
            }
            .navigationTitle("Saved Responses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .task { await model.load() }
        .onDisappear { player.stop() }
        .confirmationDialog(
            "Delete this saved response?",
            isPresented: Binding(
                get: { responseToDelete != nil },
                set: { if !$0 { responseToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Response", role: .destructive) {
                guard let response = responseToDelete else { return }
                player.stop()
                Task { await model.delete(response) }
                responseToDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording will be permanently removed. Its card will remain suspended.")
        }
        .alert("Could Not Play Response", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "The recording could not be played.")
        }
    }

    private func responseRow(_ response: StudyResponse) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                Text(response.sourceTitle.isEmpty ? "Untitled source" : response.sourceTitle)
                    .font(DesignSystem.Typography.uiRowTitle)
                Text("\(response.submittedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(response.durationMilliseconds))")
                    .font(DesignSystem.Typography.uiRowMeta)
                    .foregroundStyle(.secondary)
                Text("Saved locally · Not synced")
                    .font(DesignSystem.Typography.uiHint)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task {
                    do {
                        let data = try await model.audioData(for: response)
                        try player.toggle(response: response, data: data)
                    }
                    catch { player.errorMessage = error.localizedDescription }
                }
            } label: {
                Label(player.playingID == response.id ? "Stop" : "Play", systemImage: player.playingID == response.id ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Plays the saved spoken response")
            Button("Delete", systemImage: "trash", role: .destructive) {
                responseToDelete = response
            }
            .disabled(model.deletingIDs.contains(response.id))
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor @Observable
private final class SavedResponsePlayer: NSObject, AVAudioPlayerDelegate {
    var playingID: UUID?
    var errorMessage: String?
    private var audioPlayer: AVAudioPlayer?

    func toggle(response: StudyResponse, data: Data) throws {
        if playingID == response.id { stop(); return }
        stop()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { throw CocoaError(.fileReadUnknown) }
        audioPlayer = player
        playingID = response.id
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
