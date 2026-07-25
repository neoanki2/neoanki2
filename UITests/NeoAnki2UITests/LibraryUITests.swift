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
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-France"].exists)
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
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-Changed"].exists)
    }

    func testImageEditRequiresDescriptionBeforeSaving() throws {
        let app = launchApp(scenario: "image-missing-description")
        waitForItem(named: "Image", in: app)
        openItemDetail(named: "Image", in: app)

        app.buttons.identified("editItem").click()
        let save = app.buttons.identified("saveEditItem")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)

        enterText(
            "Map showing France",
            into: app.textFields.identified("field-Image-altText"),
            app: app
        )
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
    }

    func testDeleteItemFromDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Remove", back: "Me", in: app)
        openItemDetail(named: "Remove", in: app)

        app.buttons.identified("deleteItem").click()
        app.buttons.identified("confirmDeleteItem").click()

        assertEmptyLibrary(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-Remove"].exists)
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
        let app = launchApp()
        chooseImportFile(file, in: app)

        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].waitForExistence(timeout: 10))
        let importButton = app.buttons.identified("confirmImport")
        importButton.click()
        XCTAssertTrue(importButton.waitForNonExistence(timeout: 10))
        let completion = app.sheets.firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        XCTAssertTrue(completion.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "Import Complete")
        ).firstMatch.exists)
        completion.buttons.identified("OK").click()
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
        let app = launchApp()
        chooseImportFile(file, in: app)

        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.popUpButtons.identified("importItemTypePicker").waitForExistence(timeout: 3))
        let importButton = app.buttons.identified("confirmImport")
        XCTAssertTrue(importButton.isEnabled)
        importButton.click()
        XCTAssertTrue(importButton.waitForNonExistence(timeout: 10))
        let completion = app.sheets.firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        XCTAssertTrue(completion.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "Import Complete")
        ).firstMatch.exists)
        completion.buttons.identified("OK").click()
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
        let app = launchApp()
        chooseImportFile(file, in: app)

        XCTAssertTrue(app.buttons.identified("confirmImport").waitForExistence(timeout: 10))
        app.buttons.identified("confirmImport").click()
        XCTAssertTrue(app.descendants(matching: .any)["importError"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].exists)
        app.buttons.identified("cancelImport").click()
        assertEmptyLibrary(in: app)
    }

    func testSchedulingOptimizationReportsInsufficientHistory() throws {
        let app = launchApp()
        app.menuBarItems["Scheduling"].click()
        let optimize = app.menuItems.identified("Optimize Scheduling…")
        XCTAssertTrue(optimize.waitForExistence(timeout: 3))
        XCTAssertTrue(optimize.isEnabled)
        optimize.click()

        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "review")
            ).firstMatch.exists
        )
        alert.buttons.identified("OK").click()
    }

    func testSchedulingOptimizationSucceedsWithReviewHistory() throws {
        let app = launchApp(scenario: "scheduling-history")
        app.menuBarItems["Scheduling"].click()
        app.menuItems.identified("Optimize Scheduling…").click()

        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "Scheduling Optimized")
        ).firstMatch.exists)
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "129 review outcomes")
            ).firstMatch.exists
        )
        alert.buttons.identified("OK").click()
    }
}
