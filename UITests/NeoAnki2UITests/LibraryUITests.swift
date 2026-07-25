import XCTest

final class LibraryUITests: NeoAnkiUITestCase {
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
        app.buttons["cancelAddItem"].click()
        assertEmptyLibrary(in: app)
    }

    func testAddItemValidationDisablesSave() throws {
        let app = launchApp()
        openAddItem(in: app)
        enterText("Only front", into: field(named: "Front", in: app), app: app)

        let save = app.buttons["saveAddItem"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertFalse(save.isEnabled)
    }

    func testOpenItemDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Detail", back: "View", in: app)
        openItemDetail(named: "Detail", in: app)
        XCTAssertTrue(app.buttons["deleteItem"].exists)
    }

    func testDeleteItemFromDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Remove", back: "Me", in: app)
        openItemDetail(named: "Remove", in: app)

        app.buttons["deleteItem"].click()
        app.buttons["confirmDeleteItem"].click()

        assertEmptyLibrary(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-Remove"].exists)
    }

    func testMoveItemToDeckFromDetail() throws {
        let app = launchApp()
        createDeck(named: "Target Deck", in: app)
        addBasicItem(front: "Movable", back: "Item", in: app)
        openItemDetail(named: "Movable", in: app)

        let picker = app.descendants(matching: .any)["itemDeckPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let deckMenuItem = app.menuItems["Target Deck"]
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
        let deckPicker = app.popUpButtons["addItemDeckPicker"]
        if deckPicker.waitForExistence(timeout: 2) {
            deckPicker.click()
            app.menuItems["History"].click()
        }

        enterText("Rome", into: field(named: "Front", in: app), app: app)
        enterText("Italy", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("deckRow-History", in: app)
        waitForItem(named: "Rome", in: app)
    }
}
