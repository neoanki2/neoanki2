import AppKit
import NeoAnkiCore
import SwiftUI
import UniformTypeIdentifiers

struct MediaFieldEditor: View {
    let label: String
    let kind: MediaKind
    @Binding var media: MediaRef?
    @Binding var altText: String
    let mediaStore: MediaStore?
    let accessibilityIdentifier: String

    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var fileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(DesignSystem.Typography.uiSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: media == nil ? [6] : []))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .frame(minHeight: 88)

                if let media, let store = mediaStore {
                    MediaPreviewView(ref: media, store: store)
                        .frame(maxHeight: 160)
                } else {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: iconName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Drop a file or choose…")
                            .font(DesignSystem.Typography.uiHint)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            HStack {
                Button("Choose File…") {
                    chooseFile()
                }
                .disabled(isImporting || mediaStore == nil)

                if media != nil {
                    Button("Remove", role: .destructive) {
                        media = nil
                        fileName = ""
                    }
                }

                Spacer()

                if !fileName.isEmpty {
                    Text(fileName)
                        .font(DesignSystem.Typography.uiCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TextField("Alt text (optional)", text: $altText)
                .accessibilityIdentifier("\(accessibilityIdentifier)-altText")

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var iconName: String {
        switch kind {
        case .audio: "waveform"
        case .image: "photo"
        case .gif: "photo.stack"
        case .video: "film"
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await ingest(url: url) }
    }

    private var allowedTypes: [UTType] {
        switch kind {
        case .audio: [.mpeg4Audio, .mp3, .wav, .aiff]
        case .image: [.png, .jpeg, .heic, .tiff, .webP]
        case .gif: [.gif]
        case .video: [.mpeg4Movie, .quickTimeMovie]
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { await ingest(url: url) }
        }
        return true
    }

    @MainActor
    private func ingest(url: URL) async {
        guard let mediaStore else {
            errorMessage = "Media storage is unavailable."
            return
        }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            let trimmedAlt = altText.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = try await mediaStore.ingest(
                url: url,
                kind: kind,
                altText: trimmedAlt.isEmpty ? nil : trimmedAlt
            )
            media = ref
            fileName = url.lastPathComponent
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
    }
}

struct MediaPreviewView: View {
    let ref: MediaRef
    let store: MediaStore

    @State private var resolvedURL: URL?
    @State private var resolutionError: String?

    var body: some View {
        Group {
            if let resolutionError {
                ErrorBanner(message: resolutionError)
            } else {
                mediaContent
            }
        }
        .task(id: ref.id) {
            resolvedURL = nil
            resolutionError = nil
            do {
                resolvedURL = try await store.resolve(ref)
            } catch {
                resolutionError = UserFacingError.message(from: error)
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch ref.kind {
        case .audio:
            Label(ref.altText ?? "Audio clip", systemImage: "waveform")
                .font(DesignSystem.Typography.uiSecondary)
        case .image, .gif:
            if let resolvedURL, let image = NSImage(contentsOf: resolvedURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .accessibilityLabel(ref.altText ?? "Image")
            } else {
                ProgressView()
                    .accessibilityLabel("Loading image preview")
            }
        case .video:
            Label(ref.altText ?? "Video clip", systemImage: "film")
                .font(DesignSystem.Typography.uiSecondary)
        }
    }
}
