import Foundation
import NeoAnkiCore

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

    public func cleanup() { cleanupOperation() }
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

/// A validated native creation and its stable operation identity. Retain this
/// value while recovering an uncertain result; generating again is a new action.
public struct GeneratedDeckCreation: Sendable {
    public let prepared: PreparedAuthoredDeck
    public let parentDeckID: UUID
    public let command: NativeCommandContext
    public init(prepared: PreparedAuthoredDeck, parentDeckID: UUID) {
        self.prepared = prepared; self.parentDeckID = parentDeckID
        command = NativeCommandContext(operation: "create-generated-deck",
            input: Data((prepared.contentHash + ":" + parentDeckID.uuidString).utf8),
            expectedCount: prepared.itemCount)
    }
    public func materialize(using provider: any DeckBuildWorkspaceProviding) throws -> GeneratedDeckBundle {
        let workspace = try provider.makeWorkspace()
        do {
            try AuthoredDeck.write(prepared, to: workspace.bundleURL)
            return workspace.placed(under: parentDeckID)
        } catch { workspace.cleanup(); throw error }
    }
    public static func preparing(_ operation: @escaping @Sendable () throws -> Self) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
}
