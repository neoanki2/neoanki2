import CoreTransferable
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI
import UniformTypeIdentifiers

/// Prepares the received file before its provider-owned lifetime ends.
public struct ImportedAttachmentImage: Transferable, Sendable {
    public let image: PreparedAttachmentImage

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(image: try await AttachmentImagePreparer.prepare(url: received.file))
        }
    }
}

private struct AttachmentProcessingEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var attachmentProcessing: Bool {
        get { self[AttachmentProcessingEnvironmentKey.self] }
        set { self[AttachmentProcessingEnvironmentKey.self] = newValue }
    }
}

public struct AttachmentProcessingPreferenceKey: PreferenceKey {
    public static let defaultValue = 0
    public static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

public enum ImageAttachmentTransfer {
    @MainActor public static func prepare(provider: NSItemProvider) async throws -> PreparedAttachmentImage {
        try await prepare(provider: provider, temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    @MainActor static func prepare(provider: NSItemProvider, temporaryDirectory: URL) async throws -> PreparedAttachmentImage {
        try Task.checkCancellation()
        let types = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: .image) == true }
        var lastError: Error = MediaError.unsupportedFormat(.image)
        for type in types {
            do {
                return try await prepareRepresentation(provider: provider, type: type, directory: temporaryDirectory)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    @MainActor private static func prepareRepresentation(provider: NSItemProvider, type: String, directory: URL) async throws -> PreparedAttachmentImage {
        if let file = try? await temporaryFile(provider: provider, type: type, directory: directory) {
            defer { try? FileManager.default.removeItem(at: file) }
            return try await AttachmentImagePreparer.prepare(url: file)
        }
        // Clipboard providers may offer only an in-memory representation.
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? MediaError.readFailed) }
            }
        }
        try Task.checkCancellation()
        return try await AttachmentImagePreparer.prepare(data: data)
    }
    @MainActor private static func temporaryFile(provider: NSItemProvider, type: String, directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { continuation.resume(throwing: error ?? MediaError.readFailed); return }
                let temporary = directory.appendingPathComponent("attachment-\(UUID())")
                do {
                    try FileManager.default.copyItem(at: url, to: temporary)
                    continuation.resume(returning: temporary)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public struct ImageAttachmentPasteButton: View {
    private let receive: @MainActor (Result<PreparedAttachmentImage, Error>) async -> Void
    @State private var task: Task<Void, Never>?
    @State private var processing = false
    @Environment(\.attachmentProcessing) private var otherAttachmentProcessing

    public init(receive: @escaping @MainActor (Result<PreparedAttachmentImage, Error>) async -> Void) {
        self.receive = receive
    }

    public var body: some View {
        HStack {
            PasteButton(supportedContentTypes: [.image]) { providers in
                guard !processing, let provider = providers.first else { return }
                processing = true
                task = Task { @MainActor in
                    defer { processing = false }
                    do {
                        let image = try await ImageAttachmentTransfer.prepare(provider: provider)
                        try Task.checkCancellation()
                        await receive(.success(image))
                    } catch {
                        if !Task.isCancelled { await receive(.failure(error)) }
                    }
                }
            }
            .disabled(processing || otherAttachmentProcessing)
            .accessibilityLabel("Paste image")
            if processing { ProgressView("Preparing image…") }
        }
        .preference(key: AttachmentProcessingPreferenceKey.self, value: processing ? 1 : 0)
        .onDisappear { task?.cancel() }
    }
}
