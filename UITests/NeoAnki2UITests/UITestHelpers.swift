import XCTest

@MainActor
class NeoAnkiUITestCase: XCTestCase {
    var runningApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let failure = testRun?.failureCount, failure > 0, let runningApp {
            let attachment = XCTAttachment(screenshot: runningApp.screenshot())
            attachment.name = "\(name)-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        runningApp?.terminate()
        runningApp = nil
        try super.tearDownWithError()
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
        if waitForLibrary {
            waitForLibraryReady(in: app)
        }
        return app
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
        if app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'itemRow-'")
        ).firstMatch.exists {
            return true
        }
        let emptyTitles = ["No Items Yet", "No Unassigned Items", "No Items in Deck"]
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
        app.menuItems["Item Types…"].click()

        let done = app.buttons["templatesDone"]
        if !done.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 2))
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
        if app.buttons["addItemTypeToolbar"].waitForExistence(timeout: 3) {
            app.buttons["addItemTypeToolbar"].click()
            return
        }
        if app.buttons["addItemTypeEmptyState"].waitForExistence(timeout: 2) {
            app.buttons["addItemTypeEmptyState"].click()
            return
        }
        XCTFail("Add item type control not found")
    }

    func openTemplateEditor(named name: String, in app: XCUIApplication) {
        let edit = app.buttons["editTemplate-\(name)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(app.textFields["templateNameField"].waitForExistence(timeout: 10))
    }

    func closeTemplates(in app: XCUIApplication) {
        if app.buttons["templatesDone"].exists {
            app.buttons["templatesDone"].click()
            return
        }
        if app.buttons["Done"].exists {
            app.buttons["Done"].click()
            return
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
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
        let save = app.buttons["saveAddItem"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
    }

    func waitForItem(named title: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let row = app.descendants(matching: .any)["itemRow-\(title)"]
        if row.waitForExistence(timeout: timeout) {
            return
        }

        let labelPredicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let match = app.descendants(matching: .any).matching(labelPredicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
    }

    func field(named name: String, in app: XCUIApplication) -> XCUIElement {
        let id = "field-\(name)"
        let textView = app.textViews[id]
        if textView.waitForExistence(timeout: 2) {
            return textView
        }
        let textField = app.textFields[id]
        if textField.waitForExistence(timeout: 1) {
            return textField
        }
        return app.descendants(matching: .any)[id]
    }

    func returnToLibrary(in app: XCUIApplication) {
        if app.buttons["studySessionDone"].exists {
            app.buttons["studySessionDone"].click()
        }
        if app.buttons["studyBackToItems"].exists {
            app.buttons["studyBackToItems"].click()
        }
        if app.buttons["cancelAddItem"].exists {
            app.buttons["cancelAddItem"].click()
        }
        if app.buttons["templatesDone"].exists {
            app.buttons["templatesDone"].click()
        }
        if app.buttons["cancelTemplateEditor"].exists {
            app.buttons["cancelTemplateEditor"].click()
        }
        if app.buttons["deleteItem"].exists {
            showSidebar(in: app)
            let unassigned = app.descendants(matching: .any)["scopeRow-Unassigned"]
            let allDecks = app.descendants(matching: .any)["scopeRow-AllDecks"]
            if unassigned.waitForExistence(timeout: 2), allDecks.waitForExistence(timeout: 2) {
                unassigned.click()
                _ = app.buttons["deleteItem"].waitForNonExistence(timeout: 5)
                allDecks.click()
            } else {
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            }
            _ = app.buttons["deleteItem"].waitForNonExistence(timeout: 5)
        }
        waitForLibraryReady(in: app)
    }

    func openAddItem(in app: XCUIApplication) {
        returnToLibrary(in: app)
        if app.buttons["addItemEmptyState"].waitForExistence(timeout: 2) {
            app.buttons["addItemEmptyState"].click()
        } else {
            let add = app.buttons["addItemToolbar"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.click()
        }

        XCTAssertTrue(field(named: "Front", in: app).waitForExistence(timeout: 5))
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
        _ = app.buttons["newDeckToolbar"].waitForExistence(timeout: 3)
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
        let row = app.descendants(matching: .any)[identifier]
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

        let loading = app.staticTexts["Loading items…"]
        if loading.exists {
            XCTAssertTrue(loading.waitForNonExistence(timeout: 10))
        }
        waitForLibraryReady(in: app)
    }

    func createDeck(named name: String, in app: XCUIApplication) {
        showSidebar(in: app)
        let newDeck = app.buttons["newDeckToolbar"]
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

        if app.buttons["confirmCreateDeck"].waitForExistence(timeout: 2) {
            app.buttons["confirmCreateDeck"].click()
        } else if container.buttons["Create"].exists {
            container.buttons["Create"].click()
        }

        let deckAppeared = app.descendants(matching: .any)["deckRow-\(name)"].waitForExistence(timeout: 10)
            || app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", name)
            ).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(deckAppeared)
    }

    func openItemDetail(named title: String, in app: XCUIApplication) {
        returnToLibrary(in: app)
        let row = app.descendants(matching: .any)["itemRow-\(title)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
        XCTAssertTrue(app.buttons["deleteItem"].waitForExistence(timeout: 15))
    }

    func startStudy(in app: XCUIApplication) {
        let studyButton = app.buttons["studyButton"]
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(studyButton.isEnabled)
        studyButton.click()
        XCTAssertTrue(app.buttons["primaryStudyAction"].waitForExistence(timeout: 5)
            || app.buttons["studySessionDone"].waitForExistence(timeout: 2))
    }

    func revealAndGrade(_ gradeID: String, in app: XCUIApplication) {
        if app.buttons["primaryStudyAction"].waitForExistence(timeout: 2) {
            app.buttons["primaryStudyAction"].click()
        }
        let gradeButton = app.buttons[gradeID]
        XCTAssertTrue(gradeButton.waitForExistence(timeout: 5))
        gradeButton.click()
    }

    func finishStudySession(in app: XCUIApplication) {
        if app.buttons["studySessionDone"].waitForExistence(timeout: 5) {
            app.buttons["studySessionDone"].click()
        } else if app.buttons["studyBackToItems"].waitForExistence(timeout: 2) {
            app.buttons["studyBackToItems"].click()
        }
        waitForLibraryReady(in: app)
    }

    func waitForFormattedField(
        _ fieldName: String,
        containing expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let mirror = app.descendants(matching: .any)["field-\(fieldName)-spans"]
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

        let formatButton = app.buttons["field-\(fieldName)-\(buttonID)"]
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
        app.menuBarItems["File"].click()
        let importItem = app.menuItems["Import…"]
        XCTAssertTrue(importItem.waitForExistence(timeout: 3))
        importItem.click()

        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.sheets.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.typeText(url.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    }
}
