import XCTest

/// The Store review runner launches the optimized sandboxed application without
/// fixture arguments. Its caller owns a fresh container and preserves the result.
final class MacStoreProductionReviewJourneyTests: NeoAnkiUITestCase {
    func testFreshInstallCreateStudyAndPersistence() throws {
        guard ProcessInfo.processInfo.environment["NEOANKI_MAC_STORE_REVIEW"] == "1" else {
            throw XCTSkip("Run through Scripts/review-macos-app.py against the Store candidate")
        }
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        runningApp = app
        defer { app.terminate() }
        app.launch()
        waitForLibraryReady(in: app)
        assertEmptyLibrary(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["emptyLibraryState"].waitUntilExists(timeout: 5),
                      "A fresh Store container must contain no study items")
        storeCapture("01-native-mac-first-launch", app)
        addBasicItem(front: "What does spaced repetition improve?", back: "Long-term recall.", in: app)
        waitForItem(named: "What does spaced repetition improve?", in: app)
        storeCapture("02-native-mac-library", app)
        leaveBrowseMode(in: app)
        startStudyViaMenu(in: app)
        storeCapture("03-native-mac-study", app)
        let action = app.buttons.identified("primaryStudyAction")
        XCTAssertTrue(action.waitUntilExists(timeout: 5), "The new card must be available to study")
        action.click()
        XCTAssertTrue(app.staticTexts["Long-term recall."].waitUntilExists(timeout: 5))
        storeCapture("04-native-mac-answer", app)
        let grade = app.buttons.identified("gradeEasy")
        XCTAssertTrue(grade.waitUntilExists(timeout: 5))
        grade.click()
        XCTAssertTrue(app.buttons.identified("studySessionDone").waitUntilExists(timeout: 10))
        app.terminate()
        app.launch()
        waitForLibraryReady(in: app)
        waitForItem(named: "What does spaced repetition improve?", in: app)
        storeCapture("05-native-mac-persistence", app)
    }

    private func storeCapture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
