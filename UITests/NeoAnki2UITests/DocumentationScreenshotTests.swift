import XCTest

final class DocumentationScreenshotTests: NeoAnkiUITestCase {
    func testLibraryDeckAndAuthoringScreenshots() throws {
        let emptyApp = launchApp(databaseLabel: "docs-empty")
        captureDocumentationScreenshot(
            named: "library-empty",
            of: emptyApp,
            scenario: "empty library",
            expectedVisibleIdentifiers: ["emptyLibraryState"]
        )

        openAddItem(in: emptyApp)
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
            scenario: "browse mode listing one basic item",
            expectedVisibleIdentifiers: [
                "itemBrowserTable",
                "itemRow-What is spaced repetition?",
                "addItemToolbar",
            ]
        )
        openItemDetail(named: "What is spaced repetition?", in: emptyApp)
        captureDocumentationScreenshot(
            named: "item-detail",
            of: emptyApp,
            scenario: "basic item detail",
            expectedVisibleIdentifiers: ["deleteItem", "editItem"]
        )
        emptyApp.terminate()

        let contextualApp = launchApp(
            databaseLabel: "docs-item-add",
            scenario: "deck-included-item-types"
        )
        showSidebar(in: contextualApp)
        contextualApp.descendants(matching: .any)
            .identified("deckRow-Poetry Lab")
            .click()
        openAddItem(in: contextualApp, waitForDefaultField: false)
        captureDocumentationScreenshot(
            named: "item-add",
            of: contextualApp,
            scenario: "new item editor using the deck's recommended included type",
            expectedVisibleIdentifiers: [
                "addItemDeckPicker",
                "addItemTypePicker",
                "field-Previous Lines",
                "field-Next Line",
            ]
        )
        appCancelAddItem(in: contextualApp)
        contextualApp.terminate()

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
        let childDeck = deckApp.descendants(matching: .any).identified("deckRow-French")
        if !childDeck.waitUntilExists(timeout: 1) {
            let disclosure = deckApp.disclosureTriangles.firstMatch
            XCTAssertTrue(disclosure.waitUntilExists(timeout: 3))
            disclosure.click()
        }
        XCTAssertTrue(childDeck.waitUntilExists(timeout: 5))
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
        openItemEditor(in: app)
        XCTAssertTrue(app.buttons.identified("saveEditItem").waitUntilExists(timeout: 5))
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
        XCTAssertTrue(app.descendants(matching: .any)["gradeGuidePanel"].waitUntilExists(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-grade-help",
            of: app,
            scenario: "study prompt with grading guide open",
            expectedVisibleIdentifiers: ["gradeGuidePanel", "primaryStudyAction"]
        )
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-answer",
            of: app,
            scenario: "revealed study answer with grading controls",
            expectedVisibleIdentifiers: ["studyAnswer", "gradeGood", "gradeAgain"]
        )
        revealAndGrade("gradeGood", in: app)
        XCTAssertTrue(app.buttons.identified("studySessionDone").waitUntilExists(timeout: 5))
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
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitUntilExists(timeout: 5))
        captureDocumentationScreenshot(
            named: "study-type",
            of: app,
            scenario: "typed-answer study result",
            expectedVisibleIdentifiers: ["studyAnswer", "gradeGood"]
        )
    }

    func testItemTypeAndTemplateScreenshots() throws {
        let app = launchApp(
            databaseLabel: "docs-templates",
            scenario: "deck-included-item-types"
        )
        openTemplates(in: app)
        let includedDeckGroup = app.buttons.identified("includedDeckGroup-Poetry Lab")
        XCTAssertTrue(includedDeckGroup.waitUntilExists(timeout: 5))
        includedDeckGroup.click()
        let includedItemType = app.descendants(matching: .any)
            .identified("includedItemTypeRow-Poem Line")
        XCTAssertTrue(includedItemType.waitUntilExists(timeout: 5))
        includedItemType.click()
        XCTAssertTrue(app.buttons.identified("unlockIncludedItemType").waitUntilExists(timeout: 5))
        captureDocumentationScreenshot(
            named: "item-types",
            of: app,
            scenario: "deck-provided item type with its owner and unlock action",
            expectedVisibleIdentifiers: [
                "templatesDone",
                "includedItemTypeOwner",
                "unlockIncludedItemType",
                "duplicateIncludedItemType",
            ]
        )

        app.descendants(matching: .any).identified("itemTypeRow-Basic").click()
        app.buttons.identified("addTemplateToolbar").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").waitUntilExists(timeout: 5))
        captureDocumentationScreenshot(
            named: "template-editor",
            of: app,
            scenario: "new template editor",
            expectedVisibleIdentifiers: ["templateNameField", "templatePromptField", "templateAnswerField"]
        )

        let advancedApp = launchApp(databaseLabel: "docs-template-advanced")
        openTemplates(in: advancedApp)
        openTemplateEditor(named: "Card", in: advancedApp)
        XCTAssertTrue(advancedApp.textFields.identified("templateNameField").waitUntilExists(timeout: 5))
        let advancedSettings = advancedApp.descendants(matching: .any)
            .identified("templateAdvancedSettings")
        XCTAssertTrue(advancedSettings.waitUntilExists(timeout: 5))
        let advancedForm = advancedApp.descendants(matching: .any)
            .identified("templateEditorForm")
        XCTAssertTrue(advancedForm.waitUntilExists(timeout: 3))
        // A form taller than the display has no hit point, so no gesture can be
        // placed on the form itself. This nudge is only to bring the answer
        // controls closer; scrolling by that element below is what the capture
        // actually depends on, so skip it rather than fail the run.
        if advancedForm.isHittable {
            advancedForm.swipeUp()
        }
        let answerReveal = advancedApp.popUpButtons.identified("answerSlotReveal")
        XCTAssertTrue(answerReveal.waitUntilExists(timeout: 5))
        answerReveal.scroll(byDeltaX: 0, deltaY: 240)
        captureDocumentationScreenshot(
            named: "template-advanced",
            of: advancedApp,
            scenario: "advanced template editor with answer reveal controls and advanced settings entry point",
            expectedVisibleIdentifiers: [
                "answerSlotSource",
                "answerSlotReveal",
                "templateAdvancedSettings",
                "saveTemplate",
            ]
        )
    }

    func testImportAndConflictScreenshots() throws {
        let importFile = try makeImportFixture(
            name: "documentation.csv",
            contents: "Front,Back\nImported question,Imported answer\n"
        )
        let importApp = launchAppForImport(file: importFile, scenario: "alternate-import-type")
        XCTAssertTrue(importApp.descendants(matching: .any)["importSheet"].waitUntilExists(timeout: 5))
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
            conflictApp.buttons.identified("portableDeckConflictUseLocal").waitUntilExists(timeout: 10)
        )
        captureDocumentationScreenshot(
            named: "portable-conflict",
            of: conflictApp,
            scenario: "portable deck item-type conflict",
            expectedVisibleIdentifiers: ["portableDeckConflictUseLocal", "portableDeckConflictImportNew"]
        )
    }

    /// There is no optimization result to photograph: fitting is automatic and
    /// silent. What the guide has to show instead is the end of a session that
    /// refitted — an ordinary library, with nothing asking to be dismissed.
    func testSchedulingScreenshot() throws {
        let app = launchApp(databaseLabel: "docs-scheduling", scenario: "scheduling-history")
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        endStudyViaMenu(in: app)
        captureDocumentationScreenshot(
            named: "scheduling-result",
            of: app,
            scenario: "library after a session that refitted scheduling, with no prompt",
            expectedVisibleIdentifiers: ["scopeHome", "scopeHomeDueHeadline"]
        )
    }

    func testStartupErrorScreenshot() throws {
        let app = launchApp(
            databaseLabel: "docs-error",
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )
        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitUntilExists(timeout: 5))
        captureDocumentationScreenshot(
            named: "error-startup",
            of: app,
            scenario: "database bootstrap failure",
            expectedVisibleIdentifiers: ["bootstrapError"]
        )
    }

    private func appCancelAddItem(in app: XCUIApplication) {
        app.buttons.identified("cancelAddItem").click()
        if app.buttons.identified("confirmDiscardItem").waitUntilExists(timeout: 2) {
            app.buttons.identified("confirmDiscardItem").click()
        }
        waitForLibraryReady(in: app)
    }
}
