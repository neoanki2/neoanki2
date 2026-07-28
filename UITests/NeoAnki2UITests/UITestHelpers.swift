import CryptoKit
@preconcurrency import XCTest

@MainActor
class NeoAnkiUITestCase: XCTestCase {
    var runningApp: XCUIApplication?

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
        runningApp?.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-NeoAnkiTesting"]
        app.launchEnvironment["NEOANKI_TESTING"] = "1"
        app.launchEnvironment["NEOANKI_TEST_DB_DIR"] = NSTemporaryDirectory() + "neoanki2-ui-\(databaseLabel)"
        if let scenario {
            app.launchEnvironment["NEOANKI_TEST_SCENARIO"] = scenario
        }
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()

        runningApp = app
        addTeardownBlock { @MainActor [weak self, weak app] in
            guard let self else { return }
            if let failure = self.testRun?.failureCount, failure > 0, let app {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(self.name)-failure"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
            app?.terminate()
            if self.runningApp === app {
                self.runningApp = nil
            }
        }
        if waitForLibrary {
            waitForLibraryReady(in: app)
        }
        return app
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
        guard appWindow.waitForExistence(timeout: 5) else {
            XCTFail("No app window available for documentation screenshot '\(name)'", file: file, line: line)
            return
        }
        for identifier in expectedVisibleIdentifiers {
            let element = appWindow.descendants(matching: .any).identified(identifier)
            guard element.waitForExistence(timeout: 3),
                  !element.frame.isEmpty,
                  element.frame.intersects(appWindow.frame) else {
                XCTFail(
                    "Expected '\(identifier)' to be visible in documentation screenshot '\(name)'",
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
                capturedAt: captureContext.capturedAt
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
        var screenshots: [Entry]
    }

    private struct DocumentationScreenshotCaptureContext: Codable {
        let sourceSHA: String
        let capturedAt: String
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
        capturedAt: String
    ) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = DocumentationScreenshotManifest(
            schemaVersion: 1,
            sourceSHA: sourceSHA,
            capturedAt: capturedAt,
            screenshots: []
        )
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(
                DocumentationScreenshotManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.sourceSHA == sourceSHA, manifest.capturedAt == capturedAt else {
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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["Starting…"].exists || app.staticTexts["Loading items…"].exists
                || app.staticTexts["Loading decks…"].exists {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            if libraryIsReady(in: app) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Library did not finish loading within \(timeout)s")
    }

    func libraryIsReady(in app: XCUIApplication) -> Bool {
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

        let done = app.buttons.identified("templatesDone")
        if !done.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons.identified("Done").waitForExistence(timeout: 2))
        }
        waitForTemplatesReady(in: app)
    }

    func waitForTemplatesReady(in app: XCUIApplication, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["Loading item types…"].exists {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            if app.descendants(matching: .any)["templatesItemTypesHeader"].exists
                || app.descendants(matching: .any)["templatesPanel"].exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Templates panel did not finish loading within \(timeout)s")
    }

    func clickAddItemType(in app: XCUIApplication) {
        if app.buttons.identified("addItemTypeToolbar").waitForExistence(timeout: 3) {
            app.buttons.identified("addItemTypeToolbar").click()
            return
        }
        if app.buttons.identified("addItemTypeEmptyState").waitForExistence(timeout: 2) {
            app.buttons.identified("addItemTypeEmptyState").click()
            return
        }
        XCTFail("Add item type control not found")
    }

    func openTemplateEditor(named name: String, in app: XCUIApplication) {
        let edit = app.buttons.identified("editTemplate-\(name)")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(app.textFields.identified("templateNameField").waitForExistence(timeout: 10))
    }

    func closeTemplates(in app: XCUIApplication) {
        if app.buttons.identified("templatesDone").exists {
            app.buttons.identified("templatesDone").click()
        } else if app.buttons.identified("Done").exists {
            app.buttons.identified("Done").click()
        } else {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
        _ = app.buttons.identified("templatesDone").waitForNonExistence(timeout: 10)
        waitForLibraryReady(in: app)
    }

    func enterText(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        if field.value as? String != nil && !(field.value as? String ?? "").isEmpty {
            field.typeKey("a", modifierFlags: [.command])
        }
        field.typeText(text)
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
    }

    func saveAddItem(in app: XCUIApplication) {
        let save = app.buttons.identified("saveAddItem")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
    }

    /// Item rows live in browse mode, not on the scope home, so anything that
    /// asserts on a row has to get there first.
    func isBrowsing(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["itemBrowserTable"].exists
            || app.descendants(matching: .any)["browseNoSearchResults"].exists
            || app.buttons.identified("browseDone").exists
    }

    func enterBrowseMode(in app: XCUIApplication, timeout: TimeInterval = 10) {
        if isBrowsing(in: app) { return }
        waitForLibraryReady(in: app)
        if isBrowsing(in: app) { return }

        let browse = app.buttons.identified("browseToolbar")
        if browse.waitForExistence(timeout: 3), browse.isEnabled {
            browse.click()
        } else {
            app.typeKey("b", modifierFlags: [.command, .option])
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isBrowsing(in: app) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Browse mode did not open within \(timeout)s")
    }

    func leaveBrowseMode(in app: XCUIApplication) {
        guard isBrowsing(in: app) else { return }
        let done = app.buttons.identified("browseDone")
        if done.exists {
            done.click()
        } else {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
        _ = done.waitForNonExistence(timeout: 5)
        waitForLibraryReady(in: app)
    }

    func waitForItem(named title: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        enterBrowseMode(in: app, timeout: timeout)
        let row = app.descendants(matching: .any).identified("itemRow-\(title)")
        if row.waitForExistence(timeout: timeout) {
            return
        }

        let labelPredicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let match = app.descendants(matching: .any).matching(labelPredicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
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
        XCTAssertTrue(
            app.descendants(matching: .any)["scopeHomeNextDue"].waitForExistence(timeout: 10),
            "Expected the scope home to say when the next card is due",
            file: file,
            line: line
        )
        XCTAssertFalse(app.buttons.identified("studyButton").exists, file: file, line: line)
    }

    func assertDueCardsAvailable(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        leaveBrowseMode(in: app)
        let studyButton = app.buttons.identified("studyButton")
        XCTAssertTrue(studyButton.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(studyButton.isEnabled, file: file, line: line)
    }

    func field(named name: String, in app: XCUIApplication) -> XCUIElement {
        let id = "field-\(name)"
        let textView = app.textViews.identified(id)
        if textView.waitForExistence(timeout: 2) {
            return textView
        }
        let textField = app.textFields.identified(id)
        if textField.waitForExistence(timeout: 1) {
            return textField
        }
        return app.descendants(matching: .any)[id]
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
        if app.buttons.identified("templatesDone").exists {
            app.buttons.identified("templatesDone").click()
        }
        if app.buttons.identified("cancelTemplateEditor").exists {
            app.buttons.identified("cancelTemplateEditor").click()
        }
        if app.buttons["deleteItem"].exists {
            if app.buttons.identified("itemDetailBack").exists {
                app.buttons.identified("itemDetailBack").click()
            } else {
                showSidebar(in: app)
                let unassigned = app.descendants(matching: .any).identified("scopeRow-Unassigned")
                let allDecks = app.descendants(matching: .any).identified("scopeRow-AllDecks")
                if unassigned.waitForExistence(timeout: 2), allDecks.waitForExistence(timeout: 2) {
                    unassigned.click()
                    _ = app.buttons.identified("deleteItem").waitForNonExistence(timeout: 5)
                    allDecks.click()
                } else {
                    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
                }
            }
            _ = app.buttons.identified("deleteItem").waitForNonExistence(timeout: 5)
        }
        waitForLibraryReady(in: app)
    }

    func openAddItem(in app: XCUIApplication) {
        returnToLibrary(in: app)
        if app.buttons.identified("addItemEmptyState").waitForExistence(timeout: 2) {
            app.buttons.identified("addItemEmptyState").click()
        } else {
            let add = app.buttons.identified("addItemToolbar")
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.click()
        }

        XCTAssertTrue(app.buttons.identified("cancelAddItem").waitForExistence(timeout: 10))
        XCTAssertTrue(field(named: "Front", in: app).waitForExistence(timeout: 10))
    }

    func saveItemType(in app: XCUIApplication) {
        let save = app.buttons.identified("saveItemType")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(
            app.buttons.identified("templatesDone").waitForExistence(timeout: 10)
                || app.descendants(matching: .any)["templatesItemTypesHeader"].waitForExistence(timeout: 10)
        )
    }

    /// `waitForExistence` has no negative counterpart, and asserting absence
    /// immediately races the animation that removes the element.
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    func selectMenuItem(_ name: String, in app: XCUIApplication) {
        let item = app.menuItems[name]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if app.menuItems[name].exists {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
    }

    func selectPopUpOption(named name: String, picker: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if app.menuItems[name].waitForExistence(timeout: 5) {
            app.menuItems[name].click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return
        }
        for _ in 0..<12 {
            if (picker.value as? String)?.contains(name) == true {
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                return
            }
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    func dismissOpenMenus(in app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    func addBasicItem(front: String, back: String, in app: XCUIApplication) {
        openAddItem(in: app)
        enterText(front, into: field(named: "Front", in: app), app: app)
        enterText(back, into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)
        waitForItem(named: front, in: app)
    }

    func showSidebar(in app: XCUIApplication) {
        if app.buttons["newDeckToolbar"].exists { return }
        // Restore split view sidebar when detail-only.
        app.typeKey("0", modifierFlags: [.command])
        _ = app.buttons.identified("newDeckToolbar").waitForExistence(timeout: 3)
    }

    func modalContainer(in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement? {
        for _ in 0..<Int(timeout * 10) {
            for element in [app.dialogs.firstMatch, app.sheets.firstMatch, app.alerts.firstMatch] {
                if element.exists { return element }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    func selectScope(_ identifier: String, in app: XCUIApplication) {
        showSidebar(in: app)
        let row = app.descendants(matching: .any).identified(identifier)
        if row.waitForExistence(timeout: 5) {
            row.click()
            waitForScopeSelection(row, in: app)
            return
        }
        // Fallback: match deck name from identifier deckRow-Name
        if identifier.hasPrefix("deckRow-") {
            let name = String(identifier.dropFirst("deckRow-".count))
            let label = NSPredicate(format: "label CONTAINS[c] %@", name)
            let match = app.descendants(matching: .any).matching(label).firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 5))
            match.click()
            waitForScopeSelection(match, in: app)
            return
        }
        if identifier == "scopeRow-AllDecks" {
            let match = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", "All Decks")
            ).firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 5))
            match.click()
            waitForScopeSelection(match, in: app)
            return
        }
        if identifier == "scopeRow-Unassigned" {
            let match = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", "Unassigned")
            ).firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 5))
            match.click()
            waitForScopeSelection(match, in: app)
            return
        }
        XCTFail("Could not find scope row \(identifier)")
    }

    private func waitForScopeSelection(_ row: XCUIElement, in app: XCUIApplication) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: row
        )
        _ = XCTWaiter.wait(for: [selected], timeout: 5)

        let loading = app.staticTexts.identified("Loading items…")
        if loading.exists {
            XCTAssertTrue(loading.waitForNonExistence(timeout: 10))
        }
        waitForLibraryReady(in: app)
    }

    func createDeck(named name: String, in app: XCUIApplication) {
        showSidebar(in: app)
        let newDeck = app.buttons.identified("newDeckToolbar")
        XCTAssertTrue(newDeck.waitForExistence(timeout: 5))
        newDeck.click()

        guard let container = modalContainer(in: app) else {
            XCTFail("Deck creation dialog did not appear")
            return
        }

        let textField = container.textFields.firstMatch
        if textField.waitForExistence(timeout: 2) {
            textField.click()
            textField.typeKey("a", modifierFlags: [.command])
            textField.typeText(name)
        }

        if app.buttons.identified("confirmCreateDeck").waitForExistence(timeout: 2) {
            app.buttons.identified("confirmCreateDeck").click()
        } else if container.buttons.identified("Create").exists {
            container.buttons.identified("Create").click()
        }

        let deckAppeared = app.descendants(matching: .any).identified("deckRow-\(name)")
            .waitForExistence(timeout: 10)
            || app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", name)
            ).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(deckAppeared)
    }

    func openItemDetail(named title: String, in app: XCUIApplication) {
        returnToLibrary(in: app)
        enterBrowseMode(in: app)
        let row = app.descendants(matching: .any).identified("itemRow-\(title)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
        XCTAssertTrue(app.buttons.identified("deleteItem").waitForExistence(timeout: 15))
    }

    func startStudy(in app: XCUIApplication) {
        let studyButton = app.buttons.identified("studyButton")
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(studyButton.isEnabled)
        studyButton.click()
        XCTAssertTrue(app.buttons.identified("primaryStudyAction").waitForExistence(timeout: 5)
            || app.buttons.identified("studySessionDone").waitForExistence(timeout: 2))
    }

    func revealAndGrade(_ gradeID: String, in app: XCUIApplication) {
        let primaryAction = app.buttons.identified("primaryStudyAction")
        if primaryAction.waitForExistence(timeout: 2) {
            if primaryAction.isHittable {
                primaryAction.click()
            } else {
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            }
        }
        let gradeButton = app.buttons.identified(gradeID)
        XCTAssertTrue(gradeButton.waitForExistence(timeout: 5))
        if gradeButton.isHittable {
            gradeButton.click()
        } else {
            let shortcut = [
                "gradeAgain": "1",
                "gradeHard": "2",
                "gradeGood": "3",
                "gradeEasy": "4",
            ][gradeID]
            XCTAssertNotNil(shortcut)
            if let shortcut {
                app.typeKey(shortcut, modifierFlags: [])
            }
        }
    }

    func finishStudySession(in app: XCUIApplication) {
        if app.buttons.identified("studySessionDone").waitForExistence(timeout: 5) {
            app.buttons.identified("studySessionDone").click()
        } else if app.buttons.identified("studyBackToLibrary").waitForExistence(timeout: 2) {
            app.buttons.identified("studyBackToLibrary").click()
        }
        waitForLibraryReady(in: app)
    }

    func waitForFormattedField(
        _ fieldName: String,
        containing expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let mirror = app.descendants(matching: .any).identified("field-\(fieldName)-spans")
        XCTAssertTrue(mirror.waitForExistence(timeout: 2))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = [
                mirror.value as? String,
                mirror.label,
            ]
            if candidates.contains(where: { $0?.contains(expectedToken) == true }) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let value = mirror.value as? String ?? "<nil>"
        let label = mirror.label
        XCTFail("Expected field-\(fieldName) to contain \(expectedToken), got value=\(value) label=\(label)")
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
        XCTAssertTrue(editorField.waitForExistence(timeout: 5))

        replaceAndSelectText(text, in: editorField)

        let formatButton = app.buttons.identified("field-\(fieldName)-\(buttonID)")
        XCTAssertTrue(formatButton.waitForExistence(timeout: 2), "Missing format button \(buttonID) for \(fieldName)")
        formatButton.click()

        waitForFormattedField(fieldName, containing: "\(style):\(text)", in: app)
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        app.menuBarItems["File"].click()
        let importItem = app.menuItems.identified("Import…")
        XCTAssertTrue(importItem.waitForExistence(timeout: 3))
        XCTAssertTrue(importItem.isEnabled, "Import should be enabled before opening the file picker")
        importItem.click()

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
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
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].waitForExistence(timeout: 15))
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
        while Date() < deadline {
            if app.alerts.firstMatch.exists || app.sheets.firstMatch.exists {
                return app
            }
            if app.buttons.identified("portableDeckConflictUseLocal").exists {
                return app
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return app
    }

    func choosePortableDeckImport(_ url: URL, in app: XCUIApplication) {
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        let importItem = app.menuItems.identified("Import Deck…")
        XCTAssertTrue(importItem.waitForExistence(timeout: 3))
        importItem.click()

        chooseFileInOpenPanel(url, in: app)
    }

    func cancelFilePicker(in app: XCUIApplication) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if app.textFields["PathTextField"].exists || app.sheets.firstMatch.exists {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
    }

    func assertSidebarCollapsed(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let scopeRow = app.descendants(matching: .any).identified("scopeRow-AllDecks")
        if scopeRow.waitForExistence(timeout: 2) {
            XCTAssertFalse(scopeRow.isHittable, file: file, line: line)
        }
    }

    func chooseExportDestination(_ url: URL, in app: XCUIApplication) {
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        let exportItem = app.menuItems.identified("Export Deck…")
        XCTAssertTrue(exportItem.waitForExistence(timeout: 3))
        exportItem.click()

        chooseFileInSavePanel(url, in: app)
    }

    func waitForGoToFolderField(in app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.textFields["PathTextField"].exists {
                return app.textFields["PathTextField"]
            }
            for index in 0..<app.sheets.count {
                let field = app.sheets.element(boundBy: index).textFields.firstMatch
                if field.exists {
                    return field
                }
            }
            if app.dialogs.firstMatch.exists {
                let field = app.dialogs.firstMatch.textFields.firstMatch
                if field.exists {
                    return field
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    func chooseFileInOpenPanel(_ url: URL, in app: XCUIApplication) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        _ = app.sheets.firstMatch.waitForExistence(timeout: 8)

        for _ in 0..<3 {
            app.typeKey("g", modifierFlags: [.command, .shift])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if let goToFolderField = waitForGoToFolderField(in: app, timeout: 3) {
                goToFolderField.click()
                goToFolderField.typeKey("a", modifierFlags: [.command])
                goToFolderField.typeText(url.path)
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
                return
            }
        }
        XCTFail("Go to folder field did not appear")
    }

    func chooseFileInSavePanel(_ url: URL, in app: XCUIApplication) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey("g", modifierFlags: [.command, .shift])

        guard let goToFolderField = waitForGoToFolderField(in: app) else {
            XCTFail("Go to folder field did not appear")
            return
        }
        goToFolderField.click()
        goToFolderField.typeKey("a", modifierFlags: [.command])
        goToFolderField.typeText(url.deletingLastPathComponent().path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        if let panel = activeFilePanel(in: app) {
            let nameField = panel.textFields.matching(
                NSPredicate(format: "identifier != 'PathTextField'")
            ).firstMatch
            if nameField.waitForExistence(timeout: 2) {
                nameField.click()
                nameField.typeKey("a", modifierFlags: [.command])
                nameField.typeText(url.lastPathComponent)
            }
        }

        if let panel = activeFilePanel(in: app),
           panel.buttons["Save"].waitForExistence(timeout: 2) {
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
        if busy.waitForExistence(timeout: 3) {
            _ = busy.waitForNonExistence(timeout: 45)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    @discardableResult
    func dismissPortableDeckNoticeIfPresent(titled title: String, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let titleVisible = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", title, title)
            ).firstMatch.exists
            let ok = app.buttons["action-button-1"]
            if titleVisible && ok.exists && ok.isHittable {
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
            if app.alerts.firstMatch.waitForExistence(timeout: 0.5) {
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

    func dismissImportComplete(in app: XCUIApplication, timeout: TimeInterval = 60) {
        let importButton = app.buttons.identified("confirmImport")
        if importButton.exists {
            _ = importButton.waitForNonExistence(timeout: timeout)
        }
        let importSheet = app.descendants(matching: .any)["importSheet"]
        if importSheet.exists {
            _ = importSheet.waitForNonExistence(timeout: 15)
        }

        let completeNotice = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Import Complete", "Import Complete")
        ).firstMatch
        if completeNotice.waitForExistence(timeout: 30) {
            dismissAnyAlertOK(in: app, timeout: 10)
        }
    }

    func startStudyViaMenu(in app: XCUIApplication) {
        app.menuBarItems["Study"].click()
        let start = app.menuItems.identified("Start Study")
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        start.click()
        XCTAssertTrue(app.buttons.identified("primaryStudyAction").waitForExistence(timeout: 5)
            || app.buttons.identified("studySessionDone").waitForExistence(timeout: 2))
    }

    func endStudyViaMenu(in app: XCUIApplication) {
        app.menuBarItems["Study"].click()
        let end = app.menuItems.identified("End Session")
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        end.click()
        if app.buttons.identified("confirmEndStudySession").waitForExistence(timeout: 3) {
            app.buttons.identified("confirmEndStudySession").click()
        } else if let container = modalContainer(in: app) {
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
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
        XCTAssertFalse(menuItem.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func assertMenuEnabled(_ item: String, in app: XCUIApplication) {
        app.menuBarItems["File"].click()
        let menuItem = app.menuItems.identified(item)
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
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
