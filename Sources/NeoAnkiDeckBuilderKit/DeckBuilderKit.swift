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

public struct DeckBuilderDeckOption: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DeckBuilderHostContext: Sendable, Equatable {
    public let rootDecks: [DeckBuilderDeckOption]

    public init(rootDecks: [DeckBuilderDeckOption]) {
        self.rootDecks = rootDecks
    }
}

public struct GeneratedDeckBundle: Sendable {
    public let bundleURL: URL
    public let destinationDeckID: UUID?
    private let cleanupOperation: @Sendable () -> Void

    public init(
        bundleURL: URL,
        destinationDeckID: UUID? = nil,
        cleanup: @escaping @Sendable () -> Void
    ) {
        self.bundleURL = bundleURL
        self.destinationDeckID = destinationDeckID
        cleanupOperation = cleanup
    }

    public func placed(under destinationDeckID: UUID) -> GeneratedDeckBundle {
        GeneratedDeckBundle(
            bundleURL: bundleURL,
            destinationDeckID: destinationDeckID,
            cleanup: cleanupOperation
        )
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
        DeckBuilderHostContext,
        @escaping @MainActor (GeneratedDeckBundle) -> Void,
        @escaping @MainActor () -> Void
    ) -> AnyView

    public nonisolated var id: String { descriptor.id }

    public init<Content: View>(
        descriptor: DeckBuilderDescriptor,
        @ViewBuilder makeView: @escaping (
            DeckBuilderHostContext,
            @escaping @MainActor (GeneratedDeckBundle) -> Void,
            @escaping @MainActor () -> Void
        ) -> Content
    ) {
        self.descriptor = descriptor
        makeViewOperation = { context, onGenerated, onCancel in
            AnyView(makeView(context, onGenerated, onCancel))
        }
    }

    public func makeView(
        context: DeckBuilderHostContext,
        onGenerated: @escaping @MainActor (GeneratedDeckBundle) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) -> AnyView {
        makeViewOperation(context, onGenerated, onCancel)
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
