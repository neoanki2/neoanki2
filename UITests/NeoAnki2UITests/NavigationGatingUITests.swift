import XCTest

final class NavigationGatingUITests: NeoAnkiUITestCase {
    func testSidebarHiddenDuringStudy() throws {
        let app = launchApp()
        addBasicItem(front: "Sidebar Study Q", back: "Sidebar Study A", in: app)
        startStudy(in: app)
        assertSidebarCollapsed(in: app)
        showSidebar(in: app)
        XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitForExistence(timeout: 3))
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)
    }

    func testSidebarHiddenDuringAddItem() throws {
        let app = launchApp()
        openAddItem(in: app)
        assertSidebarCollapsed(in: app)
        showSidebar(in: app)
        XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitForExistence(timeout: 3))
        app.buttons.identified("cancelAddItem").click()
    }

    func testSidebarHiddenDuringTemplates() throws {
        let app = launchApp()
        openTemplates(in: app)
        assertSidebarCollapsed(in: app)
        showSidebar(in: app)
        XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitForExistence(timeout: 3))
        closeTemplates(in: app)
    }

    func testStudyButtonShowsDueBadge() throws {
        let app = launchAppWithFixtures(scenario: "deck-with-due-items")
        waitForItem(named: "Due 1", in: app, timeout: 15)
        showSidebar(in: app)
        selectScope("deckRow-Due Deck", in: app)

        let studyButton = app.buttons.matching(
            NSPredicate(format: "identifier == 'studyButton' OR label CONTAINS[c] 'Study'")
        ).firstMatch
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(studyButton.isEnabled)
    }

    func testTransferBusyDisablesImport() throws {
        let app = launchAppWithFixtures(
            environment: ["NEOANKI_TEST_PORTABLE_BUSY": "1"]
        )
        assertMenuDisabled("Import Deck…", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["portableDeckTransferBusy"].waitForExistence(timeout: 5))
    }

    func testBootstrapFailureShowsSafeErrorState() throws {
        let app = launchApp(
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )

        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Could Not Start"].exists)
        XCTAssertFalse(app.buttons.identified("addItemToolbar").exists)
    }
}
