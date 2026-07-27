import XCTest

final class DeckUITests: NeoAnkiUITestCase {
    func testCreateDeckFromSidebar() throws {
        let app = launchApp()
        createDeck(named: "Geography", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["deckRow-Geography"].exists)
    }

    func testRenameDeck() throws {
        let app = launchApp()
        createDeck(named: "Old Name", in: app)

        showSidebar(in: app)
        let deckRow = app.descendants(matching: .any).identified("deckRow-Old Name")
        deckRow.rightClick()
        app.menuItems.identified("Rename").click()

        guard let container = modalContainer(in: app) else {
            XCTFail("Rename dialog did not appear")
            return
        }
        let textField = container.textFields.firstMatch
        textField.click()
        textField.typeKey("a", modifierFlags: [.command])
        textField.typeText("New Name")
        if app.buttons.identified("confirmRenameDeck").exists {
            app.buttons.identified("confirmRenameDeck").click()
        } else {
            container.buttons.identified("Save").click()
        }

        XCTAssertTrue(app.descendants(matching: .any)["deckRow-New Name"].waitForExistence(timeout: 10))
    }

    func testDeleteDeckWithConfirmation() throws {
        let app = launchApp()
        createDeck(named: "Temporary", in: app)

        showSidebar(in: app)
        let deckRow = app.descendants(matching: .any).identified("deckRow-Temporary")
        deckRow.rightClick()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let contextDelete = app.menuItems.matching(
            NSPredicate(format: "title == 'Delete' AND enabled == true")
        ).firstMatch
        if contextDelete.exists {
            contextDelete.click()
        } else {
            app.menuItems["Delete"].firstMatch.click()
        }

        if app.buttons.identified("confirmDeleteDeck").waitForExistence(timeout: 5) {
            app.buttons.identified("confirmDeleteDeck").click()
        } else if let container = modalContainer(in: app) {
            container.buttons.identified("Delete Deck").click()
        } else {
            XCTFail("Delete deck confirmation did not appear")
        }

        XCTAssertFalse(app.descendants(matching: .any)["deckRow-Temporary"].waitForExistence(timeout: 3))
    }

    func testSwitchScopesFiltersItems() throws {
        let app = launchApp()
        createDeck(named: "Scoped", in: app)

        selectScope("scopeRow-AllDecks", in: app)
        addBasicItem(front: "Unassigned Item", back: "A", in: app)

        openAddItem(in: app)
        let deckPicker = app.popUpButtons.identified("addItemDeckPicker")
        if deckPicker.waitForExistence(timeout: 2) {
            deckPicker.click()
            app.menuItems.identified("Scoped").click()
        }
        enterText("Deck Item", into: field(named: "Front", in: app), app: app)
        enterText("B", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("scopeRow-Unassigned", in: app)
        waitForItem(named: "Unassigned Item", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-Deck Item"].exists)

        selectScope("deckRow-Scoped", in: app)
        waitForItem(named: "Deck Item", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-Unassigned Item"].exists)
    }

    func testScopedStudyFromDeckSelection() throws {
        let app = launchApp()
        createDeck(named: "Study Deck", in: app)

        openAddItem(in: app)
        if app.popUpButtons.identified("addItemDeckPicker").waitForExistence(timeout: 2) {
            app.popUpButtons.identified("addItemDeckPicker").click()
            app.menuItems.identified("Study Deck").click()
        }
        enterText("Scoped Q", into: field(named: "Front", in: app), app: app)
        enterText("Scoped A", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("scopeRow-AllDecks", in: app)
        addBasicItem(front: "Other Q", back: "Other A", in: app)

        selectScope("deckRow-Study Deck", in: app)
        app.typeKey("0", modifierFlags: [.command])
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        let studyButton = app.buttons.identified("studyButton")
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertFalse(studyButton.isEnabled)
    }

    func testCancelCreatingDeckLeavesSidebarUnchanged() throws {
        let app = launchApp()
        app.buttons.identified("newDeckToolbar").click()
        XCTAssertTrue(app.buttons.identified("cancelCreateDeck").waitForExistence(timeout: 3))
        app.buttons.identified("cancelCreateDeck").click()

        XCTAssertFalse(app.descendants(matching: .any)["deckRow-Cancelled"].exists)
        XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitForExistence(timeout: 3))
    }

    func testCancelRenameKeepsOriginalDeckName() throws {
        let app = launchApp()
        createDeck(named: "Keep Name", in: app)

        let row = app.descendants(matching: .any).identified("deckRow-Keep Name")
        row.rightClick()
        app.menuItems.identified("Rename").click()
        XCTAssertTrue(app.buttons.identified("cancelRenameDeck").waitForExistence(timeout: 3))
        app.buttons.identified("cancelRenameDeck").click()

        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    func testCancelDeleteKeepsDeck() throws {
        let app = launchApp()
        createDeck(named: "Keep Deck", in: app)

        let row = app.descendants(matching: .any).identified("deckRow-Keep Deck")
        row.rightClick()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let contextDelete = app.menuItems.matching(
            NSPredicate(format: "title == 'Delete' AND enabled == true")
        ).firstMatch
        XCTAssertTrue(contextDelete.waitForExistence(timeout: 3))
        contextDelete.click()
        XCTAssertNotNil(modalContainer(in: app))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    func testCreateSubdeckFromContextMenu() throws {
        let app = launchApp()
        createDeck(named: "Parent", in: app)

        let parent = app.descendants(matching: .any).identified("deckRow-Parent")
        parent.rightClick()
        app.menuItems.identified("New Subdeck").click()
        guard let container = modalContainer(in: app) else {
            XCTFail("Subdeck dialog did not appear")
            return
        }
        enterText("Child", into: container.textFields.firstMatch, app: app)
        app.buttons.identified("confirmCreateDeck").click()

        XCTAssertTrue(app.staticTexts["Child"].waitForExistence(timeout: 5))
    }

    func testDeleteDeckRemovesSubdecksAndItems() throws {
        let app = launchApp()
        createDeck(named: "Parent", in: app)

        let parent = app.descendants(matching: .any).identified("deckRow-Parent")
        parent.rightClick()
        app.menuItems.identified("New Subdeck").click()
        guard let container = modalContainer(in: app) else {
            XCTFail("Subdeck dialog did not appear")
            return
        }
        enterText("Child", into: container.textFields.firstMatch, app: app)
        app.buttons.identified("confirmCreateDeck").click()
        XCTAssertTrue(app.staticTexts["Child"].waitForExistence(timeout: 5))

        selectScope("deckRow-Child", in: app)
        addBasicItem(front: "Nested Item", back: "Answer", in: app)

        showSidebar(in: app)
        parent.rightClick()
        app.menuItems.matching(
            NSPredicate(format: "title == 'Delete' AND enabled == true")
        ).firstMatch.click()
        XCTAssertTrue(app.buttons.identified("confirmDeleteDeck").waitForExistence(timeout: 5))
        app.buttons.identified("confirmDeleteDeck").click()

        XCTAssertFalse(app.descendants(matching: .any)["deckRow-Parent"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["deckRow-Child"].exists)
        selectScope("scopeRow-AllDecks", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-Nested Item"].exists)
    }
}
