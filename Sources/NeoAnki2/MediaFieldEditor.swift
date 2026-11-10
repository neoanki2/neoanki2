import AppKit
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI
import UniformTypeIdentifiers

enum MediaFieldPolicy {
    static func descriptionLabel(for kind: MediaKind) -> String {
        [.image, .gif].contains(kind) ? "Image description (optional)" : "Description (optional)"
    }

    static func allowedContentTypes(for kind: MediaKind) -> [UTType] {
        if kind == .image { return [.image] }
        return allowedFilenameExtensions(for: kind).compactMap {
            UTType(filenameExtension: $0)
        }
    }

    static func allowedFilenameExtensions(for kind: MediaKind) -> [String] {
        switch kind {
        case .audio: ["m4a", "mp3", "wav", "aac", "caf"]
        case .image: ["png", "jpg", "jpeg", "heic", "tiff", "webp"]
        case .gif: ["gif"]
        case .video: ["mp4", "mov", "m4v"]
        }
    }
}

struct MediaFieldEditor: View {
    let label: String
    let kind: MediaKind
    @Binding var media: MediaRef?
    @Binding var altText: String
    let mediaStore: MediaStore?
    let accessibilityIdentifier: String

    @State private var isImporting = false
    @State private var isActive = true
    @State private var importTask: Task<Void, Never>?
    @State private var pasteProcessing = 0
    @Environment(\.attachmentProcessing) private var otherAttachmentProcessing
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
                .disabled(isImporting || pasteProcessing > 0 || mediaStore == nil)
                .accessibilityIdentifier("\(accessibilityIdentifier)-chooseFile")

                if kind == .image {
                    ImageAttachmentPasteButton { result in
                        do { try await attach(try result.get()) }
                        catch { errorMessage = UserFacingError.message(from: error) }
                    }
                    .onPreferenceChange(AttachmentProcessingPreferenceKey.self) { pasteProcessing = $0 }
                    .disabled(isImporting || mediaStore == nil)
                }
                if isImporting { ProgressView("Preparing attachment…") }

                if media != nil {
                    Button("Remove", role: .destructive) {
                        media = nil
                        altText = ""
                        fileName = ""
                    }
                    .accessibilityIdentifier("\(accessibilityIdentifier)-removeFile")
                    .disabled(isImporting || pasteProcessing > 0)
                }

                Spacer()

                if !fileName.isEmpty {
                    Text(fileName)
                        .font(DesignSystem.Typography.uiCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TextField(descriptionLabel, text: $altText)
                .accessibilityIdentifier("\(accessibilityIdentifier)-altText")

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }
        }
        .disabled(otherAttachmentProcessing && !isImporting && pasteProcessing == 0)
        .preference(key: AttachmentProcessingPreferenceKey.self, value: (isImporting ? 1 : 0) + pasteProcessing)
        .onAppear { isActive = true }
        .onDisappear { isActive = false; importTask?.cancel() }
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

    private var descriptionLabel: String {
        MediaFieldPolicy.descriptionLabel(for: kind)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MediaFieldPolicy.allowedContentTypes(for: kind)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTask?.cancel()
        importTask = Task { await ingest(url: url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isImporting, pasteProcessing == 0, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                guard isActive, !isImporting, !otherAttachmentProcessing else { return }
                importTask?.cancel()
                importTask = Task { await ingest(url: url) }
            }
        }
        return true
    }

    @MainActor
    private func ingest(url: URL) async {
        guard let mediaStore else {
            errorMessage = "Media storage is unavailable."
            return
        }
        guard !isImporting, isActive else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            if kind == .image {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await attach(try await AttachmentImagePreparer.prepare(url: url))
                return
            }
            let trimmedAlt = altText.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = try await mediaStore.ingest(
                url: url,
                kind: kind,
                altText: trimmedAlt.isEmpty ? nil : trimmedAlt
            )
            guard isActive, !Task.isCancelled else { try? await mediaStore.discardDraftReference(ref); return }
            media = ref
            fileName = url.lastPathComponent
        } catch {
            if isActive, !Task.isCancelled { errorMessage = UserFacingError.message(from: error) }
        }
    }
    @MainActor
    private func attach(_ image: PreparedAttachmentImage) async throws {
        guard let mediaStore, isActive, !Task.isCancelled else { return }
        let description = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = try await mediaStore.ingest(data: image.data, kind: .image,
            fileExtension: image.fileExtension, altText: description.isEmpty ? nil : description)
        guard isActive, !Task.isCancelled else { try? await mediaStore.discardDraftReference(ref); return }
        var updated = ref
        let latestDescription = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.altText = latestDescription.isEmpty ? nil : latestDescription
        media = updated
        fileName = "Image.\(image.fileExtension)"
        errorMessage = nil
    }
}

struct MediaPreviewView: View {
    let ref: MediaRef
    let store: MediaStore

    @State private var resolvedURL: URL?
    @State private var resolutionError: String?
    @State private var loadedImage: NSImage?
    @State private var imageLoadFailed = false

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
            loadedImage = nil
            imageLoadFailed = false
            do {
                let url = try await store.resolve(ref)
                guard !Task.isCancelled else { return }
                resolvedURL = url
            } catch {
                guard !Task.isCancelled else { return }
                resolutionError = UserFacingError.message(from: error)
            }
        }
        .task(id: resolvedURL) {
            guard let resolvedURL, [.image, .gif].contains(ref.kind) else { return }
            let image = await MediaImageLoader.shared.image(
                for: resolvedURL,
                kind: ref.kind,
                maxPixelSize: 640
            )
            guard !Task.isCancelled else { return }
            loadedImage = image
            imageLoadFailed = image == nil
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch ref.kind {
        case .audio:
            Label(ref.altText ?? "Audio clip", systemImage: "waveform")
                .font(DesignSystem.Typography.uiSecondary)
        case .image, .gif:
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .accessibilityLabel(ref.altText ?? "Image")
            } else if imageLoadFailed {
                Label("Image preview unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(DesignSystem.Typography.uiSecondary)
                    .foregroundStyle(.secondary)
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
