import CryptoKit
@preconcurrency import XCTest

@MainActor
class NeoAnkiUITestCase: XCTestCase {
    private struct ControlCommand: Codable {
        let sessionID: String
        let sequence: Int
        let action: String
        let databaseDirectory: String
        let scenario: String?
        let initialRoute: String
        let path: String?
        let enabled: Bool?
        let environment: [String: String]
    }

    private struct ControlAcknowledgement: Codable {
        let sessionID: String
        let sequence: Int
        let state: String
        let scenario: String?
        let route: String
        let message: String?
    }

    private static var sharedApp: XCUIApplication?
    private static var controlSequence = 0
    private static var launchedDatabaseDirectories = Set<String>()
    private static let controlSessionID = UUID().uuidString
    private static let controlDirectory: URL = {
        if let configured = ProcessInfo.processInfo.environment["NEOANKI_UI_DIAGNOSTIC_DIR"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki2-ui-control-\(controlSessionID)", isDirectory: true)
    }()

    var runningApp: XCUIApplication?
    private var teardownRegistered = false

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    func launchApp(
        databaseLabel: String = UUID().uuidString,
        scenario: String? = nil,
        environment: [String: String] = [:],
        waitForLibrary: Bool = true
    ) -> XCUIApplication {
        let databaseDirectory = NSTemporaryDirectory() + "neoanki2-ui-\(databaseLabel)"
        // Import and portable-import fixtures are one-shot startup actions.
        // Reusing the app can acknowledge the reset after bootstrap but before
        // SwiftUI starts the replacement ContentView's transfer task, leaving
        // the test on an empty library with no import ever attempted.
        let requiresFreshTransferLaunch = environment["NEOANKI_TEST_IMPORT_PATH"] != nil
            || environment["NEOANKI_TEST_PORTABLE_IMPORT_PATH"] != nil
        let requiresLaunch = Self.sharedApp == nil
            || Self.sharedApp?.state == .notRunning
            || environment["NEOANKI_TEST_BOOTSTRAP_FAILURE"] == "1"
            || requiresFreshTransferLaunch
        let app: XCUIApplication

        if requiresLaunch {
            if let previousApp = Self.sharedApp {
                previousApp.terminate()
                _ = waitUntil(timeout: 3) { previousApp.state == .notRunning }
                Self.sharedApp = nil
            }
            if Self.launchedDatabaseDirectories.insert(databaseDirectory).inserted {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: databaseDirectory, isDirectory: true)
                )
            }
            app = XCUIApplication()
            app.launchArguments = ["-NeoAnkiTesting"]
            app.launchEnvironment["NEOANKI_TESTING"] = "1"
            app.launchEnvironment["NEOANKI_TEST_DB_DIR"] = databaseDirectory
            app.launchEnvironment["NEOANKI_TEST_CONTROL_DIR"] = Self.controlDirectory.path
            app.launchEnvironment["NEOANKI_TEST_SESSION_ID"] = Self.controlSessionID
            if ProcessInfo.processInfo.environment["DOC_SCREENSHOT_DIR"] != nil {
                app.launchEnvironment["NEOANKI_DOC_SCREENSHOTS"] = "1"
            }
            if let scenario {
                app.launchEnvironment["NEOANKI_TEST_SCENARIO"] = scenario
            }
            for (key, value) in environment {
                app.launchEnvironment[key] = value
            }
            if let bootstrapFailure = environment["NEOANKI_TEST_BOOTSTRAP_FAILURE"] {
                // macOS may reuse launch-services environment state after a
                // rapid terminate/relaunch, while launch arguments are always
                // applied to the new process.
                if bootstrapFailure == "1" {
                    app.launchArguments.append("-NeoAnkiBootstrapFailure")
                }
            }
            try? FileManager.default.createDirectory(
                at: Self.controlDirectory,
                withIntermediateDirectories: true
            )
            app.launch()
            Self.sharedApp = app
        } else {
            app = Self.sharedApp!
            resetRunningApp(
                app,
                databaseDirectory: databaseDirectory,
                scenario: scenario,
                environment: environment
            )
        }

