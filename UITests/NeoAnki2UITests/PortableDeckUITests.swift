import XCTest

final class PortableDeckUITests: NeoAnkiUITestCase {
    func testImportPortableDeckSucceeds() throws {
        let app = launchAppForPortableImport(file: fixtureURL("minimal.neodeck"))
        finishPortableImport(in: app)
        waitForItem(named: "Imported Front", in: app)
        showSidebar(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any).identified("deckRow-Portable Import").waitUntilExists(timeout: 5)
        )
    }

    func testImportAuthoredNeoankiBundle() throws {
        let app = launchAppForPortableImport(file: fixtureURL("Biology.neoanki"))
        finishPortableImport(in: app)
        waitForItem(named: "What is the primary role of mitochondria?", in: app, timeout: 15)
    }

    func testExportPortableDeckSucceeds() throws {
        let app = launchAppWithFixtures(scenario: "portable-export-source")
        showSidebar(in: app)
        selectScope("deckRow-Export Deck", in: app)

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki2-ui-export-\(UUID().uuidString).neodeck")
        try? FileManager.default.removeItem(at: exportURL)

        chooseExportDestination(exportURL, in: app)
        dismissPortableDeckNotice(titled: "Deck Exported", in: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testExportDisabledWithoutDeckSelection() throws {
        let app = launchAppWithFixtures(scenario: "portable-export-source")
        selectScope("scopeRow-AllDecks", in: app)
        assertMenuDisabled("Export Deck…", in: app)

        selectScope("scopeRow-Unassigned", in: app)
        assertMenuDisabled("Export Deck…", in: app)
    }

    func testImportConflictShowsResolutionDialog() throws {
        let app = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )

        XCTAssertTrue(app.buttons.identified("portableDeckConflictUseLocal").waitUntilExists(timeout: 10))
        XCTAssertTrue(app.buttons.identified("portableDeckConflictImportNew").exists)
        XCTAssertTrue(app.buttons.identified("portableDeckConflictCancel").exists)
    }

    func testImportConflictUseMatchingLocalType() throws {
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

    func testImportConflictImportAsNewType() throws {
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
        XCTAssertTrue(
            app.descendants(matching: .any)["itemTypeRow-Portable Custom Revised"].waitUntilExists(timeout: 15)
        )
        closeTemplates(in: app)
    }

    func testImportConflictCancel() throws {
        let app = launchAppWithFixtures(scenario: "type-conflict-local")
        choosePortableDeckImport(fixtureURL("conflict.neodeck"), in: app)
        app.buttons.identified("portableDeckConflictCancel").click()
        if app.buttons.identified("portableDeckConflictUseLocal").waitUntilExists(timeout: 2) {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }

        XCTAssertTrue(app.buttons.identified("portableDeckConflictUseLocal").waitUntilGone(timeout: 5))
    }
}
