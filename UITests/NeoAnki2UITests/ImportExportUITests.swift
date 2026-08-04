import XCTest

extension FastFunctionalJourneyTests {
    func runSharedImportAndPortableTransferJourney() throws {
        // Start the controller on an ordinary library route, then drive every
        // transfer through the acknowledged command channel. Opening an import
        // from initial launch environment races SwiftUI's first task install.
        _ = launchApp()

        try runJourneyActivity("ImportExportUITests.testImportWithMediaDirectory") {
            let app = launchAppForImport(
                file: fixtureURL("import-with-media.json"),
                scenario: "import-with-media"
            )
            let chooseMedia = app.buttons.identified("chooseImportMediaDirectory")
            if chooseMedia.exists {
                chooseMedia.click()
                chooseFileInOpenPanel(
                    fixturesDirectory().appendingPathComponent("media"),
                    in: app
                )
            }
            app.buttons.identified("confirmImport").click()
            dismissImportComplete(in: app)
            waitForItem(named: "Media Question", in: app, timeout: 10)
        }
        try runJourneyActivity("LibraryUITests.testJSONImportThroughSystemFilePicker") {
            let app = try XCTUnwrap(runningApp)
            XCTAssertTrue(
                app.descendants(matching: .any)["itemRow-Media Question"].exists,
                "The JSON import should create its declared row"
            )
        }

        let navigationApp = launchApp()
        try runJourneyActivity("ImportExportUITests.testImportFilePickerCancel") {
            dismissOpenMenus(in: navigationApp)
            navigationApp.menuBarItems["File"].click()
            let importItem = navigationApp.menuItems.identified("Import…")
            XCTAssertTrue(importItem.waitUntilExists(timeout: 3))
            importItem.click()
            cancelFilePicker(in: navigationApp)
            XCTAssertTrue(
                navigationApp.descendants(matching: .any)["importSheet"]
                    .waitUntilGone(timeout: 2)
            )
            assertEmptyLibrary(in: navigationApp)
        }

        var rows = "Front,Back\n"
        for index in 0..<200 {
            rows += "Bulk \(index),Answer \(index)\n"
        }
        let bulkFile = try makeImportFixture(name: "bulk.csv", contents: rows)
        try runJourneyActivity("ImportExportUITests.testImportProgressIndicator") {
            let app = launchAppForImport(file: bulkFile)
            app.buttons.identified("confirmImport").click()
            let progress = app.descendants(matching: .any)["importProgress"]
            _ = progress.waitUntilExists(timeout: 1)
            dismissImportComplete(in: app)
            waitForItem(named: "Bulk 0", in: app, timeout: 15)
        }

        let typedFile = try makeImportFixture(
            name: "typed.csv",
            contents: """
            Front,Back
            Alt Question,Alt Answer
            """
        )
        try runJourneyActivity("ImportExportUITests.testCSVImportItemTypePicker") {
            let app = launchAppForImport(file: typedFile, scenario: "alternate-import-type")
            let picker = app.popUpButtons.identified("importItemTypePicker")
            XCTAssertTrue(picker.waitUntilExists(timeout: 5))
            selectPopUpOption(named: "Alternate", picker: picker, in: app)
            app.buttons.identified("confirmImport").click()
            dismissImportComplete(in: app)
            waitForItem(named: "Alt Question", in: app, timeout: 10)
        }
        try runJourneyActivity("LibraryUITests.testCSVImportSelectsItemTypeAndImportsRows") {
            let app = try XCTUnwrap(runningApp)
            XCTAssertTrue(
                app.descendants(matching: .any)["itemRow-Alt Question"].exists,
                "The CSV import should use the selected item type and create its row"
            )
        }

        let invalidFile = try makeImportFixture(
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
        try runJourneyActivity("LibraryUITests.testImportValidationKeepsSheetOpenAndLibraryUnchanged") {
            let app = launchAppForImport(file: invalidFile)
            app.buttons.identified("confirmImport").click()
            XCTAssertTrue(
                app.descendants(matching: .any)["importError"].waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(app.descendants(matching: .any)["importSheet"].exists)
            app.buttons.identified("cancelImport").click()
            assertEmptyLibrary(in: app)
        }

        try runJourneyActivity("PortableDeckUITests.testImportPortableDeckSucceeds") {
            let app = launchAppForPortableImport(file: fixtureURL("minimal.neodeck"))
            finishPortableImport(in: app)
            waitForItem(named: "Imported Front", in: app)
            showSidebar(in: app)
            XCTAssertTrue(
                app.descendants(matching: .any).identified("deckRow-Portable Import")
                    .waitUntilExists(timeout: 5)
            )
        }

        try runJourneyActivity("PortableDeckUITests.testImportAuthoredNeoankiBundle") {
            let app = launchAppForPortableImport(file: fixtureURL("Biology.neoanki"))
            finishPortableImport(in: app)
            waitForItem(
                named: "What is the primary role of mitochondria?",
                in: app,
                timeout: 15
            )
        }

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki2-ui-export-\(UUID().uuidString).neodeck")
        try? FileManager.default.removeItem(at: exportURL)
        let exportApp = launchApp(
            scenario: "portable-export-source",
            environment: ["NEOANKI_TEST_PORTABLE_EXPORT_PATH": exportURL.path]
        )
        try runJourneyActivity("PortableDeckUITests.testExportDisabledWithoutDeckSelection") {
            selectScope("scopeRow-AllDecks", in: exportApp)
            assertMenuDisabled("Export Deck…", in: exportApp)
            selectScope("scopeRow-Unassigned", in: exportApp)
            assertMenuDisabled("Export Deck…", in: exportApp)
        }

        try runJourneyActivity("PortableDeckUITests.testExportPortableDeckSucceeds") {
            showSidebar(in: exportApp)
            selectScope("deckRow-Export Deck", in: exportApp)
            dismissOpenMenus(in: exportApp)
            exportApp.menuBarItems["File"].click()
            let exportItem = exportApp.menuItems.identified("Export Deck…")
            XCTAssertTrue(exportItem.waitUntilExists(timeout: 3))
            XCTAssertTrue(exportItem.isEnabled)
            exportApp.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            exportPortableDeckForTesting(to: exportURL, in: exportApp)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        }

        let conflictApp = launchAppForPortableImport(
            scenario: "type-conflict-local",
            file: fixtureURL("conflict.neodeck")
        )
        try runJourneyActivity("PortableDeckUITests.testImportConflictShowsResolutionDialog") {
            XCTAssertTrue(
                conflictApp.buttons.identified("portableDeckConflictUseLocal")
                    .waitUntilExists(timeout: 10)
            )
            XCTAssertTrue(
                conflictApp.buttons.identified("portableDeckConflictImportNew").exists
            )
            XCTAssertTrue(
                conflictApp.buttons.identified("portableDeckConflictCancel").exists
            )
        }
        try runJourneyActivity("PortableDeckUITests.testImportConflictUseMatchingLocalType") {
            conflictApp.buttons.identified("portableDeckConflictUseLocal").click()
            XCTAssertTrue(
                conflictApp.buttons.identified("portableDeckConflictUseLocal")
                    .waitUntilGone(timeout: 15)
            )
            waitForPortableImportCompletion(in: conflictApp)
            waitForLibraryReady(in: conflictApp)
            selectScope("scopeRow-AllDecks", in: conflictApp)
            waitForItem(named: "Conflict Q", in: conflictApp, timeout: 15)
        }

        try runJourneyActivity("PortableDeckUITests.testImportConflictImportAsNewType") {
            let app = launchAppForPortableImport(
                scenario: "type-conflict-local",
                file: fixtureURL("conflict.neodeck")
            )
            app.buttons.identified("portableDeckConflictImportNew").click()
            XCTAssertTrue(
                app.buttons.identified("portableDeckConflictUseLocal")
                    .waitUntilGone(timeout: 15)
            )
            waitForPortableImportCompletion(in: app)
            openTemplates(in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)["itemTypeRow-Portable Custom Revised"]
                    .waitUntilExists(timeout: 15)
            )
            closeTemplates(in: app)
        }

        try runJourneyActivity("PortableDeckUITests.testImportConflictCancel") {
            let app = launchAppForPortableImport(
                scenario: "type-conflict-local",
                file: fixtureURL("conflict.neodeck")
            )
            let conflict = app.buttons.identified("portableDeckConflictUseLocal")
            let cancel = app.buttons.identified("portableDeckConflictCancel")
            for _ in 0..<3 where conflict.exists {
                XCTAssertTrue(cancel.waitUntilHittable(timeout: 1))
                cancel.click()
                if conflict.waitUntilGone(timeout: 1) { break }
            }
            XCTAssertTrue(conflict.waitUntilGone(timeout: 3))
            waitForLibraryReady(in: app)
        }
    }

    func checkImportExportUITestsImportWithMediaDirectory() throws {
        let app = launchAppForImport(
            file: fixtureURL("import-with-media.json"),
            scenario: "import-with-media"
        )

        let chooseMedia = app.buttons.identified("chooseImportMediaDirectory")
        if chooseMedia.waitUntilExists(timeout: 3) {
            chooseMedia.click()
            chooseFileInOpenPanel(fixturesDirectory().appendingPathComponent("media"), in: app)
        }

        app.buttons.identified("confirmImport").click()
        dismissImportComplete(in: app)
        waitForItem(named: "Media Question", in: app, timeout: 10)
    }

    func checkImportExportUITestsImportFilePickerCancel() throws {
        let app = launchApp()
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        let importItem = app.menuItems.identified("Import…")
        XCTAssertTrue(importItem.waitUntilExists(timeout: 3))
        importItem.click()

        cancelFilePicker(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].waitUntilGone(timeout: 2))
        assertEmptyLibrary(in: app)
    }

