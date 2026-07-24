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
        let app = launchApp(databaseLabel: "persistence")

        app.buttons["addItemEmptyState"].click()

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

        let relaunched = launchApp(databaseLabel: "persistence")
        XCTAssertTrue(relaunched.staticTexts["Alpha"].waitForExistence(timeout: 5))
    }
}
