#if os(iOS)
import AVFoundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

struct SavedResponsesMobileView: View {
    @State private var model: SavedResponsesFeatureModel
    @State private var player = MobileSavedResponsePlayer()
    @State private var responseToDelete: StudyResponse?

    init(library: any LibraryStudyResponses) {
        _model = State(initialValue: SavedResponsesFeatureModel(library: library))
    }

    var body: some View {
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
                        .controlSize(.large)
                }
            case .ready where model.responses.isEmpty:
                ContentUnavailableView(
                    "No Saved Responses",
                    systemImage: "waveform",
                    description: Text("Audio Submission responses you save while studying will appear here.")
                )
            case .ready:
                List(model.responses) { response in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(response.sourceTitle.isEmpty ? "Untitled source" : response.sourceTitle)
                            .font(.headline)
                        Text("\(response.submittedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(response.durationMilliseconds))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Saved locally · Not synced")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    do {
                                        let data = try await model.audioData(for: response)
                                        try player.toggle(response: response, data: data)
                                    } catch {
                                        player.errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label(
                                    player.playingID == response.id ? "Stop" : "Play",
                                    systemImage: player.playingID == response.id ? "stop.fill" : "play.fill"
                                )
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                responseToDelete = response
                            }
                            .frame(minHeight: 44)
                            .disabled(model.deletingIDs.contains(response.id))
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                }
                .refreshable { await model.reload() }
            }
        }
        .navigationTitle("Saved Responses")
        .navigationBarTitleDisplayMode(.inline)
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

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor @Observable
private final class MobileSavedResponsePlayer: NSObject, AVAudioPlayerDelegate {
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
#endif
