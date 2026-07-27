import XCTest

final class DocumentationScreenshotTests: NeoAnkiUITestCase {
    func testLibraryDeckAndAuthoringScreenshots() throws {
        let emptyApp = launchApp(databaseLabel: "docs-empty")
        captureDocumentationScreenshot(
            named: "library-empty",
            of: emptyApp,
            scenario: "empty library",
            expectedVisibleIdentifiers: ["emptyLibraryState", "addItemEmptyState"]
        )

        openAddItem(in: emptyApp)
        captureDocumentationScreenshot(
            named: "item-add",
            of: emptyApp,
            scenario: "new basic item editor",
            expectedVisibleIdentifiers: ["cancelAddItem", "field-Front", "field-Back"]
        )
        assertFormattedField(
            named: "Front",
            buttonID: "formatBold",
            style: "bold",
            text: "Spaced repetition",
            in: emptyApp
        )
        captureDocumentationScreenshot(
            named: "item-rich-text",
            of: emptyApp,
            scenario: "basic item editor with visibly bold front text",
            expectedVisibleIdentifiers: ["field-Front", "field-Front-formatBold", "saveAddItem"]
        )
        appCancelAddItem(in: emptyApp)

        addBasicItem(
            front: "What is spaced repetition?",
            back: "Reviewing information near the point of forgetting.",
            in: emptyApp
        )
        captureDocumentationScreenshot(
            named: "library-populated",
            of: emptyApp,
            scenario: "library containing one basic item",
            expectedVisibleIdentifiers: ["itemRow-What is spaced repetition?", "addItemToolbar"]
        )
        openItemDetail(named: "What is spaced repetition?", in: emptyApp)
        captureDocumentationScreenshot(
            named: "item-detail",
            of: emptyApp,
            scenario: "basic item detail",
            expectedVisibleIdentifiers: ["deleteItem", "editItem"]
        )

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
        captureDocumentationScreenshot(
            named: "decks-nested",
            of: deckApp,
            scenario: "library sidebar with nested Languages and French decks",
            expectedVisibleIdentifiers: ["deckRow-Languages", "deckRow-French"]
        )
    }

