#if os(iOS)
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI

struct SavedResponsesMobileView: View {
    @State private var model: SavedResponsesFeatureModel
    @State private var player = SavedResponsePlayer()
    @State private var responseToDelete: StudyResponse?

    init(model: SavedResponsesFeatureModel) { _model = State(initialValue: model) }

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
                        .buttonStyle(.borderedProminent).neoAnkiMobilePrimaryActionTint()
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
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                Task { await player.toggle(id: response.id) { try await model.audioData(for: response) } }
                            } label: {
                                AudioPlaybackLabel(isPlaying: player.playingID == response.id, activeAction: .stop,
                                                   playTitle: "Play Recording", activeTitle: "Stop Recording")
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button(role: .destructive) {
                                responseToDelete = response
                            } label: { Label("Delete", systemImage: "trash").frame(minHeight: 44) }
                            .buttonStyle(.borderless)
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
#endif