        runningApp = app
        if !teardownRegistered {
            teardownRegistered = true
            addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            let app = self.runningApp
            if let failure = self.testRun?.failureCount, failure > 0, let app {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(self.name)-failure"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                self.attachControlArtifact(named: "last-command")
                self.attachControlArtifact(named: "last-ack")
            }
            app?.terminate()
            if let app {
                _ = self.waitUntil(timeout: 3) { app.state == .notRunning }
            }
            if Self.sharedApp === app {
                Self.sharedApp = nil
            }
            if self.runningApp === app {
                self.runningApp = nil
            }
            }
        }
        if waitForLibrary {
            waitForLibraryReady(in: app)
        }
        return app
    }

    private func resetRunningApp(
        _ app: XCUIApplication,
        databaseDirectory: String,
        scenario: String?,
        environment: [String: String]
    ) {
        Self.controlSequence += 1
        let sequence = Self.controlSequence
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: databaseDirectory, isDirectory: true)
        )

        var runtimeEnvironment = environment
        runtimeEnvironment["NEOANKI_TESTING"] = "1"
        let action: String
        if environment["NEOANKI_TEST_IMPORT_PATH"] != nil {
            action = "openImport"
        } else if environment["NEOANKI_TEST_PORTABLE_IMPORT_PATH"] != nil {
            action = "openPortableImport"
        } else if environment["NEOANKI_TEST_PORTABLE_BUSY"] == "1" {
            action = "setPortableBusy"
        } else {
            action = "reset"
        }
        let command = ControlCommand(
            sessionID: Self.controlSessionID,
            sequence: sequence,
            action: action,
            databaseDirectory: databaseDirectory,
            scenario: scenario,
            initialRoute: "library",
            path: environment["NEOANKI_TEST_IMPORT_PATH"]
                ?? environment["NEOANKI_TEST_PORTABLE_IMPORT_PATH"],
            enabled: environment["NEOANKI_TEST_PORTABLE_BUSY"].map { $0 == "1" },
            environment: runtimeEnvironment
        )
        deliver(command, to: app)
    }

    private func deliver(_ command: ControlCommand, to app: XCUIApplication) {
        let commandURL = Self.controlDirectory
            .appendingPathComponent("command-\(Self.controlSessionID).json")
        let acknowledgementURL = Self.controlDirectory
            .appendingPathComponent("ack-\(Self.controlSessionID).json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(command)
            try data.write(to: commandURL, options: .atomic)
            try data.write(
                to: Self.controlDirectory.appendingPathComponent("last-command.json"),
                options: .atomic
            )
        } catch {
            XCTFail("Could not send UI test reset command: \(error)")
            return
        }

        let notification = Notification.Name(
            "com.neoanki2.uitest.command.\(Self.controlSessionID)"
        )
        let deadline = Date().addingTimeInterval(15)
        var acknowledgement: ControlAcknowledgement?
        repeat {
            DistributedNotificationCenter.default().postNotificationName(
                notification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            if let data = try? Data(contentsOf: acknowledgementURL),
               let decoded = try? JSONDecoder().decode(ControlAcknowledgement.self, from: data),
               decoded.sessionID == Self.controlSessionID,
               decoded.sequence == command.sequence {
                acknowledgement = decoded
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        guard let acknowledgement else {
            XCTFail("UI test command \(command.sequence) was not acknowledged")
            return
        }
        XCTAssertEqual(
            acknowledgement.state,
            "ready",
            acknowledgement.message ?? "UI test reset failed"
        )
        app.activate()
    }

    func exportPortableDeckForTesting(to destination: URL, in app: XCUIApplication) {
        Self.controlSequence += 1
        deliver(
            ControlCommand(
                sessionID: Self.controlSessionID,
                sequence: Self.controlSequence,
                action: "exportPortable",
                databaseDirectory: "",
                scenario: nil,
                initialRoute: "library",
                path: destination.path,
                enabled: nil,
                environment: [:]
            ),
            to: app
        )
    }

    private func attachControlArtifact(named name: String) {
        let filename = name == "last-command"
            ? "command-\(Self.controlSessionID).json"
            : "ack-\(Self.controlSessionID).json"
        let url = Self.controlDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func captureDocumentationScreenshot(
        named name: String,
        of app: XCUIApplication,
        scenario: String,
        expectedVisibleIdentifiers: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let outputPath = ProcessInfo.processInfo.environment["DOC_SCREENSHOT_DIR"] else {
            XCTFail("DOC_SCREENSHOT_DIR must be set for documentation screenshot tests", file: file, line: line)
            return
        }
        guard !scenario.isEmpty, !expectedVisibleIdentifiers.isEmpty else {
            XCTFail("Screenshot scenario and expected identifiers must not be empty", file: file, line: line)
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        let captureContext: DocumentationScreenshotCaptureContext
        do {
            captureContext = try JSONDecoder().decode(
                DocumentationScreenshotCaptureContext.self,
                from: Data(contentsOf: outputDirectory.appendingPathComponent(".capture-context.json"))
            )
        } catch {
            XCTFail("Could not read documentation screenshot capture context: \(error)", file: file, line: line)
            return
        }

        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let appWindow = app.windows.firstMatch
        guard appWindow.waitUntilExists(timeout: 5) else {
            XCTFail("No app window available for documentation screenshot '\(name)'", file: file, line: line)
            return
        }
        guard appWindow.frame.width >= 1_024, appWindow.frame.height >= 674 else {
            XCTFail(
                "Documentation screenshot window is too small: \(appWindow.frame)",
                file: file,
                line: line
            )
            return
        }
        for identifier in expectedVisibleIdentifiers {
            let windowElement = appWindow.descendants(matching: .any).identified(identifier)
            let element = windowElement.waitUntilExists(timeout: 1)
                ? windowElement
                : app.descendants(matching: .any).identified(identifier)
            guard element.waitUntilExists(timeout: 2), !element.frame.isEmpty else {
                XCTFail(
                    "Expected '\(identifier)' to exist in documentation screenshot '\(name)'",
                    file: file,
                    line: line
                )
                return
            }
            let containerTypes: Set<XCUIElement.ElementType> = [
                .group, .other, .outline, .scrollView, .table,
            ]
            let isVisible = element.frame.intersects(appWindow.frame)
                && (containerTypes.contains(element.elementType)
                    || appWindow.frame.contains(element.frame))
            guard isVisible else {
                XCTFail(
                    "Expected '\(identifier)' to be fully visible in documentation screenshot '\(name)'",
                    file: file,
                    line: line
                )
                return
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let screenshot = appWindow.screenshot()
            let pngData = screenshot.pngRepresentation
            let dimensions = try pngDimensions(pngData)
            try pngData.write(
                to: outputDirectory.appendingPathComponent("\(name).png"),
                options: .atomic
            )
            try updateDocumentationScreenshotManifest(
                in: outputDirectory,
                entry: DocumentationScreenshotManifest.Entry(
                    filename: "\(name).png",
                    width: dimensions.width,
                    height: dimensions.height,
                    sha256: SHA256.hash(data: pngData)
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    scenario: scenario,
                    expectedVisibleIdentifiers: expectedVisibleIdentifiers
                ),
                sourceSHA: captureContext.sourceSHA,
                capturedAt: captureContext.capturedAt,
                appearance: captureContext.appearance
            )
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Could not write documentation screenshot '\(name)': \(error)", file: file, line: line)
        }
    }

    private struct DocumentationScreenshotManifest: Codable {
        struct Entry: Codable {
            let filename: String
            let width: Int
            let height: Int
            let sha256: String
            let scenario: String
            let expectedVisibleIdentifiers: [String]
        }

        let schemaVersion: Int
        let sourceSHA: String
        let capturedAt: String
        let appearance: String
        var screenshots: [Entry]
    }

    private struct DocumentationScreenshotCaptureContext: Codable {
        let sourceSHA: String
        let capturedAt: String
        let appearance: String
    }

    private func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            throw NSError(
                domain: "DocumentationScreenshot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screenshot is not a valid PNG"]
            )
        }
        func integer(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (integer(at: 16), integer(at: 20))
    }

    private func updateDocumentationScreenshotManifest(
        in directory: URL,
        entry: DocumentationScreenshotManifest.Entry,
        sourceSHA: String,
        capturedAt: String,
        appearance: String
    ) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = DocumentationScreenshotManifest(
            schemaVersion: 1,
            sourceSHA: sourceSHA,
            capturedAt: capturedAt,
            appearance: appearance,
            screenshots: []
        )
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(
                DocumentationScreenshotManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.sourceSHA == sourceSHA,
                  manifest.capturedAt == capturedAt,
                  manifest.appearance == appearance else {
                throw NSError(
                    domain: "DocumentationScreenshot",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Manifest capture metadata changed during the run"]
                )
            }
        }
        manifest.screenshots.removeAll { $0.filename == entry.filename }
        manifest.screenshots.append(entry)
        manifest.screenshots.sort { $0.filename < $1.filename }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func waitForLibraryReady(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let ready = waitUntil(timeout: timeout) { libraryIsReady(in: app) }
        XCTAssertTrue(ready, "Library did not finish loading within \(timeout)s")
    }

    func libraryIsReady(in app: XCUIApplication) -> Bool {
        if app.descendants(matching: .any)["libraryReady"].exists { return true }
        if app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["scopeHomeLoading", "itemBrowserLoading"])
        ).firstMatch.exists {
            return false
        }

        // Compatibility fallback for an older test build or the brief interval
        // before SwiftUI exposes the route-level readiness marker.
        // A loading placeholder means the window exists but has not settled.
        if app.staticTexts["Starting…"].exists || app.staticTexts["Loading items…"].exists
            || app.staticTexts["Loading decks…"].exists {
            return false
        }

        if app.buttons["deleteItem"].exists { return false }
        if app.buttons["primaryStudyAction"].exists || app.buttons["studySessionDone"].exists { return false }
        if app.buttons["saveAddItem"].exists || app.buttons["cancelAddItem"].exists { return false }
        if app.buttons["templatesDone"].exists { return false }

        if app.descendants(matching: .any)["emptyLibraryState"].exists { return true }
        if app.buttons["addItemEmptyState"].exists { return true }
        if app.buttons["addItemToolbar"].exists { return true }
        if app.descendants(matching: .any)["scopeHome"].exists { return true }
        if app.descendants(matching: .any)["itemBrowserTable"].exists { return true }
        if app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'itemRow-'")
        ).firstMatch.exists {
            return true
        }
        let emptyTitles = [
            "Nothing to Remember Yet",
            "No Unassigned Items",
            "No Items in This Deck",
        ]
        for title in emptyTitles {
            let label = NSPredicate(format: "label CONTAINS[c] %@", title)
            if app.descendants(matching: .any).matching(label).firstMatch.exists { return true }
        }
        return false
    }

    func assertEmptyLibrary(in app: XCUIApplication) {
        waitForLibraryReady(in: app)
        XCTAssertTrue(libraryIsReady(in: app))
    }

    func openTemplates(in app: XCUIApplication) {
        app.menuBarItems["Library"].click()
        app.menuItems.identified("Item Types…").click()

        XCTAssertNotNil(
            firstExisting(
                of: [app.buttons.identified("templatesDone"), app.buttons.identified("Done")],
                timeout: 5
            ),
            "Templates panel did not open"
        )
        waitForTemplatesReady(in: app)
    }

    func waitForTemplatesReady(in app: XCUIApplication, timeout: TimeInterval = 10) {
        let ready = waitUntil(timeout: timeout) {
            if app.staticTexts["Loading item types…"].exists { return false }
            return app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier IN %@",
                    ["templatesItemTypesHeader"]
                )
            ).firstMatch.exists
        }
        XCTAssertTrue(ready, "Templates panel did not finish loading within \(timeout)s")
    }

    func clickAddItemType(in app: XCUIApplication) {
        guard let control = firstExisting(
            of: [
                app.buttons.identified("addItemTypeToolbar"),
                app.buttons.identified("addItemTypeEmptyState"),
            ],
            timeout: 5
        ) else {
            XCTFail("Add item type control not found")
            return
        }
        control.click()
    }

    func openItemTypeStudio(named name: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any).identified("itemTypeRow-\(name)")
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        row.click()
        let edit = app.buttons.identified("editItemType")
        XCTAssertTrue(edit.waitUntilExists(timeout: 5))
        activateCompactButton(edit)
        let studioName = app.textFields.identified("itemTypeStudioName")
        if !studioName.waitUntilExists(timeout: 2) {
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        }
        XCTAssertTrue(studioName.waitUntilExists(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .identified("itemTypeStudioCardSetupEditor")
                .waitUntilExists(timeout: 10)
        )
    }

    /// Dismissing right after an edit can land while the panel is still
    /// settling, and a swallowed click leaves the panel open — which then reads
    /// as "the library never loaded". Retrying is what makes this reliable.
    func closeTemplates(in app: XCUIApplication) {
        let done = app.buttons.identified("templatesDone")
        for _ in 0..<4 {
            let labeledDone = app.buttons.identified("Done")
            if !done.exists, !labeledDone.exists { break }
            if done.exists, done.isHittable {
                done.click()
            } else if labeledDone.exists, labeledDone.isHittable {
                labeledDone.click()
            } else {
                // Both controls carry the cancel-action shortcut. Xcode 26.6
                // can expose a toolbar item before AppKit considers it
                // hittable, while Escape remains the supported user path.
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            }
            if done.waitUntilGone(timeout: 3) { break }
        }
        XCTAssertTrue(done.waitUntilGone(timeout: 5), "Item types panel did not close")
        waitForLibraryReady(in: app)
    }

    func enterText(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitUntilExists(timeout: 5))
        field.click()
        if field.value as? String != nil && !(field.value as? String ?? "").isEmpty {
            field.typeKey("a", modifierFlags: [.command])
        }
        field.typeText(text)
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
    }

    func saveAddItem(in app: XCUIApplication) {
        let save = app.buttons.identified("saveAddItem")
        XCTAssertTrue(save.waitUntilExists(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitUntilGone(timeout: 10))
    }

    /// Activates a visible compact icon control even when XCTest's AppKit
    /// bridge declines to mark its small accessibility frame as hittable.
    func activateCompactButton(_ button: XCUIElement) {
        XCTAssertTrue(button.waitUntilExists(timeout: 3))
        XCTAssertTrue(button.isEnabled)
        if button.waitUntilHittable(timeout: 1) {
            button.click()
        } else {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    /// Item rows live in browse mode, not on the scope home, so anything that
    /// asserts on a row has to get there first.
    func isBrowsing(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier IN %@",
                ["itemBrowserTable", "browseNoSearchResults", "browseDone"]
            )
        ).firstMatch.exists
    }

    func enterBrowseMode(in app: XCUIApplication, timeout: TimeInterval = 10) {
        if isBrowsing(in: app) { return }
        waitForLibraryReady(in: app)
        if isBrowsing(in: app) { return }

        let browse = app.buttons.identified("browseToolbar")
        if browse.waitUntilExists(timeout: 3), browse.isEnabled {
            browse.click()
        } else {
            app.typeKey("b", modifierFlags: [.command, .option])
        }

        XCTAssertTrue(
            waitUntil(timeout: timeout) { isBrowsing(in: app) },
            "Browse mode did not open within \(timeout)s"
        )
    }

    /// A click that lands while the view is still settling — right after a study
    /// session ends, for instance — gets swallowed, so one click is not proof
    /// that browse mode closed. Retrying is what makes this reliable rather than
    /// dependent on how long the preceding step happened to take.
    func leaveBrowseMode(in app: XCUIApplication) {
        guard isBrowsing(in: app) else { return }
        let done = app.buttons.identified("browseDone")

        for _ in 0..<4 {
            if done.exists, done.isHittable {
                done.click()
            } else {
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            }
            if waitUntil(timeout: 2, { !isBrowsing(in: app) }) {
                waitForLibraryReady(in: app)
                return
            }
        }
        XCTFail("Browse mode did not close")
    }

    func waitForItem(named title: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        enterBrowseMode(in: app, timeout: timeout)
        let row = app.descendants(matching: .any).identified("itemRow-\(title)")
        if row.waitUntilExists(timeout: timeout) {
            return
        }

        let labelPredicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let match = app.descendants(matching: .any).matching(labelPredicate).firstMatch
        XCTAssertTrue(match.waitUntilExists(timeout: 2))
    }

    /// A scope with no items cannot be browsed at all, which is itself proof the
    /// item is gone.
    func assertNoItem(
        named title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        returnToLibrary(in: app)
        let browse = app.buttons.identified("browseToolbar")
        if !isBrowsing(in: app), browse.exists, browse.isEnabled {
            enterBrowseMode(in: app)
        }
        XCTAssertFalse(
            app.descendants(matching: .any)["itemRow-\(title)"].exists,
            file: file,
            line: line
        )
    }

    /// The scope home replaces the old dead disabled Study button with the time
    /// the next card comes back, so "caught up" is an absence plus a sentence.
    func assertNothingDue(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        leaveBrowseMode(in: app)
        // The scope home renders its due summary a beat after the library
        // reports ready, so both halves of "caught up" have to be waited for.
        let nextDue = app.descendants(matching: .any)["scopeHomeNextDue"]
        let studyButton = app.buttons.identified("studyButton")
        let caughtUp = waitUntil(timeout: 10) {
            nextDue.exists && !studyButton.exists
        }
        XCTAssertTrue(
            caughtUp,
            """
            Expected the scope home to say when the next card is due \
            (nextDue=\(nextDue.exists), studyButton=\(studyButton.exists))
            """,
            file: file,
            line: line
        )
    }

    func assertDueCardsAvailable(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        leaveBrowseMode(in: app)
        let studyButton = app.buttons.identified("studyButton")
        XCTAssertTrue(studyButton.waitUntilExists(timeout: 10), file: file, line: line)
        XCTAssertTrue(studyButton.isEnabled, file: file, line: line)
    }

    /// A field renders as either a text view or a text field depending on its
    /// type, so both have to be considered — but probing them in sequence pays
    /// the first one's timeout in full whenever the answer is the second.
    func field(named name: String, in app: XCUIApplication) -> XCUIElement {
        let id = "field-\(name)"
        let candidates = [app.textViews.identified(id), app.textFields.identified(id)]
        return firstExisting(of: candidates, timeout: 3)
            ?? app.descendants(matching: .any)[id]
    }

    func closeItemDetail(in app: XCUIApplication) {
        let deleteButton = app.buttons.identified("deleteItem")
        guard deleteButton.waitUntilExists(timeout: 3) else { return }

        for _ in 0..<2 {
            let back = app.buttons.identified("itemDetailBack")
            XCTAssertTrue(back.waitUntilExists(timeout: 3), "Item detail Back button did not appear")
            guard back.exists else { return }
            back.click()
            if deleteButton.waitUntilGone(timeout: 3) { return }
        }

        XCTFail("Item detail did not close after two Back attempts")
    }

    func returnToLibrary(in app: XCUIApplication) {
        if app.buttons.identified("studySessionDone").exists {
            app.buttons.identified("studySessionDone").click()
        }
        if app.buttons.identified("studyBackToLibrary").exists {
            app.buttons.identified("studyBackToLibrary").click()
        }
        if app.buttons.identified("cancelAddItem").exists {
            app.buttons.identified("cancelAddItem").click()
        }
        if app.buttons.identified("cancelItemTypeStudio").exists {
            app.buttons.identified("cancelItemTypeStudio").click()
            if app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 1) {
                app.buttons.identified("confirmDiscardItemTypeStudio").click()
            }
        }
        if app.buttons.identified("templatesDone").exists {
            app.buttons.identified("templatesDone").click()
        }
        if isBrowsing(in: app) {
            leaveBrowseMode(in: app)
        }
        if app.buttons["deleteItem"].exists {
            if app.buttons.identified("itemDetailBack").exists {
                closeItemDetail(in: app)
            } else {
                showSidebar(in: app)
                let unassigned = app.descendants(matching: .any).identified("scopeRow-Unassigned")
                let allDecks = app.descendants(matching: .any).identified("scopeRow-AllDecks")
                if unassigned.waitUntilExists(timeout: 2), allDecks.waitUntilExists(timeout: 2) {
                    unassigned.click()
                    _ = app.buttons.identified("deleteItem").waitUntilGone(timeout: 5)
                    allDecks.click()
                } else {
                    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
                }
            }
            _ = app.buttons.identified("deleteItem").waitUntilGone(timeout: 5)
        }
        waitForLibraryReady(in: app)
    }

    func openAddItem(in app: XCUIApplication, waitForDefaultField: Bool = true) {
        returnToLibrary(in: app)
        guard let add = firstExisting(
            of: [
                app.buttons.identified("addItemEmptyState"),
                app.buttons.identified("addItemToolbar"),
            ],
            timeout: 5
        ) else {
            XCTFail("No control available to add an item")
            return
        }
        add.click()

        XCTAssertTrue(app.buttons.identified("cancelAddItem").waitUntilExists(timeout: 10))
        if waitForDefaultField {
            XCTAssertTrue(field(named: "Front", in: app).waitUntilExists(timeout: 10))
        }
    }

    func openItemEditor(in app: XCUIApplication) {
        let edit = app.buttons.identified("editItem")
        let save = app.buttons.identified("saveEditItem")
        let cancel = app.buttons.identified("cancelEditItem")
        XCTAssertTrue(edit.waitUntilHittable(timeout: 3))
        for _ in 0..<3 {
            edit.click()
            if waitUntil(timeout: 2) { save.exists && cancel.exists } {
                return
            }
        }
        XCTFail("Item editor did not open")
    }

    func saveItemType(in app: XCUIApplication) {
        let save = app.buttons.identified("saveItemTypeStudio")
        XCTAssertTrue(save.waitUntilExists(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        if save.waitUntilHittable(timeout: 2) {
            save.click()
        } else {
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        }
        XCTAssertTrue(save.waitUntilGone(timeout: 10), "Item type editor did not close after saving")
    }

    func assertItemTypeStudioFitsWindow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        let outline = app.descendants(matching: .any).identified("itemTypeStudioOutline")
        let editor = app.descendants(matching: .any)
            .identified("itemTypeStudioCardSetupEditor")
        let cancel = app.buttons.identified("cancelItemTypeStudio")
        let save = app.buttons.identified("saveItemTypeStudio")

        XCTAssertTrue(window.waitUntilExists(timeout: 5), file: file, line: line)
        for element in [outline, editor, cancel, save] {
            XCTAssertTrue(element.waitUntilExists(timeout: 5), file: file, line: line)
        }

        XCTAssertLessThanOrEqual(
            outline.frame.maxX,
            editor.frame.minX + 1,
            "Studio columns must not overlap",
            file: file,
            line: line
        )
        for (name, element) in [
            ("outline", outline),
            ("Card setup editor", editor),
            ("Cancel", cancel),
            ("Save", save),
        ] {
            XCTAssertGreaterThanOrEqual(
                element.frame.minX,
                window.frame.minX - 1,
                "Studio \(name) extends past the window's leading edge",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                element.frame.maxX,
                window.frame.maxX + 1,
                "Studio \(name) extends past the window's trailing edge",
                file: file,
                line: line
            )
        }
    }

    /// Asserting absence immediately races the animation that removes the
    /// element, so absence has to be waited for like anything else.
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitUntilGone(timeout: timeout)
    }

    func selectMenuItem(_ name: String, in app: XCUIApplication) {
        let item = app.menuItems[name]
        XCTAssertTrue(item.waitUntilExists(timeout: 3))
        item.click()
        let dismissed = waitUntil(timeout: 1) {
            !item.exists || !item.isHittable
        }
        if dismissed { return }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func selectPopUpOption(named name: String, picker: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(picker.waitUntilExists(timeout: 5))
        picker.click()
        // A pop-up menu populates a beat after the click, and the keyboard
        // fallback below would otherwise start stepping through a menu that is
        // not there yet.
        _ = picker.menuItems.firstMatch.waitUntilExists(timeout: 2)
        // Scope the option to this pop-up. App-wide lookup is ambiguous for
        // labels such as "Arrange", which also exist in the macOS Window menu.
        let option = picker.menuItems[name].firstMatch
        if option.waitUntilExists(timeout: 5) {
            option.click()
            _ = option.waitUntilGone(timeout: 2)
            return
        }
        for _ in 0..<12 {
            if (picker.value as? String)?.contains(name) == true {
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
                _ = picker.menuItems.firstMatch.waitUntilGone(timeout: 1)
                return
            }
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        _ = picker.menuItems.firstMatch.waitUntilGone(timeout: 1)
    }

    func dismissOpenMenus(in app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        _ = waitUntil(timeout: 0.25) {
            let menu = app.menus.firstMatch
            return !menu.exists || !menu.isHittable
        }
    }

    func addBasicItem(front: String, back: String, in app: XCUIApplication) {
        openAddItem(in: app)
        enterText(front, into: field(named: "Front", in: app), app: app)
        enterText(back, into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)
        waitForItem(named: front, in: app)
    }

    func showSidebar(in app: XCUIApplication) {
        let allDecks = app.descendants(matching: .any).identified("scopeRow-AllDecks")
        if allDecks.exists, allDecks.isHittable { return }
        // Restore split view sidebar when detail-only.
        app.typeKey("0", modifierFlags: [.command])
        XCTAssertTrue(allDecks.waitUntilHittable(timeout: 3), "Sidebar did not become interactive")
    }

    func assertSidebarCannotOpenDuringStudy(in app: XCUIApplication) {
        let allDecks = app.descendants(matching: .any).identified("scopeRow-AllDecks")
        assertSidebarCollapsed(in: app)
        app.typeKey("0", modifierFlags: [.command])
        XCTAssertFalse(
            allDecks.waitUntilHittable(timeout: 1),
            "Sidebar became interactive during study"
        )
    }

    func modalContainer(in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement? {
        firstExisting(
            of: [app.dialogs.firstMatch, app.sheets.firstMatch, app.alerts.firstMatch],
            timeout: timeout
        )
    }

    func selectScope(_ identifier: String, in app: XCUIApplication) {
        showSidebar(in: app)
        let row = app.descendants(matching: .any).identified(identifier)
        if row.waitUntilExists(timeout: 5) {
            row.click()
            waitForScopeSelection(in: app)
            return
        }
        // Fallback: match deck name from identifier deckRow-Name
        if identifier.hasPrefix("deckRow-") {
            let name = String(identifier.dropFirst("deckRow-".count))
            let label = NSPredicate(format: "label CONTAINS[c] %@", name)
            let match = app.descendants(matching: .any).matching(label).firstMatch
            XCTAssertTrue(match.waitUntilExists(timeout: 5))
            match.click()
            waitForScopeSelection(in: app)
            return
        }
        if identifier == "scopeRow-AllDecks" {
            let match = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", "All Decks")
            ).firstMatch
            XCTAssertTrue(match.waitUntilExists(timeout: 5))
            match.click()
            waitForScopeSelection(in: app)
            return
        }
        if identifier == "scopeRow-Unassigned" {
            let match = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", "Unassigned")
            ).firstMatch
            XCTAssertTrue(match.waitUntilExists(timeout: 5))
            match.click()
            waitForScopeSelection(in: app)
            return
        }
        XCTFail("Could not find scope row \(identifier)")
    }

    /// Sidebar rows use `accessibilityElement(children: .combine)`, which
    /// collapses them into static text that never reports `isSelected` — a
    /// selection predicate here can only ever burn its whole timeout. What the
    /// callers actually need is for the new scope's content to have caught up.
    ///
    /// `libraryIsReady` can be satisfied by a marker that outlives the switch
    /// (the toolbar's Add button never goes away), so it alone can return while
    /// the scope-specific controls are still being built. Waiting for the
    /// placeholder to appear and clear is what actually tracks the reload; when
    /// no placeholder shows up at all the load was already synchronous.
    private func waitForScopeSelection(in app: XCUIApplication) {
        let loading = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["scopeHomeLoading", "itemBrowserLoading"])
        ).firstMatch
        if loading.waitUntilExists(timeout: 0.5) {
            XCTAssertTrue(loading.waitUntilGone(timeout: 10))
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["libraryReady"].waitUntilExists(timeout: 3),
            "Selected scope did not become ready"
        )
    }

    func createDeck(named name: String, in app: XCUIApplication) {
        showSidebar(in: app)
        let newDeck = app.buttons.identified("newDeckToolbar")
        XCTAssertTrue(newDeck.waitUntilExists(timeout: 5))
        newDeck.click()

        guard let container = modalContainer(in: app) else {
            XCTFail("Deck creation dialog did not appear")
            return
        }

        let textField = container.textFields.firstMatch
        if textField.waitUntilExists(timeout: 2) {
            textField.click()
            textField.typeKey("a", modifierFlags: [.command])
            textField.typeText(name)
        }

        if app.buttons.identified("confirmCreateDeck").waitUntilExists(timeout: 2) {
            app.buttons.identified("confirmCreateDeck").click()
        } else if container.buttons.identified("Create").exists {
            container.buttons.identified("Create").click()
        }

        let deckAppeared = app.descendants(matching: .any).identified("deckRow-\(name)")
            .waitUntilExists(timeout: 10)
            || app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", name)
            ).firstMatch.waitUntilExists(timeout: 5)
        XCTAssertTrue(deckAppeared)
    }

    func openItemDetail(named title: String, in app: XCUIApplication) {
        returnToLibrary(in: app)
        enterBrowseMode(in: app)
        let row = app.descendants(matching: .any).identified("itemRow-\(title)")
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        row.doubleClick()
        XCTAssertTrue(app.buttons.identified("deleteItem").waitUntilExists(timeout: 15))
    }

    func startStudy(in app: XCUIApplication) {
        let studyButton = app.buttons.identified("studyButton")
        XCTAssertTrue(studyButton.waitUntilExists(timeout: 5))
        XCTAssertTrue(studyButton.isEnabled)
        studyButton.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            app.buttons.identified("primaryStudyAction").exists
                || app.buttons.identified("startRecording").exists
                || app.buttons.identified("studySessionDone").exists
        })
    }

    /// Clicks a control, falling back to its keyboard shortcut when a tall
    /// window has pushed it off a short display. Both reach the same action, and
    /// the screenshot is taken from the resulting state either way.
    func clickOrType(_ identifier: String, shortcut: String, in app: XCUIApplication) {
        let button = app.buttons.identified(identifier)
        XCTAssertTrue(button.waitUntilExists(timeout: 5))
        if button.isHittable {
            button.click()
        } else {
            app.typeKey(shortcut, modifierFlags: [])
        }
    }

    /// Activates the primary study action. The button carries the default-action
    /// keyboard shortcut, so Return reaches it even when a tall window has
    /// pushed it past the bottom of a short display and clicking cannot.
    func triggerPrimaryStudyAction(in app: XCUIApplication) {
        let primaryAction = app.buttons.identified("primaryStudyAction")
        XCTAssertTrue(primaryAction.waitUntilExists(timeout: 5))
        if primaryAction.isHittable {
            primaryAction.click()
        } else {
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        }
    }

    func revealAndGrade(_ gradeID: String, in app: XCUIApplication) {
        if app.buttons.identified("primaryStudyAction").waitUntilExists(timeout: 2) {
            triggerPrimaryStudyAction(in: app)
        }
        let shortcut = Self.gradeShortcuts[gradeID]
        XCTAssertNotNil(shortcut)
        if let shortcut {
            clickOrType(gradeID, shortcut: shortcut, in: app)
        }
    }

    static let gradeShortcuts = [
        "gradeAgain": "1",
        "gradeHard": "2",
        "gradeGood": "3",
        "gradeEasy": "4",
    ]

    /// Grading "Again" puts the card back in the queue, so the session does not
    /// end on its own and neither exit button ever appears. Ending it explicitly
    /// is what gets back to the library from any grade.
    func finishStudySession(in app: XCUIApplication) {
        if app.buttons.identified("primaryStudyAction").exists {
            endStudyViaMenu(in: app)
            return
        }
        if let exit = firstExisting(
            of: [
                app.buttons.identified("studySessionDone"),
                app.buttons.identified("studyBackToLibrary"),
            ],
            timeout: 2
        ) {
            exit.click()
        } else if app.buttons.identified("primaryStudyAction").exists {
            endStudyViaMenu(in: app)
            return
        }
        waitForLibraryReady(in: app)
    }

    func formattedField(
        _ fieldName: String,
        containing expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> Bool {
        let mirror = app.descendants(matching: .any).identified("field-\(fieldName)-spans")
        guard mirror.waitUntilExists(timeout: 2) else { return false }

        let expectedParts = expectedToken.split(separator: ":", maxSplits: 1).map(String.init)
        func containsExpectedToken(_ description: String) -> Bool {
            if description.contains(expectedToken) { return true }
            guard expectedParts.count == 2 else { return false }
            return description.split(separator: "|").contains { run in
                let parts = run.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return false }
                return parts[0].split(separator: "+").contains(Substring(expectedParts[0]))
                    && parts[1].contains(expectedParts[1])
            }
        }

        return waitUntil(timeout: timeout) {
            [mirror.value as? String, mirror.label]
                .contains { $0.map(containsExpectedToken) == true }
        }
    }

    func replaceAndSelectText(_ text: String, in field: XCUIElement) {
        field.click()
        field.typeKey("a", modifierFlags: [.command])
        field.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        field.typeText(text)
        field.typeKey("a", modifierFlags: [.command])
    }

    func assertFormattedField(
        named fieldName: String,
        buttonID: String,
        style: String,
        text: String,
        in app: XCUIApplication
    ) {
        let editorField = field(named: fieldName, in: app)
        XCTAssertTrue(editorField.waitUntilExists(timeout: 5))

        replaceAndSelectText(text, in: editorField)

        let formatButton = app.buttons.identified("field-\(fieldName)-\(buttonID)")
        XCTAssertTrue(formatButton.waitUntilHittable(timeout: 2), "Missing format button \(buttonID) for \(fieldName)")
        formatButton.click()
        if !formattedField(fieldName, containing: "\(style):\(text)", in: app, timeout: 1) {
            editorField.click()
            editorField.typeKey("a", modifierFlags: [.command])
            formatButton.click()
        }
        XCTAssertTrue(
            formattedField(fieldName, containing: "\(style):\(text)", in: app),
            "Expected field-\(fieldName) to contain \(style):\(text)"
        )
    }

    func assertFormattedStyles(
        named fieldName: String,
        text: String,
        styles: [(buttonID: String, style: String)],
        in app: XCUIApplication
    ) {
        let editorField = field(named: fieldName, in: app)
        XCTAssertTrue(editorField.waitUntilExists(timeout: 5))
        replaceAndSelectText(text, in: editorField)

        for style in styles {
            let button = app.buttons.identified("field-\(fieldName)-\(style.buttonID)")
            XCTAssertTrue(
                button.waitUntilHittable(timeout: 2),
                "Missing format button \(style.buttonID) for \(fieldName)"
            )
            editorField.click()
            editorField.typeKey("a", modifierFlags: [.command])
            button.click()
            if !formattedField(
                fieldName,
                containing: "\(style.style):\(text)",
                in: app,
                timeout: 1
            ) {
                editorField.click()
                editorField.typeKey("a", modifierFlags: [.command])
                button.click()
            }
            XCTAssertTrue(
                formattedField(fieldName, containing: "\(style.style):\(text)", in: app),
                "Expected field-\(fieldName) to contain \(style.style):\(text)"
            )
        }
    }

    func makeImportFixture(name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki2-ui-imports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func chooseImportFile(_ url: URL, in app: XCUIApplication) {
        returnToLibrary(in: app)
        waitForLibraryReady(in: app)
        dismissOpenMenus(in: app)
        app.activate()

        app.menuBarItems["File"].click()
        let importItem = app.menuItems.identified("Import…")
        XCTAssertTrue(importItem.waitUntilExists(timeout: 3))
        XCTAssertTrue(importItem.isEnabled, "Import should be enabled before opening the file picker")
        importItem.click()

        XCTAssertTrue(app.sheets.firstMatch.waitUntilExists(timeout: 8))
        chooseFileInOpenPanel(url, in: app)
    }

    func launchAppForImport(
        file url: URL,
        databaseLabel: String = UUID().uuidString,
        scenario: String? = nil,
        environment: [String: String] = [:],
        waitForLibrary: Bool = true
    ) -> XCUIApplication {
        var env = environment
        env["NEOANKI_TEST_IMPORT_PATH"] = url.path
        let app = launchApp(
            databaseLabel: databaseLabel,
            scenario: scenario,
            environment: env,
            waitForLibrary: waitForLibrary
        )
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].waitUntilExists(timeout: 15))
        return app
    }

    func launchAppForPortableImport(
        databaseLabel: String = UUID().uuidString,
        scenario: String? = nil,
        file url: URL,
        environment: [String: String] = [:],
        waitForLibrary: Bool = true
    ) -> XCUIApplication {
        var env = environment
        env["NEOANKI_TEST_FIXTURE_DIR"] = fixturesDirectory().path
        env["NEOANKI_TEST_PORTABLE_IMPORT_PATH"] = url.path
        let app = launchApp(
            databaseLabel: databaseLabel,
            scenario: scenario,
            environment: env,
            waitForLibrary: waitForLibrary
        )
        let deadline = Date().addingTimeInterval(30)
        var sawBusy = false
        while Date() < deadline {
            if app.buttons.identified("portableDeckConflictUseLocal").exists {
                return app
            }
            let busy = app.descendants(matching: .any)["portableDeckTransferBusy"]
            if busy.exists {
                sawBusy = true
            } else if sawBusy && libraryIsReady(in: app) {
                return app
            }
            let noticeAction = app.buttons["action-button-1"]
            if noticeAction.exists, noticeAction.isHittable {
                return app
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return app
    }

    func choosePortableDeckImport(_ url: URL, in app: XCUIApplication) {
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        let importItem = app.menuItems.identified("Import Deck…")
        XCTAssertTrue(importItem.waitUntilExists(timeout: 3))
        importItem.click()

        chooseFileInOpenPanel(url, in: app)
    }

    func cancelFilePicker(in app: XCUIApplication) {
        let cancel = firstExisting(
            of: [
                app.sheets.firstMatch.buttons["Cancel"],
                app.dialogs.firstMatch.buttons["Cancel"],
                app.buttons["Cancel"],
            ],
            timeout: 2
        )
        if let cancel, cancel.isHittable {
            cancel.click()
        } else {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                !app.sheets.firstMatch.exists
                    && !app.dialogs.firstMatch.exists
                    && !app.textFields["PathTextField"].exists
            },
            "Open panel did not close"
        )
    }

    func assertSidebarCollapsed(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let scopeRow = app.descendants(matching: .any).identified("scopeRow-AllDecks")
        if scopeRow.exists {
            XCTAssertFalse(scopeRow.isHittable, file: file, line: line)
        }
    }

    func chooseExportDestination(_ url: URL, in app: XCUIApplication) {
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        let exportItem = app.menuItems.identified("Export Deck…")
        XCTAssertTrue(exportItem.waitUntilExists(timeout: 3))
        XCTAssertTrue(
            waitUntil(timeout: 5) { exportItem.isEnabled },
            "Export Deck did not become enabled for the selected deck"
        )
        exportItem.click()

        chooseFileInSavePanel(url, in: app)
    }

    func waitForGoToFolderField(in app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement? {
        // The surrounding open/save panel also contains text fields. Returning
        // its first field can mistake the filename control for the dedicated
        // Go to Folder control and send a directory path to the wrong place.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pathField = app.textFields["PathTextField"]
            if pathField.exists {
                return pathField
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    func chooseFileInOpenPanel(_ url: URL, in app: XCUIApplication) {
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                app.sheets.firstMatch.exists
                    || app.dialogs.firstMatch.exists
                    || app.textFields["PathTextField"].exists
            },
            "Open panel did not appear"
        )

        for _ in 0..<3 {
            app.typeKey("g", modifierFlags: [.command, .shift])
            if let goToFolderField = waitForGoToFolderField(in: app, timeout: 3) {
                goToFolderField.click()
                goToFolderField.typeKey("a", modifierFlags: [.command])
                goToFolderField.typeText(url.path)
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
                _ = goToFolderField.waitUntilGone(timeout: 3)
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
                return
            }
        }
        XCTFail("Go to folder field did not appear")
    }

    func chooseFileInSavePanel(_ url: URL, in app: XCUIApplication) {
        guard waitUntil(timeout: 8, {
                app.sheets.firstMatch.exists
                    || app.dialogs.firstMatch.exists
                    || app.textFields["PathTextField"].exists
            }) else {
            XCTFail("Save panel did not appear")
            return
        }
        app.typeKey("g", modifierFlags: [.command, .shift])

        guard let goToFolderField = waitForGoToFolderField(in: app) else {
            XCTFail("Go to folder field did not appear")
            return
        }
        goToFolderField.click()
        goToFolderField.typeKey("a", modifierFlags: [.command])
        goToFolderField.typeText(url.deletingLastPathComponent().path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        _ = goToFolderField.waitUntilGone(timeout: 3)
        if let panel = activeFilePanel(in: app) {
            let nameField = panel.textFields.matching(
                NSPredicate(format: "identifier != 'PathTextField'")
            ).firstMatch
            if nameField.waitUntilExists(timeout: 2) {
                nameField.click()
                nameField.typeKey("a", modifierFlags: [.command])
                nameField.typeText(url.lastPathComponent)
            }
        }

        if let panel = activeFilePanel(in: app),
           panel.buttons["Save"].waitUntilExists(timeout: 2) {
            panel.buttons["Save"].click()
        } else {
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        }
    }

    func activeFilePanel(in app: XCUIApplication) -> XCUIElement? {
        if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
        if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
        return nil
    }

    func dismissAnyAlertOK(in app: XCUIApplication, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let appOK = app.buttons["action-button-1"]
            if appOK.exists && appOK.isHittable {
                appOK.click()
                return
            }

            for sheet in app.sheets.allElementsBoundByIndex where sheet.exists {
                for identifier in ["action-button-1", "OK"] {
                    let button = sheet.buttons[identifier]
                    if button.exists && button.isHittable {
                        button.click()
                        return
                    }
                }
                let ok = sheet.buttons.matching(
                    NSPredicate(format: "title == 'OK'")
                ).firstMatch
                if ok.exists && ok.isHittable {
                    ok.click()
                    return
                }
            }
            for alert in app.alerts.allElementsBoundByIndex where alert.exists {
                for identifier in ["action-button-1", "OK"] {
                    let button = alert.buttons[identifier]
                    if button.exists && button.isHittable {
                        button.click()
                        return
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("No alert with an OK button appeared")
    }

    func finishPortableImport(in app: XCUIApplication, noticeTitle: String = "Deck Imported") {
        waitForPortableImportCompletion(in: app)
        dismissPortableDeckNoticeIfPresent(titled: noticeTitle, in: app)
        waitForLibraryReady(in: app)
        selectScope("scopeRow-AllDecks", in: app)
    }

    func waitForPortableImportCompletion(in app: XCUIApplication) {
        let busy = app.descendants(matching: .any)["portableDeckTransferBusy"]
        if busy.exists {
            _ = busy.waitUntilGone(timeout: 45)
        }
    }

    @discardableResult
    func dismissPortableDeckNoticeIfPresent(titled title: String, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let ok = app.buttons["action-button-1"]
            if ok.exists && ok.isHittable {
                ok.click()
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    func dismissPortableDeckNotice(titled title: String, in app: XCUIApplication) {
        if !dismissPortableDeckNoticeIfPresent(titled: title, in: app) {
            XCTFail("Portable deck notice '\(title)' did not appear")
        }
    }

    func dismissAlert(titled title: String, button: String, in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if app.alerts.firstMatch.waitUntilExists(timeout: 0.5) {
                dismissAnyAlertOK(in: app, timeout: 1)
                return
            }
            if app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", title, title)
            ).firstMatch.exists {
                dismissAnyAlertOK(in: app, timeout: 1)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        dismissAnyAlertOK(in: app, timeout: 2)
    }

    func dismissImportComplete(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let importButton = app.buttons.identified("confirmImport")
        if importButton.exists {
            _ = importButton.waitUntilGone(timeout: timeout)
        }
        let importSheet = app.descendants(matching: .any)["importSheet"]
        _ = importSheet.waitUntilGone(timeout: timeout)

        // AppKit does not consistently expose a SwiftUI Alert's title as a
        // static text. The action is the synchronization point that matters,
        // and querying it directly avoids a guaranteed 30-second title wait
        // on runners where the alert is represented only by its button.
        let ok = app.buttons["action-button-1"]
        if ok.exists, ok.isHittable {
            ok.click()
        }
    }

    func startStudyViaMenu(in app: XCUIApplication) {
        app.menuBarItems["Study"].click()
        let start = app.menuItems.identified("Start Study")
        XCTAssertTrue(start.waitUntilExists(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        start.click()
        XCTAssertTrue(app.buttons.identified("primaryStudyAction").waitUntilExists(timeout: 5)
            || app.buttons.identified("studySessionDone").waitUntilExists(timeout: 2))
    }

    func endStudyViaMenu(in app: XCUIApplication) {
        app.menuBarItems["Study"].click()
        let end = app.menuItems.identified("End Session")
        XCTAssertTrue(end.waitUntilExists(timeout: 3))
        end.click()

        let confirm = app.buttons.identified("confirmEndStudySession")
        if confirm.exists {
            confirm.click()
        } else if let container = modalContainer(in: app, timeout: 0.5) {
            container.buttons.identified("End Session").click()
        }
        waitForLibraryReady(in: app)
    }

    func gradeViaKeyboard(_ grade: Int, in app: XCUIApplication) {
        XCTAssertTrue((1...4).contains(grade))
        app.typeKey("\(grade)", modifierFlags: [])
    }

    func assertMenuDisabled(_ item: String, in app: XCUIApplication) {
        app.menuBarItems["File"].click()
        let menuItem = app.menuItems.identified(item)
        XCTAssertTrue(menuItem.waitUntilExists(timeout: 3))
        XCTAssertFalse(menuItem.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func assertMenuEnabled(_ item: String, in app: XCUIApplication) {
        app.menuBarItems["File"].click()
        let menuItem = app.menuItems.identified(item)
        XCTAssertTrue(menuItem.waitUntilExists(timeout: 3))
        XCTAssertTrue(menuItem.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    func fixtureURL(_ name: String) -> URL {
        fixturesDirectory().appendingPathComponent(name)
    }

    func launchAppWithFixtures(
        databaseLabel: String = UUID().uuidString,
        scenario: String? = nil,
        environment: [String: String] = [:],
        waitForLibrary: Bool = true
    ) -> XCUIApplication {
        var env = environment
        env["NEOANKI_TEST_FIXTURE_DIR"] = fixturesDirectory().path
        return launchApp(
            databaseLabel: databaseLabel,
            scenario: scenario,
            environment: env,
            waitForLibrary: waitForLibrary
        )
    }
}

extension XCUIElementQuery {
    func identified(_ identifier: String) -> XCUIElement {
        matching(identifier: identifier).firstMatch
    }
}

/// How often the polling waits below re-query the app. A query costs ~40ms on
/// its own, so this lands near a 90ms effective period — an order of magnitude
/// finer than the 1s tick these helpers replace.
private let pollInterval: TimeInterval = 0.05

extension XCUIElement {
    /// `waitForExistence` schedules its first predicate evaluation one full
    /// second out, so it burns ~1.04s even when the element is already on
    /// screen. Polling `exists` checks immediately and returns the moment the
    /// element shows up, which is both faster and finer-grained than the
    /// version it replaces.
    @discardableResult
    func waitUntilExists(timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { $0.exists }
    }

    /// Negative counterpart to `waitUntilExists`, replacing
    /// `waitForNonExistence` and its matching 1s tick.
    @discardableResult
    func waitUntilGone(timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { !$0.exists }
    }

    @discardableResult
    func waitUntilHittable(timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { $0.exists && $0.isHittable }
    }

    func waitUntil(timeout: TimeInterval, _ condition: (XCUIElement) -> Bool) -> Bool {
        if condition(self) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
            if condition(self) { return true }
        }
        return condition(self)
    }
}

extension NeoAnkiUITestCase {
    /// Probing candidates one at a time makes every miss cost that candidate's
    /// full timeout, so a two-way probe against an absent first option pays for
    /// it before it even looks at the second. Polling all of them together
    /// costs one timeout total and returns whichever appears first.
    func firstExisting(
        of candidates: [XCUIElement],
        timeout: TimeInterval = 5
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for candidate in candidates where candidate.exists {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline
        return candidates.first { $0.exists }
    }

    /// Waits for any of several conditions to come true, for the cases where
    /// the interesting states are not all "some element exists".
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
            if condition() { return true }
        }
        return condition()
    }
}
