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
        frontField.click()
        frontField.typeText("France")

        let backField = app.textFields["field-Back"]
        backField.click()
        backField.typeText("Paris")

        app.buttons["saveAddItem"].click()

        let itemRow = app.staticTexts["France"]
        XCTAssertTrue(itemRow.waitForExistence(timeout: 5))
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
        frontField.click()
        frontField.typeText("Alpha")

        app.textFields["field-Back"].click()
        app.textFields["field-Back"].typeText("Beta")

        app.buttons["saveAddItem"].click()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5))

        app.terminate()
        runningApp = nil

        let relaunched = launchApp(databaseLabel: databaseLabel)
        XCTAssertTrue(relaunched.staticTexts["Alpha"].waitForExistence(timeout: 5))
    }

    func testStudyBasicItemFlow() throws {
        let app = launchApp()

        app.buttons["addItemEmptyState"].click()

        let frontField = app.textFields["field-Front"]
        XCTAssertTrue(frontField.waitForExistence(timeout: 5))
        frontField.click()
        frontField.typeText("France")

        app.textFields["field-Back"].click()
        app.textFields["field-Back"].typeText("Paris")

        app.buttons["saveAddItem"].click()
        XCTAssertTrue(app.staticTexts["France"].waitForExistence(timeout: 5))

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
}