    func testMediaAuthoringScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-media", scenario: "image-missing-description")
        waitForItem(named: "Image", in: app)
        openItemDetail(named: "Image", in: app)
        app.buttons.identified("editItem").click()
        XCTAssertTrue(app.buttons.identified("saveEditItem").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "item-media",
            of: app,
            scenario: "editing an image item missing its description",
            expectedVisibleIdentifiers: ["saveEditItem", "field-Image"]
        )
    }

    func testStudyScreenshots() throws {
        let app = launchApp(databaseLabel: "docs-study")
        addBasicItem(front: "Capital of France", back: "Paris", in: app)
        startStudy(in: app)
        captureDocumentationScreenshot(
            named: "study-prompt",
            of: app,
            scenario: "study prompt before revealing the answer",
            expectedVisibleIdentifiers: ["primaryStudyAction", "gradeHelp"]
        )

        app.buttons.identified("gradeHelp").click()
        XCTAssertTrue(app.descendants(matching: .any)["gradeGuidePanel"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-grade-help",
            of: app,
            scenario: "study prompt with grading guide open",
            expectedVisibleIdentifiers: ["gradeGuidePanel", "primaryStudyAction"]
        )
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        app.buttons.identified("primaryStudyAction").click()
        XCTAssertTrue(app.buttons.identified("gradeGood").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-answer",
            of: app,
            scenario: "revealed study answer with grading controls",
            expectedVisibleIdentifiers: ["studyAnswer", "gradeGood", "gradeAgain"]
        )
        app.buttons.identified("gradeGood").click()
        XCTAssertTrue(app.buttons.identified("studySessionDone").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-complete",
            of: app,
            scenario: "completed study session",
            expectedVisibleIdentifiers: ["studySessionDone"]
        )
    }

    func testTypedStudyScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-study-type", scenario: "study-type")
        startStudy(in: app)
        enterText("London", into: app.textFields.identified("typedAnswer"), app: app)
        app.buttons.identified("primaryStudyAction").click()
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-type",
            of: app,
            scenario: "typed-answer study result",
            expectedVisibleIdentifiers: ["typedAnswer", "studyAnswer"]
        )
    }

    func testItemTypeAndTemplateScreenshots() throws {
        let app = launchApp(databaseLabel: "docs-templates")
        openTemplates(in: app)
        captureDocumentationScreenshot(
            named: "item-types",
            of: app,
            scenario: "item types and templates panel",
            expectedVisibleIdentifiers: ["templatesPanel", "addTemplateToolbar"]
        )

        app.buttons.identified("addTemplateToolbar").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "template-editor",
            of: app,
            scenario: "new template editor",
            expectedVisibleIdentifiers: ["templateNameField", "templatePromptField", "templateAnswerField"]
        )

        let advancedApp = launchApp(
            databaseLabel: "docs-template-advanced",
            environment: ["NEOANKI_TEST_EXPAND_TEMPLATE_ADVANCED": "1"]
        )
        openTemplates(in: advancedApp)
        advancedApp.buttons.identified("addTemplateToolbar").click()
        XCTAssertTrue(advancedApp.textFields.identified("templateNameField").waitForExistence(timeout: 5))
        enterText(
            "Custom practice card",
            into: advancedApp.textFields.identified("templateNameField"),
            app: advancedApp
        )
        advancedApp.descendants(matching: .any).identified("templateAutomaticSkill").click()
        XCTAssertTrue(advancedApp.popUpButtons.identified("templateSkillInput").waitForExistence(timeout: 3))
        advancedApp.descendants(matching: .any).identified("templateGenerateCondition").click()
        advancedApp.descendants(matching: .any).identified("templateGenerateCondition")
            .scroll(byDeltaX: 0, deltaY: 350)
        captureDocumentationScreenshot(
            named: "template-advanced",
            of: advancedApp,
            scenario: "advanced template editor with explicit skill mapping and generation rule",
            expectedVisibleIdentifiers: [
                "templateAdvancedSettings",
                "templateSkillInput",
                "templateSkillOutput",
                "templateSkillOperation",
                "templateGenerateCondition",
            ]
        )
    }

    func testImportAndConflictScreenshots() throws {
        let importFile = try makeImportFixture(
            name: "documentation.csv",
            contents: "Front,Back\nImported question,Imported answer\n"
        )
        let importApp = launchAppForImport(file: importFile, scenario: "alternate-import-type")
        XCTAssertTrue(importApp.descendants(matching: .any)["importSheet"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "import-sheet",
            of: importApp,
            scenario: "CSV import mapping sheet",
            expectedVisibleIdentifiers: ["importSheet", "confirmImport"]
        )

        let conflictApp = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )
        XCTAssertTrue(
            conflictApp.buttons.identified("portableDeckConflictUseLocal").waitForExistence(timeout: 10)
        )
        captureDocumentationScreenshot(
            named: "portable-conflict",
            of: conflictApp,
            scenario: "portable deck item-type conflict",
            expectedVisibleIdentifiers: ["portableDeckConflictUseLocal", "portableDeckConflictImportNew"]
        )
    }

    func testSchedulingScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-scheduling", scenario: "scheduling-history")
        app.menuBarItems["Scheduling"].click()
        app.menuItems.identified("Optimize Scheduling…").click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 20))
        captureDocumentationScreenshot(
            named: "scheduling-result",
            of: app,
            scenario: "scheduling optimization result sheet",
            expectedVisibleIdentifiers: ["action-button-1"]
        )
    }

    func testStartupErrorScreenshot() throws {
        let app = launchApp(
            databaseLabel: "docs-error",
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )
        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitForExistence(timeout: 5))
        captureDocumentationScreenshot(
            named: "error-startup",
            of: app,
            scenario: "database bootstrap failure",
            expectedVisibleIdentifiers: ["bootstrapError"]
        )
    }

    private func appCancelAddItem(in app: XCUIApplication) {
        app.buttons.identified("cancelAddItem").click()
        if app.buttons.identified("confirmDiscardItem").waitForExistence(timeout: 2) {
            app.buttons.identified("confirmDiscardItem").click()
        }
        waitForLibraryReady(in: app)
    }
}
