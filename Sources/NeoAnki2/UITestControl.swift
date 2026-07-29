import Foundation

#if DEBUG
enum UITestRoute: String, Codable, Sendable {
    case library
    case browse
    case addItem
    case templates
    case study
    case importSheet
}

struct UITestRuntimeConfiguration: Codable, Equatable, Sendable {
    let sequence: Int
    let databaseDirectory: String
    let scenario: String?
    let initialRoute: UITestRoute
    let environment: [String: String]
}
enum UITestScenario: String, Codable, Sendable {
    case studyType = "study-type"
    case studyChoose = "study-choose"
    case studyArrange = "study-arrange"
    case studyRecord = "study-record"
    case studyCloze = "study-cloze"
    case studyReverse = "study-reverse"
    case studyEdit = "study-edit"
    case libraryBrowse = "library-browse"
    case schedulingHistory = "scheduling-history"
    case imageMissingDescription = "image-missing-description"
    case deckWithDueItems = "deck-with-due-items"
    case deckScoping = "deck-scoping"
    case portableExportSource = "portable-export-source"
    case typeConflictLocal = "type-conflict-local"
    case corruptedItemType = "corrupted-item-type"
    case importWithMedia = "import-with-media"
    case alternateImportType = "alternate-import-type"
    case authoringFields = "authoring-fields"
}

struct UITestCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case reset
        case openImport
        case openPortableImport
        case setPortableBusy
    }

    let sessionID: String
    let sequence: Int
    let action: Action
    let databaseDirectory: String
    let scenario: UITestScenario?
    let initialRoute: UITestRoute
    let path: String?
    let enabled: Bool?
    let environment: [String: String]
}

struct UITestAcknowledgement: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case ready
        case failed
    }

    let sessionID: String
    let sequence: Int
    let state: State
    let scenario: UITestScenario?
    let route: UITestRoute
    let message: String?
}

@MainActor
final class UITestControlMonitor {
    typealias Handler = @MainActor (UITestCommand) async -> UITestAcknowledgement

    private var observer: NSObjectProtocol?
    private var handler: Handler?
    private var directory: URL?
    private var sessionID: String?
    private var lastSequence = 0

    func start(handler: @escaping Handler) {
        guard AppDatabase.isTesting,
              observer == nil,
              let directoryPath = ProcessInfo.processInfo.environment["NEOANKI_TEST_CONTROL_DIR"],
              let sessionID = ProcessInfo.processInfo.environment["NEOANKI_TEST_SESSION_ID"],
              !directoryPath.isEmpty,
              !sessionID.isEmpty
        else {
            return
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.directory = directory
        self.sessionID = sessionID
        self.handler = handler

        // The XCTest process intentionally keeps one session ID while genuine
        // launch-contract checks replace the app process. Do not replay the
        // preceding process's already-acknowledged command on a fresh launch.
        // Reading the ack (rather than merely the command) still lets the
        // startup task recover a command written while the observer installs.
        let acknowledgementURL = directory.appendingPathComponent("ack-\(sessionID).json")
        if let data = try? Data(contentsOf: acknowledgementURL),
           let acknowledgement = try? JSONDecoder().decode(
               UITestAcknowledgement.self,
               from: data
           ),
           acknowledgement.sessionID == sessionID {
            lastSequence = acknowledgement.sequence
        }

        let name = Notification.Name("com.neoanki2.uitest.command.\(sessionID)")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processPendingCommand()
            }
        }

        Task { @MainActor [weak self] in
            await self?.processPendingCommand()
        }
    }

    private func processPendingCommand() async {
        guard let directory, let sessionID, let handler else { return }
        let commandURL = directory.appendingPathComponent("command-\(sessionID).json")

        do {
            let command = try JSONDecoder().decode(
                UITestCommand.self,
                from: Data(contentsOf: commandURL)
            )
            guard command.sessionID == sessionID, command.sequence > lastSequence else { return }
            lastSequence = command.sequence
            let acknowledgement = await handler(command)
            let acknowledgementURL = directory
                .appendingPathComponent("ack-\(sessionID).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(acknowledgement)
            try data.write(to: acknowledgementURL, options: .atomic)
            try data.write(
                to: directory.appendingPathComponent("last-ack.json"),
                options: .atomic
            )
        } catch {
            // A command may be observed between the atomic rename and metadata
            // propagation. The test runner re-posts while waiting for its ack.
        }
    }
}
#endif
