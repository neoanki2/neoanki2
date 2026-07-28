import XCTest

final class ImportExportUITests: NeoAnkiUITestCase {
    func testImportWithMediaDirectory() throws {
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

    func testImportFilePickerCancel() throws {
        let app = launchApp()
        dismissOpenMenus(in: app)
        app.menuBarItems["File"].click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let importItem = app.menuItems.identified("Import…")
        XCTAssertTrue(importItem.waitUntilExists(timeout: 3))
        importItem.click()

        cancelFilePicker(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].waitUntilGone(timeout: 2))
        assertEmptyLibrary(in: app)
    }

    func testImportDisabledDuringStudy() throws {
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

    func testImportDisabledDuringTemplates() throws {
        let app = launchApp()
        openTemplates(in: app)
        assertMenuDisabled("Import…", in: app)
        closeTemplates(in: app)
    }

    func testImportProgressIndicator() throws {
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

    func testCSVImportItemTypePicker() throws {
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
