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
        selectScope("deckRow-Poetry Lab", in: contextualApp)
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

        let topLevelTarget = deckApp.descendants(matching: .any)
            .identified("deckTopLevelDropTarget")
        XCTAssertTrue(topLevelTarget.waitUntilExists(timeout: 3))
        childDeck.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
            .press(
                forDuration: 0.6,
                thenDragTo: topLevelTarget.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                )
            )

        XCTAssertTrue(
            waitUntil(timeout: 5) {
                childDeck.exists && abs(childDeck.frame.minX - parent.frame.minX) < 4
            },
            "Dragging French to the Decks heading should move it to the top level"
        )

        childDeck.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
            .press(
                forDuration: 0.6,
                thenDragTo: parent.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                )
            )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                childDeck.exists && childDeck.frame.minX > parent.frame.minX + 4
            },
            "Dropping French in the center of Languages should indent it as a subdeck"
        )

        let disclosureAfterMovingIn = deckApp.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosureAfterMovingIn.waitUntilExists(timeout: 3))
        disclosureAfterMovingIn.click()
        XCTAssertTrue(
            childDeck.waitUntilGone(timeout: 5),
            "Dropping French in the center of Languages should make it a subdeck"
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
            expectedVisibleIdentifiers: ["gradeGood", "gradeAgain"]
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
            expectedVisibleIdentifiers: ["gradeGood"]
        )
    }

    func testItemTypeAndCardSetupScreenshots() throws {
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
        app.buttons.identified("editItemType").click()
        XCTAssertTrue(app.textFields.identified("itemTypeStudioName").waitUntilExists(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .identified("itemTypeStudioCardSetupEditor")
                .waitUntilExists(timeout: 5)
        )
        let basicEditorScroll = app.scrollViews.identified("cardSetupEditor")
        let showAnswer = app.buttons.identified("cardSetupEditor.showAnswer")
        let editorWindow = app.windows.firstMatch
        XCTAssertTrue(basicEditorScroll.waitUntilExists(timeout: 3))
        XCTAssertTrue(showAnswer.waitUntilExists(timeout: 3))
        XCTAssertTrue(editorWindow.waitUntilExists(timeout: 3))
        for _ in 0..<4 where !editorWindow.frame.contains(showAnswer.frame) {
            basicEditorScroll.scroll(byDeltaX: 0, deltaY: -100)
        }
        XCTAssertTrue(
            editorWindow.frame.contains(showAnswer.frame),
            "Template editor screenshot must fully show the answer-preview control"
        )
        captureDocumentationScreenshot(
            named: "template-editor",
            of: app,
            scenario: "unified Item Type Studio with Fields, Card setups, and a fillable wireframe",
            expectedVisibleIdentifiers: [
                "itemTypeStudioOutline",
                "itemTypeStudioCardSetupEditor",
                "cardSetupEditor.layoutPicker",
                "cardSetupEditor.showAnswer",
            ]
        )

        let advancedApp = launchApp(databaseLabel: "docs-template-advanced")
        openTemplates(in: advancedApp)
        openItemTypeStudio(named: "Basic", in: advancedApp)
        let advancedSettings = advancedApp.descendants(matching: .any)
            .identified("cardSetupEditor.advanced")
        XCTAssertTrue(advancedSettings.waitUntilExists(timeout: 5))
        advancedSettings.click()
        XCTAssertEqual(advancedSettings.value as? String, "Expanded")
        let editorScroll = advancedApp.scrollViews.identified("cardSetupEditor")
        XCTAssertTrue(editorScroll.waitUntilExists(timeout: 3))
        let availability = advancedApp.descendants(matching: .any)
            .identified("cardSetupEditor.availability")
        let learningRoute = advancedApp.descendants(matching: .any)
            .identified("cardSetupEditor.learningRoute")
        let advancedWindow = advancedApp.windows.firstMatch
        XCTAssertTrue(advancedWindow.waitUntilExists(timeout: 3))
        for _ in 0..<6 where !availability.exists
            || !learningRoute.exists
            || !availability.frame.intersects(advancedWindow.frame)
            || !learningRoute.frame.intersects(advancedWindow.frame) {
            editorScroll.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(
            availability.waitUntilExists(timeout: 3)
                && availability.frame.intersects(advancedWindow.frame),
            "Advanced screenshot must visibly include Availability controls"
        )
        XCTAssertTrue(
            learningRoute.waitUntilExists(timeout: 3)
                && learningRoute.frame.intersects(advancedWindow.frame),
            "Advanced screenshot must visibly include Learning route controls"
        )
        captureDocumentationScreenshot(
            named: "template-advanced",
            of: advancedApp,
            scenario: "Item Type Studio Advanced Availability and Learning route controls",
            expectedVisibleIdentifiers: [
                "itemTypeStudioCardSetupEditor",
                "cardSetupEditor.advanced",
                "cardSetupEditor.availability",
                "cardSetupEditor.learningRoute",
                "saveItemTypeStudio",
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
