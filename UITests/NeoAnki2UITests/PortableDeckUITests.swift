import XCTest

extension FastFunctionalJourneyTests {
    func checkPortableDeckUITestsImportPortableDeckSucceeds() throws {
        let app = launchAppForPortableImport(file: fixtureURL("minimal.neodeck"))
        finishPortableImport(in: app)
        waitForItem(named: "Imported Front", in: app)
        showSidebar(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any).identified("deckRow-Portable Import").waitUntilExists(timeout: 5)
        )
    }

    func checkPortableDeckUITestsImportAuthoredNeoankiBundle() throws {
        let app = launchAppForPortableImport(file: fixtureURL("Biology.neoanki"))
        finishPortableImport(in: app)
        waitForItem(named: "What is the primary role of mitochondria?", in: app, timeout: 15)
    }

    func checkPortableDeckUITestsExportPortableDeckSucceeds() throws {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki2-ui-export-\(UUID().uuidString).neodeck")
        try? FileManager.default.removeItem(at: exportURL)

        let app = launchAppWithFixtures(
            scenario: "portable-export-source",
            environment: ["NEOANKI_TEST_PORTABLE_EXPORT_PATH": exportURL.path]
        )
        showSidebar(in: app)
        selectScope("deckRow-Export Deck", in: app)
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        let exportItem = app.menuItems.identified("Export Deck…")
        XCTAssertTrue(exportItem.waitUntilExists(timeout: 3))
        XCTAssertTrue(exportItem.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        exportPortableDeckForTesting(to: exportURL, in: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func checkPortableDeckUITestsExportDisabledWithoutDeckSelection() throws {
        let app = launchAppWithFixtures(scenario: "portable-export-source")
        selectScope("scopeRow-AllDecks", in: app)
        assertMenuDisabled("Export Deck…", in: app)

        selectScope("scopeRow-Unassigned", in: app)
        assertMenuDisabled("Export Deck…", in: app)
    }

    func checkPortableDeckUITestsImportConflictShowsResolutionDialog() throws {
        let app = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )

        XCTAssertTrue(app.buttons.identified("portableDeckConflictUseLocal").waitUntilExists(timeout: 10))
        XCTAssertTrue(app.buttons.identified("portableDeckConflictImportNew").exists)
        XCTAssertTrue(app.buttons.identified("portableDeckConflictCancel").exists)
    }

    func checkPortableDeckUITestsImportConflictUseMatchingLocalType() throws {
        let app = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )
        app.buttons.identified("portableDeckConflictUseLocal").click()
        XCTAssertTrue(
            app.buttons.identified("portableDeckConflictUseLocal").waitUntilGone(timeout: 15)
        )
        waitForPortableImportCompletion(in: app)
        waitForLibraryReady(in: app)
        selectScope("scopeRow-AllDecks", in: app)
        waitForItem(named: "Conflict Q", in: app, timeout: 15)
    }

    func checkPortableDeckUITestsImportConflictImportAsNewType() throws {
        let app = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )
        app.buttons.identified("portableDeckConflictImportNew").click()
        XCTAssertTrue(
            app.buttons.identified("portableDeckConflictUseLocal").waitUntilGone(timeout: 15)
        )
        waitForPortableImportCompletion(in: app)

        openTemplates(in: app)
        let includedDeckGroup = app.buttons.identified("includedDeckGroup-Conflict Deck")
        XCTAssertTrue(includedDeckGroup.waitUntilExists(timeout: 15))
        includedDeckGroup.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["includedItemTypeRow-Portable Custom Revised"]
                .waitUntilExists(timeout: 15)
        )
        closeTemplates(in: app)
    }

    func checkPortableDeckUITestsImportConflictCancel() throws {
        let app = launchAppWithFixtures(scenario: "type-conflict-local")
        choosePortableDeckImport(fixtureURL("conflict.neodeck"), in: app)
        app.buttons.identified("portableDeckConflictCancel").click()
        if app.buttons.identified("portableDeckConflictUseLocal").waitUntilExists(timeout: 2) {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }

        XCTAssertTrue(app.buttons.identified("portableDeckConflictUseLocal").waitUntilGone(timeout: 5))
    }
}
