import AVFoundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

struct SavedResponsesView: View {
    @State private var model: SavedResponsesFeatureModel
    @State private var player = SavedResponsePlayer()
    @State private var responseToDelete: StudyResponse?

    init(library: any LibraryStudyResponses) {
        _model = State(initialValue: SavedResponsesFeatureModel(library: library))
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Loading recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(error):
                ContentUnavailableView {
                    Label("Could Not Load Recordings", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .ready where model.responses.isEmpty:
                ContentUnavailableView(
                    "No Recordings Yet",
                    systemImage: "waveform",
                    description: Text("Spoken responses you save while studying will appear here.")
                )
            case .ready:
                List(model.responses) { response in
                    responseRow(response)
                }
                .listStyle(.inset)
                .refreshable { await model.reload() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.detailBackground)
        .navigationTitle("Recordings")
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.reload() }
                }
                .disabled(model.loadState == .loading)
                .help("Reload recordings")
                .accessibilityIdentifier("refreshRecordings")
            }
        }
        .task { await model.load() }
        .onDisappear { player.stop() }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { responseToDelete != nil },
                set: { if !$0 { responseToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                guard let response = responseToDelete else { return }
                player.stop()
                Task { await model.delete(response) }
                responseToDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording will be permanently removed. The source card will remain suspended.")
        }
        .alert("Could Not Play Recording", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "The recording could not be played.")
        }
    }

    private var navigationSubtitle: String {
        switch model.loadState {
        case .ready:
            let count = model.responses.count
            let noun = count == 1 ? "recording" : "recordings"
            return "\(count) \(noun) · Stored only on this Mac"
        case .loading, .failed:
            return "Stored only on this Mac"
        }
    }

    private func responseRow(_ response: StudyResponse) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Button {
                play(response)
            } label: {
                Image(systemName: player.playingID == response.id ? "stop.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.playingID == response.id ? "Stop recording" : "Play recording")
            .accessibilityHint("Plays the spoken response")
            .help(player.playingID == response.id ? "Stop" : "Play")

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                Text(response.sourceTitle.isEmpty ? "Untitled source" : response.sourceTitle)
                    .font(DesignSystem.Typography.uiBody.weight(.medium))
                    .lineLimit(1)
                Text(response.submittedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(DesignSystem.Typography.uiRowMeta)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(duration(response.durationMilliseconds))
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if model.deletingIDs.contains(response.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Deleting recording")
            } else {
                Menu {
                    Button("Delete Recording", systemImage: "trash", role: .destructive) {
                        responseToDelete = response
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More actions for recording")
                .help("More actions")
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func play(_ response: StudyResponse) {
        Task {
            do {
                let data = try await model.audioData(for: response)
                try player.toggle(response: response, data: data)
            } catch {
                player.errorMessage = error.localizedDescription
            }
        }
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
