import XCTest

extension FastFunctionalJourneyTests {
    func runSharedLaunchGatingAndAccessibilityJourney() throws {
        let app = launchApp(scenario: "deck-with-due-items")

        try runJourneyActivity("NavigationGatingUITests.testSidebarHiddenDuringAddItem") {
            openAddItem(in: app)
            assertSidebarCollapsed(in: app)
            showSidebar(in: app)
            XCTAssertTrue(app.buttons.identified("newDeckToolbar").exists)
            app.buttons.identified("cancelAddItem").click()
        }

        try runJourneyActivity("NavigationGatingUITests.testSidebarHiddenDuringTemplates") {
            openTemplates(in: app)
            assertSidebarCollapsed(in: app)
            assertSidebarCannotOpenDuringItemTypes(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["templatesItemTypesHeader"].exists)
            runJourneyActivity("ImportExportUITests.testImportDisabledDuringTemplates") {
                assertMenuDisabled("Import…", in: app)
            }
            closeTemplates(in: app)
        }

        try runJourneyActivity("NavigationGatingUITests.testStudyButtonShowsDueBadge") {
            assertDueCardsAvailable(in: app)
        }

        try runJourneyActivity("NavigationGatingUITests.testSidebarHiddenDuringStudy") {
            startStudy(in: app)
            assertSidebarCannotOpenDuringStudy(in: app)
            runJourneyActivity("ImportExportUITests.testImportDisabledDuringStudy") {
                assertMenuDisabled("Import…", in: app)
            }
            revealAndGrade("gradeGood", in: app)
            finishStudySession(in: app)
        }

        try runJourneyActivity("NavigationGatingUITests.testTransferBusyDisablesImport") {
            let busyApp = launchApp(
                environment: ["NEOANKI_TEST_PORTABLE_BUSY": "1"]
            )
            assertMenuDisabled("Import Deck…", in: busyApp)
            XCTAssertTrue(
                busyApp.descendants(matching: .any)["portableDeckTransferBusy"]
                    .waitUntilExists(timeout: 3)
            )
        }

        let failedApp = launchApp(
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )
        try runJourneyActivity("NavigationGatingUITests.testBootstrapFailureShowsSafeErrorState") {
            XCTAssertTrue(
                failedApp.descendants(matching: .any)["bootstrapError"].waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(failedApp.staticTexts["Could Not Start"].exists)
            XCTAssertFalse(failedApp.buttons.identified("addItemToolbar").exists)
        }
        try runJourneyActivity("LibraryUITests.testBootstrapFailureShowsSafeErrorState") {
            XCTAssertTrue(failedApp.descendants(matching: .any)["bootstrapError"].exists)
            XCTAssertTrue(failedApp.staticTexts["Could Not Start"].exists)
            XCTAssertFalse(failedApp.buttons.identified("addItemToolbar").exists)
        }
    }

    func checkNavigationGatingUITestsSidebarHiddenDuringStudy() throws {
        let app = launchApp()
        addBasicItem(front: "Sidebar Study Q", back: "Sidebar Study A", in: app)
        startStudy(in: app)
        assertSidebarCannotOpenDuringStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)
    }

    func checkNavigationGatingUITestsSidebarHiddenDuringAddItem() throws {
        let app = launchApp()
        openAddItem(in: app)
        assertSidebarCollapsed(in: app)
        showSidebar(in: app)
        XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelAddItem").click()
    }

    func checkNavigationGatingUITestsSidebarHiddenDuringTemplates() throws {
        let app = launchApp()
        openTemplates(in: app)
        assertSidebarCollapsed(in: app)
        assertSidebarCannotOpenDuringItemTypes(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["templatesItemTypesHeader"].waitUntilExists(timeout: 3)
        )
        closeTemplates(in: app)
    }

    func checkNavigationGatingUITestsStudyButtonShowsDueBadge() throws {
        let app = launchAppWithFixtures(scenario: "deck-with-due-items")
        waitForItem(named: "Due 1", in: app, timeout: 15)
        showSidebar(in: app)
        selectScope("deckRow-Due Deck", in: app)

        assertDueCardsAvailable(in: app)
    }

    func checkNavigationGatingUITestsTransferBusyDisablesImport() throws {
        let app = launchAppWithFixtures(
            environment: ["NEOANKI_TEST_PORTABLE_BUSY": "1"]
        )
        assertMenuDisabled("Import Deck…", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["portableDeckTransferBusy"].waitUntilExists(timeout: 5))
    }

    func checkNavigationGatingUITestsBootstrapFailureShowsSafeErrorState() throws {
        let app = launchApp(
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )

        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["Could Not Start"].exists)
        XCTAssertFalse(app.buttons.identified("addItemToolbar").exists)
    }
}
