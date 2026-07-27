import Foundation
import SwiftUI

public struct DeckBuilderDescriptor: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String

    public init(id: String, title: String, subtitle: String, systemImage: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }
}

public struct GeneratedDeckBundle: Sendable {
    public let bundleURL: URL
    private let cleanupOperation: @Sendable () -> Void

    public init(bundleURL: URL, cleanup: @escaping @Sendable () -> Void) {
        self.bundleURL = bundleURL
        cleanupOperation = cleanup
    }

    public func cleanup() {
        cleanupOperation()
    }
}

public protocol DeckBuildWorkspaceProviding: Sendable {
    func makeWorkspace() throws -> GeneratedDeckBundle
}

public struct SystemDeckBuildWorkspaceProvider: DeckBuildWorkspaceProviding {
    public init() {}

    public func makeWorkspace() throws -> GeneratedDeckBundle {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-deck-builder-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("Generated.neoanki", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
        return GeneratedDeckBundle(bundleURL: bundleURL) {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}

@MainActor
public struct AnyDeckBuilderFeature: Identifiable {
    public let descriptor: DeckBuilderDescriptor
    private let makeViewOperation: (
        @escaping @MainActor (GeneratedDeckBundle) -> Void,
        @escaping @MainActor () -> Void
    ) -> AnyView

    public nonisolated var id: String { descriptor.id }

    public init<Content: View>(
        descriptor: DeckBuilderDescriptor,
        @ViewBuilder makeView: @escaping (
            @escaping @MainActor (GeneratedDeckBundle) -> Void,
            @escaping @MainActor () -> Void
        ) -> Content
    ) {
        self.descriptor = descriptor
        makeViewOperation = { onGenerated, onCancel in
            AnyView(makeView(onGenerated, onCancel))
        }
    }

    public func makeView(
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) -> AnyView {
        makeViewOperation(onGenerated, onCancel)
    }
}

@MainActor
public struct DeckBuilderRegistry {
    public let features: [AnyDeckBuilderFeature]

    public init(_ features: [AnyDeckBuilderFeature]) {
        self.features = features
    }

    public func feature(id: String) -> AnyDeckBuilderFeature? {
        features.first { $0.id == id }
    }
}
