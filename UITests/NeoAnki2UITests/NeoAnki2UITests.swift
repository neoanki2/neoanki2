import XCTest

final class NeoAnki2UITests: XCTestCase {
    private var runningApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        runningApp?.terminate()
        runningApp = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func launchApp(databaseLabel: String = UUID().uuidString) -> XCUIApplication {
        runningApp?.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-NeoAnkiTesting"]
        app.launchEnvironment["NEOANKI_TESTING"] = "1"
        app.launchEnvironment["NEOANKI_TEST_DB_DIR"] = NSTemporaryDirectory() + "neoanki2-ui-\(databaseLabel)"
        app.launch()

        runningApp = app
        return app
    }

    private func openTemplates(in app: XCUIApplication) {
        if app.buttons["templatesToolbar"].waitForExistence(timeout: 2) {
            app.buttons["templatesToolbar"].click()
        } else {
            app.menuBarItems["Library"].click()
            app.menuItems["Item Types…"].click()
        }

        let done = app.buttons["templatesDone"]
        if !done.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 2))
        }
    }

    private func closeTemplates(in app: XCUIApplication) {
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

    private func enterText(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        field.click()
        field.typeKey("a", modifierFlags: [.command])
        field.typeText(text)
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
    }

    private func saveAddItem(in app: XCUIApplication) {
        let save = app.buttons["saveAddItem"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
    }

    private func waitForItem(named title: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let row = app.descendants(matching: .any)["itemRow-\(title)"]
        if row.waitForExistence(timeout: timeout) {
            return
        }

        let labelPredicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let match = app.descendants(matching: .any).matching(labelPredicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
    }

    func testAppLaunchesWithEmptyLibrary() throws {
        let app = launchApp()

        let emptyState = app.staticTexts["No Items Yet"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
    }

    func testAddItemFromEmptyState() throws {
        let app = launchApp()

        let addButton = app.buttons["addItemEmptyState"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let frontField = app.textFields["field-Front"]
        XCTAssertTrue(frontField.waitForExistence(timeout: 5))
        enterText("France", into: frontField, app: app)

        let backField = app.textFields["field-Back"]
        enterText("Paris", into: backField, app: app)

        saveAddItem(in: app)

        waitForItem(named: "France", in: app)
    }

    func testAddItemFromToolbar() throws {
        let databaseLabel = UUID().uuidString
        let app = launchApp(databaseLabel: databaseLabel)

        if app.buttons["addItemEmptyState"].waitForExistence(timeout: 2) {
            app.buttons["addItemEmptyState"].click()
        } else {
            app.buttons["addItemToolbar"].click()
        }

        let frontField = app.textFields["field-Front"]
        XCTAssertTrue(frontField.waitForExistence(timeout: 5))
        enterText("Alpha", into: frontField, app: app)
        enterText("Beta", into: app.textFields["field-Back"], app: app)

        saveAddItem(in: app)
        waitForItem(named: "Alpha", in: app)

        app.terminate()
        runningApp = nil

        let relaunched = launchApp(databaseLabel: databaseLabel)
        waitForItem(named: "Alpha", in: relaunched)
    }

    func testStudyBasicItemFlow() throws {
        let app = launchApp()

        app.buttons["addItemEmptyState"].click()

        let frontField = app.textFields["field-Front"]
        XCTAssertTrue(frontField.waitForExistence(timeout: 5))
        enterText("France", into: frontField, app: app)
        enterText("Paris", into: app.textFields["field-Back"], app: app)

        saveAddItem(in: app)
        waitForItem(named: "France", in: app)

        let studyButton = app.buttons["studyButton"]
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(studyButton.isEnabled)
        studyButton.click()

        let showAnswer = app.buttons["showAnswer"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 5))
        showAnswer.click()

        let gradeGood = app.buttons["gradeGood"]
        XCTAssertTrue(gradeGood.waitForExistence(timeout: 5))
        gradeGood.click()

        let studyDone = app.buttons["studySessionDone"]
        XCTAssertTrue(studyDone.waitForExistence(timeout: 5))
        studyDone.click()

        let studyButtonAfter = app.buttons["studyButton"]
        XCTAssertTrue(studyButtonAfter.waitForExistence(timeout: 5))
        XCTAssertFalse(studyButtonAfter.isEnabled)
    }

    func testTemplatesOpensAndShowsBasicTemplate() throws {
        let app = launchApp()

        openTemplates(in: app)

        XCTAssertTrue(app.staticTexts["Types"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["templateRow-Card"].waitForExistence(timeout: 5))

        closeTemplates(in: app)
        XCTAssertTrue(
            app.staticTexts["No Items Yet"].waitForExistence(timeout: 5)
                || app.staticTexts["Ready to Study"].waitForExistence(timeout: 2)
        )
    }

    func testTemplatesLayoutDoesNotOverlapColumns() throws {
        let app = launchApp()

        openTemplates(in: app)

        let basicRow = app.descendants(matching: .any)["itemTypeRow-Basic"]
        let cardTemplate = app.buttons["templateRow-Card"]
        let detailTitle = app.staticTexts["templatesDetailTitle-Basic"]

        XCTAssertTrue(basicRow.waitForExistence(timeout: 5))
        XCTAssertTrue(cardTemplate.waitForExistence(timeout: 5))

        XCTAssertLessThan(basicRow.frame.maxX, cardTemplate.frame.minX)

        if detailTitle.waitForExistence(timeout: 2) {
            XCTAssertLessThan(basicRow.frame.maxX, detailTitle.frame.minX)
        }

        closeTemplates(in: app)
    }

    func testTemplatesAddReverseTemplate() throws {
        let app = launchApp()

        openTemplates(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitForExistence(timeout: 5))

        let addTemplate = app.buttons["addTemplateToolbar"]
        if !addTemplate.waitForExistence(timeout: 2) {
            XCTAssertTrue(app.buttons["Add Template"].waitForExistence(timeout: 5))
            app.buttons["Add Template"].click()
        } else {
            addTemplate.click()
        }

        let nameField = app.textFields["templateNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Reverse")

        let promptPicker = app.popUpButtons["templatePromptField"]
        XCTAssertTrue(promptPicker.waitForExistence(timeout: 5))
        promptPicker.click()
        app.menuItems["Back"].click()

        let answerPicker = app.popUpButtons["templateAnswerField"]
        XCTAssertTrue(answerPicker.waitForExistence(timeout: 5))
        answerPicker.click()
        app.menuItems["Front"].click()

        app.buttons["saveTemplate"].click()

        XCTAssertTrue(app.buttons["templateRow-Reverse"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }
}