    func checkImportExportUITestsImportDisabledDuringStudy() throws {
        let app = launchApp()
        addBasicItem(front: "Study Gate Q", back: "Study Gate A", in: app)
        startStudy(in: app)

        app.menuBarItems["File"].click()
        let importItem = app.menuItems.identified("Import…")
        XCTAssertTrue(importItem.waitUntilExists(timeout: 3))
        XCTAssertFalse(importItem.isEnabled)
        dismissOpenMenus(in: app)

        app.buttons.identified("endStudySession").click()
        if app.buttons.identified("confirmEndStudySession").waitUntilExists(timeout: 2) {
            app.buttons.identified("confirmEndStudySession").click()
        }
        waitForLibraryReady(in: app)
    }

    func checkImportExportUITestsImportDisabledDuringTemplates() throws {
        let app = launchApp()
        openTemplates(in: app)
        assertMenuDisabled("Import…", in: app)
        closeTemplates(in: app)
    }

    func checkImportExportUITestsImportProgressIndicator() throws {
        var rows = "Front,Back\n"
        for index in 0..<200 {
            rows += "Bulk \(index),Answer \(index)\n"
        }
        let file = try makeImportFixture(name: "bulk.csv", contents: rows)
        let app = launchAppForImport(file: file)
        app.buttons.identified("confirmImport").click()
        let progress = app.descendants(matching: .any)["importProgress"]
        _ = progress.waitUntilExists(timeout: 2)
        dismissImportComplete(in: app)
        waitForItem(named: "Bulk 0", in: app, timeout: 15)
    }

    func checkImportExportUITestsCSVImportItemTypePicker() throws {
        let file = try makeImportFixture(
            name: "typed.csv",
            contents: """
            Front,Back
            Alt Question,Alt Answer
            """
        )
        let app = launchAppForImport(file: file, scenario: "alternate-import-type")
        let picker = app.popUpButtons.identified("importItemTypePicker")
        XCTAssertTrue(picker.waitUntilExists(timeout: 5))
        selectPopUpOption(named: "Alternate", picker: picker, in: app)

        app.buttons.identified("confirmImport").click()
        dismissImportComplete(in: app)
        waitForItem(named: "Alt Question", in: app, timeout: 10)
    }
}
