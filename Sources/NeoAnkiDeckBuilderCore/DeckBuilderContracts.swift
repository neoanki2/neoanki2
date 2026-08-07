import Foundation

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
