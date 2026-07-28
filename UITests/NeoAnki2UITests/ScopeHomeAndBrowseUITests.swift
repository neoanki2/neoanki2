import XCTest

final class ScopeHomeAndBrowseUITests: NeoAnkiUITestCase {
    func testScopeHomeLeadsWithDueCountAndStudy() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        leaveBrowseMode(in: app)

        let headline = app.descendants(matching: .any).identified("scopeHomeDueHeadline")
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["scopeHomeCardStates"].exists)
        XCTAssertTrue(app.buttons.identified("studyButton").isEnabled)
        XCTAssertTrue(app.buttons.identified("scopeHomeBrowseLink").exists)
    }

    /// The scope home never prints an item's answer, which is the whole reason
    /// the detail pane stopped being a list.
    func testScopeHomeDoesNotRevealAnswers() throws {
        let app = launchApp()
        addBasicItem(front: "Capital of France", back: "Paris", in: app)
        leaveBrowseMode(in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["scopeHomeDueHeadline"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "Paris", "Paris")
            ).firstMatch.exists
        )
    }

    func testScopeHomeReportsNextDueInsteadOfADeadStudyButton() throws {
        let app = launchApp()
        addBasicItem(front: "Caught Up Q", back: "Caught Up A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
        let nextDue = app.descendants(matching: .any).identified("scopeHomeNextDue")
        XCTAssertTrue(nextDue.waitForExistence(timeout: 10))
    }

    func testBrowseOpensWithKeyboardShortcutAndClosesWithEscape() throws {
        let app = launchApp()
        addBasicItem(front: "Browse Me", back: "Answer", in: app)
        leaveBrowseMode(in: app)

        app.typeKey("b", modifierFlags: [.command, .option])
        XCTAssertTrue(
            app.descendants(matching: .any)["itemBrowserTable"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.descendants(matching: .any)["itemRow-Browse Me"].exists)

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(
            app.descendants(matching: .any)["scopeHomeDueHeadline"].waitForExistence(timeout: 10)
        )
    }

    func testBrowseOpensFromTheLibraryMenu() throws {
        let app = launchApp()
        addBasicItem(front: "Menu Browse", back: "Answer", in: app)
        leaveBrowseMode(in: app)

        app.menuBarItems["Library"].click()
        selectMenuItem("Browse Items", in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["itemBrowserTable"].waitForExistence(timeout: 10)
        )
    }

    func testBrowseSearchNarrowsRowsAndReportsNoResults() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        addBasicItem(front: "Japan", back: "Tokyo", in: app)
        enterBrowseMode(in: app)

        let search = searchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Japan")

        let japan = app.descendants(matching: .any).identified("itemRow-Japan")
        XCTAssertTrue(japan.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["itemRow-France"].exists)

        search.typeKey("a", modifierFlags: [.command])
        search.typeText("Ukraine")
        XCTAssertTrue(
            app.descendants(matching: .any)["browseNoSearchResults"].waitForExistence(timeout: 5)
        )
    }

    func testBrowseHidesTheAnswerColumnByDefault() throws {
        let app = launchApp()
        addBasicItem(front: "Capital of France", back: "Paris", in: app)
        enterBrowseMode(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["itemRow-Capital of France"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "value == %@ OR label == %@", "Paris", "Paris")
            ).firstMatch.exists
        )
    }

    /// Menu navigation is the standard Mac discovery path, and the only one
    /// VoiceOver menu users have, so the app's second most common verb has to
    /// appear there rather than living solely on a toolbar button.
    func testAddItemHasAMenuHomeUnderFile() throws {
        let app = launchApp()

        app.menuBarItems["File"].click()
        selectMenuItem("New Item", in: app)

        XCTAssertTrue(app.buttons.identified("cancelAddItem").waitForExistence(timeout: 10))
        XCTAssertTrue(field(named: "Front", in: app).waitForExistence(timeout: 10))
    }

    /// A hidden-by-default column is only a considered default if the user can
    /// find the way to reveal it, so the reveal has to live in the menu bar.
    func testBrowseRevealsTheAnswerColumnFromTheLibraryMenu() throws {
        let app = launchApp()
        addBasicItem(front: "Capital of France", back: "Paris", in: app)
        enterBrowseMode(in: app)

        let answer = app.staticTexts.matching(
            NSPredicate(format: "value == %@ OR label == %@", "Paris", "Paris")
        ).firstMatch
        XCTAssertFalse(answer.exists)

        app.menuBarItems["Library"].click()
        selectMenuItem("Show Answer Column", in: app)
        XCTAssertTrue(answer.waitForExistence(timeout: 5))

        app.menuBarItems["Library"].click()
        selectMenuItem("Hide Answer Column", in: app)
        XCTAssertTrue(waitForDisappearance(of: answer))
    }

    /// Whether you want to see answers is a standing preference, not something
    /// to rediscover every time you open browse mode.
    func testAnswerColumnChoiceSurvivesLeavingBrowseMode() throws {
        let app = launchApp()
        addBasicItem(front: "Capital of Japan", back: "Tokyo", in: app)
        enterBrowseMode(in: app)

        app.typeKey("a", modifierFlags: [.command, .option])
        let answer = app.staticTexts.matching(
            NSPredicate(format: "value == %@ OR label == %@", "Tokyo", "Tokyo")
        ).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))

        leaveBrowseMode(in: app)
        enterBrowseMode(in: app)
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
    }

    func testBrowseDeletesASelectedItem() throws {
        let app = launchApp()
        addBasicItem(front: "Delete Me", back: "Answer", in: app)
        addBasicItem(front: "Keep Me", back: "Answer", in: app)
        enterBrowseMode(in: app)

        let row = app.descendants(matching: .any).identified("itemRow-Delete Me")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        let delete = app.buttons.identified("browseDeleteSelection")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(
            app.buttons.identified("browseConfirmDelete").waitForExistence(timeout: 5)
        )
        app.buttons.identified("browseConfirmDelete").click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["itemRow-Keep Me"].exists)
    }

    func testBrowseMovesASelectedItemToADeck() throws {
        let app = launchApp()
        createDeck(named: "Target Deck", in: app)
        addBasicItem(front: "Movable", back: "Item", in: app)
        enterBrowseMode(in: app)

        let row = app.descendants(matching: .any).identified("itemRow-Movable")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        let moveMenu = app.buttons.identified("browseMoveToDeck")
        let menu = moveMenu.exists ? moveMenu : app.menuButtons.identified("browseMoveToDeck")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        selectMenuItem("Target Deck", in: app)

        selectScope("deckRow-Target Deck", in: app)
        waitForItem(named: "Movable", in: app, timeout: 15)
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 3) { return field }
        return app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] %@", "Search items")
        ).firstMatch
    }
}
