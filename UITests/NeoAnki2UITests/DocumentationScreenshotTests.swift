import XCTest

final class DocumentationScreenshotTests: NeoAnkiUITestCase {
    func testLibraryDeckAndAuthoringScreenshots() throws {
        let emptyApp = launchApp(databaseLabel: "docs-empty")
        captureDocumentationScreenshot(named: "library-empty", of: emptyApp)

        openAddItem(in: emptyApp)
        captureDocumentationScreenshot(named: "item-add", of: emptyApp)
        enterText("What is spaced repetition?", into: field(named: "Front", in: emptyApp), app: emptyApp)
        captureDocumentationScreenshot(named: "item-rich-text", of: emptyApp)
        appCancelAddItem(in: emptyApp)

        addBasicItem(
            front: "What is spaced repetition?",
            back: "Reviewing information near the point of forgetting.",
            in: emptyApp
        )
        captureDocumentationScreenshot(named: "library-populated", of: emptyApp)
        openItemDetail(named: "What is spaced repetition?", in: emptyApp)
        captureDocumentationScreenshot(named: "item-detail", of: emptyApp)

        let deckApp = launchApp(databaseLabel: "docs-decks", scenario: "deck-with-due-items")
        showSidebar(in: deckApp)
        createDeck(named: "Languages", in: deckApp)
        let parent = deckApp.descendants(matching: .any).identified("deckRow-Languages")
        parent.rightClick()
        deckApp.menuItems.identified("New Subdeck").click()
        if let container = modalContainer(in: deckApp) {
            enterText("French", into: container.textFields.firstMatch, app: deckApp)
            deckApp.buttons.identified("confirmCreateDeck").click()
        }
        captureDocumentationScreenshot(named: "decks-nested", of: deckApp)
    }

    func testMediaAuthoringScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-media", scenario: "image-missing-description")
        waitForItem(named: "Image", in: app)
        openItemDetail(named: "Image", in: app)
        app.buttons.identified("editItem").click()
        XCTAssertTrue(app.buttons.identified("saveEditItem").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "item-media", of: app)
    }

    func testStudyScreenshots() throws {
        let app = launchApp(databaseLabel: "docs-study")
        addBasicItem(front: "Capital of France", back: "Paris", in: app)
        startStudy(in: app)
        captureDocumentationScreenshot(named: "study-prompt", of: app)

        app.buttons.identified("gradeHelp").click()
        XCTAssertTrue(app.descendants(matching: .any)["gradeGuidePanel"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "study-grade-help", of: app)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        app.buttons.identified("primaryStudyAction").click()
        XCTAssertTrue(app.buttons.identified("gradeGood").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "study-answer", of: app)
        app.buttons.identified("gradeGood").click()
        XCTAssertTrue(app.buttons.identified("studySessionDone").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "study-complete", of: app)
    }

    func testTypedStudyScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-study-type", scenario: "study-type")
        startStudy(in: app)
        enterText("London", into: app.textFields.identified("typedAnswer"), app: app)
        app.buttons.identified("primaryStudyAction").click()
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "study-type", of: app)
    }

    func testItemTypeAndTemplateScreenshots() throws {
        let app = launchApp(databaseLabel: "docs-templates")
        openTemplates(in: app)
        captureDocumentationScreenshot(named: "item-types", of: app)

        app.buttons.identified("addTemplateToolbar").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "template-editor", of: app)

        let advanced = app.descendants(matching: .any).identified("templateAdvancedSettings")
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()
        XCTAssertTrue(app.descendants(matching: .any)["templateAutomaticSkill"].waitForExistence(timeout: 3))
        captureDocumentationScreenshot(named: "template-advanced", of: app)
    }

    func testImportAndConflictScreenshots() throws {
        let importFile = try makeImportFixture(
            name: "documentation.csv",
            contents: "Front,Back\nImported question,Imported answer\n"
        )
        let importApp = launchAppForImport(file: importFile, scenario: "alternate-import-type")
        XCTAssertTrue(importApp.descendants(matching: .any)["importSheet"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "import-sheet", of: importApp)

        let conflictApp = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )
        XCTAssertTrue(
            conflictApp.buttons.identified("portableDeckConflictUseLocal").waitForExistence(timeout: 10)
        )
        captureDocumentationScreenshot(named: "portable-conflict", of: conflictApp)
    }

    func testSchedulingScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-scheduling", scenario: "scheduling-history")
        app.menuBarItems["Scheduling"].click()
        app.menuItems.identified("Optimize Scheduling…").click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 20))
        captureDocumentationScreenshot(named: "scheduling-result", of: app)
    }

    func testStartupErrorScreenshot() throws {
        let app = launchApp(
            databaseLabel: "docs-error",
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )
        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(named: "error-startup", of: app)
    }

    private func appCancelAddItem(in app: XCUIApplication) {
        app.buttons.identified("cancelAddItem").click()
        if app.buttons.identified("confirmDiscardItem").waitForExistence(timeout: 2) {
            app.buttons.identified("confirmDiscardItem").click()
        }
        waitForLibraryReady(in: app)
    }
}
