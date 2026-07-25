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
        let deckRow = app.descendants(matching: .any)["deckRow-Old Name"]
        deckRow.rightClick()
        app.menuItems["Rename"].click()

        guard let container = modalContainer(in: app) else {
            XCTFail("Rename dialog did not appear")
            return
        }
        let textField = container.textFields.firstMatch
        textField.click()
        textField.typeKey("a", modifierFlags: [.command])
        textField.typeText("New Name")
        if app.buttons["confirmRenameDeck"].exists {
            app.buttons["confirmRenameDeck"].click()
        } else {
            container.buttons["Save"].click()
        }

        XCTAssertTrue(app.descendants(matching: .any)["deckRow-New Name"].waitForExistence(timeout: 10))
    }

    func testDeleteDeckWithConfirmation() throws {
        let app = launchApp()
        createDeck(named: "Temporary", in: app)

        showSidebar(in: app)
        let deckRow = app.descendants(matching: .any)["deckRow-Temporary"]
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

        if app.buttons["confirmDeleteDeck"].waitForExistence(timeout: 5) {
            app.buttons["confirmDeleteDeck"].click()
        } else if let container = modalContainer(in: app) {
            container.buttons["Delete Deck"].click()
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
        let deckPicker = app.popUpButtons["addItemDeckPicker"]
        if deckPicker.waitForExistence(timeout: 2) {
            deckPicker.click()
            app.menuItems["Scoped"].click()
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
        if app.popUpButtons["addItemDeckPicker"].waitForExistence(timeout: 2) {
            app.popUpButtons["addItemDeckPicker"].click()
            app.menuItems["Study Deck"].click()
        }
        enterText("Scoped Q", into: field(named: "Front", in: app), app: app)
        enterText("Scoped A", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("scopeRow-AllDecks", in: app)
        addBasicItem(front: "Other Q", back: "Other A", in: app)

        selectScope("deckRow-Study Deck", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        let studyButton = app.buttons["studyButton"]
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertFalse(studyButton.isEnabled)
    }
}
