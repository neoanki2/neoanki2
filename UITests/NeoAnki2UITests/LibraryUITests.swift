import XCTest

final class LibraryUITests: NeoAnkiUITestCase {
    func testBootstrapFailureShowsSafeErrorState() throws {
        let app = launchApp(
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )

        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Could Not Start"].exists)
        XCTAssertFalse(app.buttons.identified("addItemToolbar").exists)
    }

    func testAppLaunchesWithEmptyLibrary() throws {
        let app = launchApp()
        assertEmptyLibrary(in: app)
    }

    func testAddItemFromEmptyState() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
    }

    func testAddItemFromToolbar() throws {
        let databaseLabel = UUID().uuidString
        let app = launchApp(databaseLabel: databaseLabel)
        addBasicItem(front: "Alpha", back: "Beta", in: app)

        app.terminate()
        runningApp = nil

        let relaunched = launchApp(databaseLabel: databaseLabel)
        waitForItem(named: "Alpha", in: relaunched)
    }

    func testRichTextEditorFormattingButtonsApplyStyles() throws {
        let app = launchApp()
        openAddItem(in: app)

        assertFormattedField(named: "Front", buttonID: "formatBold", style: "bold", text: "BoldWord", in: app)
        assertFormattedField(named: "Front", buttonID: "formatItalic", style: "italic", text: "ItalicWord", in: app)
        assertFormattedField(named: "Front", buttonID: "formatUnderline", style: "underline", text: "UnderlineWord", in: app)
        assertFormattedField(named: "Back", buttonID: "formatStrikethrough", style: "strikethrough", text: "StrikeWord", in: app)
        assertFormattedField(named: "Back", buttonID: "formatHighlight", style: "highlight", text: "HighlightWord", in: app)
        assertFormattedField(named: "Back", buttonID: "formatCode", style: "code", text: "CodeWord", in: app)
    }

    func testAddItemCancelReturnsToLibrary() throws {
        let app = launchApp()
        openAddItem(in: app)
        app.buttons.identified("cancelAddItem").click()
        assertEmptyLibrary(in: app)
    }

    func testAddItemValidationDisablesSave() throws {
        let app = launchApp()
        openAddItem(in: app)
        enterText("Only front", into: field(named: "Front", in: app), app: app)

        let save = app.buttons.identified("saveAddItem")
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertFalse(save.isEnabled)
    }

    func testOpenItemDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Detail", back: "View", in: app)
        openItemDetail(named: "Detail", in: app)
        XCTAssertTrue(app.buttons.identified("deleteItem").exists)
    }

    func testBackFromItemDetailReturnsToLibrary() throws {
        let app = launchApp()
        addBasicItem(front: "Back Test", back: "View", in: app)
        openItemDetail(named: "Back Test", in: app)

        let back = app.buttons.identified("itemDetailBack")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.click()

        waitForItem(named: "Back Test", in: app)
        XCTAssertFalse(app.buttons.identified("deleteItem").exists)
    }

    func testDeleteAllUnassignedFromToolbar() throws {
        let app = launchApp()
        addBasicItem(front: "Loose Item", back: "A", in: app)
        createDeck(named: "Keep Deck", in: app)

        openAddItem(in: app)
        let deckPicker = app.popUpButtons.identified("addItemDeckPicker")
        if deckPicker.waitForExistence(timeout: 2) {
            deckPicker.click()
            app.menuItems.identified("Keep Deck").click()
        }
        enterText("Deck Item", into: field(named: "Front", in: app), app: app)
        enterText("B", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("scopeRow-Unassigned", in: app)
        waitForItem(named: "Loose Item", in: app)

        let deleteAll = app.buttons.identified("deleteAllUnassignedToolbar")
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5))
        deleteAll.click()
        XCTAssertTrue(app.buttons.identified("confirmDeleteAllUnassigned").waitForExistence(timeout: 5))
        app.buttons.identified("confirmDeleteAllUnassigned").click()

        XCTAssertTrue(app.descendants(matching: .any)["emptyUnassignedState"].waitForExistence(timeout: 10))
        selectScope("scopeRow-AllDecks", in: app)
        waitForItem(named: "Deck Item", in: app)
        assertNoItem(named: "Loose Item", in: app)
    }

    func testDeleteAllUnassignedFromSidebarMenu() throws {
        let app = launchApp()
        addBasicItem(front: "Sidebar Delete", back: "A", in: app)

        showSidebar(in: app)
        let unassigned = app.descendants(matching: .any).identified("scopeRow-Unassigned")
        unassigned.rightClick()
        app.menuItems.identified("Delete All").click()
        XCTAssertTrue(app.buttons.identified("confirmDeleteAllUnassigned").waitForExistence(timeout: 5))
        app.buttons.identified("confirmDeleteAllUnassigned").click()

        selectScope("scopeRow-Unassigned", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["emptyUnassignedState"].waitForExistence(timeout: 10))
        assertNoItem(named: "Sidebar Delete", in: app)
    }

    func testEditItemFromDetailUpdatesLibraryAndPreview() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        openItemDetail(named: "France", in: app)

        app.buttons.identified("editItem").click()
        enterText("Japan", into: field(named: "Front", in: app), app: app)
        enterText("Tokyo", into: field(named: "Back", in: app), app: app)
        let save = app.buttons.identified("saveEditItem")
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "Japan", "Japan")
        ).firstMatch.waitForExistence(timeout: 5))
        returnToLibrary(in: app)
        waitForItem(named: "Japan", in: app)
        assertNoItem(named: "France", in: app)
    }

    func testDirtyItemEditCanKeepEditingThenDiscard() throws {
        let app = launchApp()
        addBasicItem(front: "Original", back: "Answer", in: app)
        openItemDetail(named: "Original", in: app)

        app.buttons.identified("editItem").click()
        enterText("Changed", into: field(named: "Front", in: app), app: app)
        app.buttons.identified("cancelEditItem").click()
        XCTAssertTrue(app.buttons.identified("cancelDiscardItem").waitForExistence(timeout: 3))
        app.buttons.identified("cancelDiscardItem").click()
        XCTAssertTrue(app.buttons.identified("saveEditItem").exists)

        app.buttons.identified("cancelEditItem").click()
        app.buttons.identified("confirmDiscardItem").click()
        XCTAssertTrue(app.buttons.identified("deleteItem").waitForExistence(timeout: 5))
        returnToLibrary(in: app)
        waitForItem(named: "Original", in: app)
        assertNoItem(named: "Changed", in: app)
    }

    func testImageEditRequiresDescriptionBeforeSaving() throws {
        let app = launchApp(scenario: "image-missing-description")
        waitForItem(named: "Image", in: app)
        openItemDetail(named: "Image", in: app)

        app.buttons.identified("editItem").click()
        let save = app.buttons.identified("saveEditItem")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
    }

    func testDeleteItemFromDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Remove", back: "Me", in: app)
        openItemDetail(named: "Remove", in: app)

        app.buttons.identified("deleteItem").click()
        app.buttons.identified("confirmDeleteItem").click()

        assertEmptyLibrary(in: app)
        assertNoItem(named: "Remove", in: app)
    }

    func testMoveItemToDeckFromDetail() throws {
        let app = launchApp()
        createDeck(named: "Target Deck", in: app)
        addBasicItem(front: "Movable", back: "Item", in: app)
        openItemDetail(named: "Movable", in: app)

        let picker = app.descendants(matching: .any).identified("itemDeckPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let deckMenuItem = app.menuItems.identified("Target Deck")
        XCTAssertTrue(deckMenuItem.waitForExistence(timeout: 3))
        deckMenuItem.click()

        returnToLibrary(in: app)
        selectScope("deckRow-Target Deck", in: app)
        waitForItem(named: "Movable", in: app, timeout: 15)
    }

    func testAddItemWithDeckPicker() throws {
        let app = launchApp()
        createDeck(named: "History", in: app)

        openAddItem(in: app)
        let deckPicker = app.popUpButtons.identified("addItemDeckPicker")
        if deckPicker.waitForExistence(timeout: 2) {
            deckPicker.click()
            app.menuItems.identified("History").click()
        }

        enterText("Rome", into: field(named: "Front", in: app), app: app)
        enterText("Italy", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("deckRow-History", in: app)
        waitForItem(named: "Rome", in: app)
    }

    func testDeleteItemCancellationPreservesItem() throws {
        let app = launchApp()
        addBasicItem(front: "Keep Item", back: "Still Here", in: app)
        openItemDetail(named: "Keep Item", in: app)

        app.buttons.identified("deleteItem").click()
        XCTAssertTrue(app.buttons.identified("cancelDeleteItem").waitForExistence(timeout: 3))
        app.buttons.identified("cancelDeleteItem").click()

        XCTAssertTrue(app.buttons.identified("deleteItem").waitForExistence(timeout: 3))
        returnToLibrary(in: app)
        waitForItem(named: "Keep Item", in: app)
    }

    func testWhitespaceOnlyRequiredFieldsCannotBeSaved() throws {
        let app = launchApp()
        openAddItem(in: app)
        enterText("   ", into: field(named: "Front", in: app), app: app)

        XCTAssertFalse(app.buttons.identified("saveAddItem").isEnabled)
    }

    func testJSONImportThroughSystemFilePicker() throws {
        let file = try makeImportFixture(
            name: "items.json",
            contents: """
            {
              "itemType": "Basic",
              "rows": [
                { "Front": "Imported Question", "Back": "Imported Answer" }
              ]
            }
            """
        )
        let app = launchAppForImport(file: file)
        app.buttons.identified("confirmImport").click()
        _ = app.buttons.identified("confirmImport").waitForNonExistence(timeout: 30)
        dismissImportComplete(in: app)
        waitForItem(named: "Imported Question", in: app, timeout: 10)
    }

    func testCSVImportSelectsItemTypeAndImportsRows() throws {
        let file = try makeImportFixture(
            name: "items.csv",
            contents: """
            Front,Back,tags
            CSV Question,CSV Answer,imported
            """
        )
        let app = launchAppForImport(file: file)
        XCTAssertTrue(app.popUpButtons.identified("importItemTypePicker").waitForExistence(timeout: 3))
        let importButton = app.buttons.identified("confirmImport")
        XCTAssertTrue(importButton.isEnabled)
        importButton.click()
        _ = importButton.waitForNonExistence(timeout: 30)
        dismissImportComplete(in: app)
        waitForItem(named: "CSV Question", in: app, timeout: 10)
    }

    func testImportValidationKeepsSheetOpenAndLibraryUnchanged() throws {
        let file = try makeImportFixture(
            name: "invalid.json",
            contents: """
            {
              "itemType": "Basic",
              "rows": [
                { "Front": "Question", "Back": "Answer", "Unknown": "Rejected" }
              ]
            }
            """
        )
        let app = launchAppForImport(file: file)

        XCTAssertTrue(app.buttons.identified("confirmImport").waitForExistence(timeout: 10))
        app.buttons.identified("confirmImport").click()
        XCTAssertTrue(app.descendants(matching: .any)["importError"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].exists)
        app.buttons.identified("cancelImport").click()
        assertEmptyLibrary(in: app)
    }

    /// Fitting is automatic, so the Scheduling menu must not offer it — there is
    /// no decision here for the learner to get wrong or forget to make.
    func testSchedulingMenuOffersOnlySettings() throws {
        let app = launchApp()
        app.menuBarItems["Scheduling"].click()
        let settings = app.menuItems.identified("Scheduling Settings…")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(app.menuItems.identified("Optimize Scheduling…").exists)
        XCTAssertFalse(app.menuItems.identified("Optimizing Scheduling…").exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    /// Ending a session with enough history to refit must tune the profile
    /// without saying so: the learner asked to study, not to be reported to.
    func testEndingASessionOptimizesWithoutInterrupting() throws {
        let app = launchApp(scenario: "scheduling-history")
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        endStudyViaMenu(in: app)

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "Scheduling Optimized")
            ).firstMatch.exists
        )
        waitForLibraryReady(in: app)
    }
}
