import AppKit
import XCTest

extension FastFunctionalJourneyTests {
    func runSharedDecksAndAuthoringJourney() throws {
        var app = launchApp()

        try runJourneyActivity("DeckUITests.testCancelCreatingDeckLeavesSidebarUnchanged") {
            app.buttons.identified("newDeckToolbar").click()
            let cancel = app.buttons.identified("cancelCreateDeck")
            XCTAssertTrue(cancel.waitUntilExists(timeout: 3))
            cancel.click()
            XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitUntilExists(timeout: 3))
        }

        try runJourneyActivity("DeckUITests.testCreateDeckFromSidebar") {
            createDeck(named: "Lifecycle", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["deckRow-Lifecycle"].exists)
        }

        try runJourneyActivity("DeckUITests.testRenameDeck") {
            renameDeck(from: "Lifecycle", to: "Renamed", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["deckRow-Renamed"].waitUntilExists(timeout: 5))
        }

        try runJourneyActivity("DeckUITests.testCancelRenameKeepsOriginalDeckName") {
            let row = app.descendants(matching: .any).identified("deckRow-Renamed")
            row.rightClick()
            selectMenuItem("Rename", in: app)
            let cancel = app.buttons.identified("cancelRenameDeck")
            XCTAssertTrue(cancel.waitUntilExists(timeout: 3))
            cancel.click()
            XCTAssertTrue(row.waitUntilExists(timeout: 3))
        }

        try runJourneyActivity("DeckUITests.testCancelDeleteKeepsDeck") {
            let row = app.descendants(matching: .any).identified("deckRow-Renamed")
            openDeckDeleteConfirmation(for: row, in: app)
            XCTAssertTrue(app.buttons.identified("confirmDeleteDeck").exists)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons.identified("confirmDeleteDeck").waitUntilGone(timeout: 3))
            XCTAssertTrue(row.waitUntilExists(timeout: 3))
        }

        try runJourneyActivity("DeckUITests.testDeleteDeckWithConfirmation") {
            let row = app.descendants(matching: .any).identified("deckRow-Renamed")
            openDeckDeleteConfirmation(for: row, in: app)
            confirmDeckDeletion(in: app)
            XCTAssertTrue(row.waitUntilGone(timeout: 3))
        }

        app = launchApp(scenario: "deck-scoping")
        try runJourneyActivity("DeckUITests.testSwitchScopesFiltersItems") {
            selectScope("scopeRow-Unassigned", in: app)
            waitForItem(named: "Unassigned Item", in: app)
            XCTAssertFalse(app.descendants(matching: .any)["itemRow-Deck Item"].exists)

            selectScope("deckRow-Scoped", in: app)
            waitForItem(named: "Deck Item", in: app)
            XCTAssertFalse(app.descendants(matching: .any)["itemRow-Unassigned Item"].exists)
        }

        try runJourneyActivity("DeckUITests.testScopedStudyFromDeckSelection") {
            returnToLibrary(in: app)
            selectScope("deckRow-Scoped", in: app)
            startStudy(in: app)
            revealAndGrade("gradeGood", in: app)
            finishStudySession(in: app)
            assertNothingDue(in: app)
        }

        createDeck(named: "Parent", in: app)
        let parent = app.descendants(matching: .any).identified("deckRow-Parent")

        try runJourneyActivity("DeckUITests.testCreateSubdeckFromContextMenu") {
            parent.rightClick()
            selectMenuItem("New Subdeck", in: app)
            guard let container = modalContainer(in: app) else {
                XCTFail("Subdeck dialog did not appear")
                return
            }
            enterText("Child", into: container.textFields.firstMatch, app: app)
            app.buttons.identified("confirmCreateDeck").click()
            XCTAssertTrue(app.descendants(matching: .any)["deckRow-Child"].waitUntilExists(timeout: 5))
        }

        try runJourneyActivity("DeckUITests.testSelectingParentDoesNotExpandItsSubdecks") {
            let child = app.descendants(matching: .any).identified("deckRow-Child")
            let collapseButton = app.disclosureTriangles.firstMatch
            XCTAssertTrue(collapseButton.waitUntilExists(timeout: 3))
            collapseButton.click()
            XCTAssertTrue(child.waitUntilGone(timeout: 3))

            selectScope("deckRow-Parent", in: app)
            XCTAssertFalse(child.exists, "Selecting a parent row should leave it collapsed")

            let expandButton = app.disclosureTriangles.firstMatch
            XCTAssertTrue(expandButton.waitUntilExists(timeout: 3))
            expandButton.click()
            XCTAssertTrue(child.waitUntilExists(timeout: 3))
        }

        try runJourneyActivity("DeckUITests.testDeleteDeckRemovesSubdecksAndItems") {
            selectScope("deckRow-Child", in: app)
            openAddItem(in: app)
            enterText("Nested Item", into: field(named: "Front", in: app), app: app)
            enterText("Answer", into: field(named: "Back", in: app), app: app)
            saveAddItem(in: app)
            showSidebar(in: app)
            openDeckDeleteConfirmation(for: parent, in: app)
            confirmDeckDeletion(in: app)

            XCTAssertTrue(parent.waitUntilGone(timeout: 3))
            XCTAssertFalse(app.descendants(matching: .any)["deckRow-Child"].exists)
            selectScope("scopeRow-AllDecks", in: app)
            assertNoItem(named: "Nested Item", in: app)
        }

        // Authoring chapters need an empty unassigned scope, so reset once
        // here instead of rebuilding the app for every legacy check.
        let authoringApp = launchApp(scenario: "authoring-fields")

        try runJourneyActivity("AuthoringUITests.testUnassignedScopeEmptyState") {
            let visibleScreenHeight = try XCTUnwrap(NSScreen.main?.visibleFrame.height)
            XCTAssertLessThanOrEqual(authoringApp.windows.firstMatch.frame.height, visibleScreenHeight)
            selectScope("scopeRow-Unassigned", in: authoringApp)
            XCTAssertTrue(
                authoringApp.descendants(matching: .any)["emptyUnassignedState"]
                    .waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(authoringApp.buttons.identified("addItemEmptyState").waitUntilGone(timeout: 2))
        }

        try runJourneyActivity("AuthoringUITests.testEmptyDeckAddItem") {
            selectScope("deckRow-Empty Deck", in: authoringApp)
            let add = authoringApp.buttons.identified("addItemEmptyState")
            XCTAssertTrue(add.waitUntilExists(timeout: 5))
            add.click()
            XCTAssertTrue(field(named: "Front", in: authoringApp).waitUntilExists(timeout: 5))
            authoringApp.buttons.identified("cancelAddItem").click()
        }

        try runJourneyActivity("AuthoringUITests.testAddItemWithNumberField") {
            openAddItem(in: authoringApp, waitForDefaultField: false)
            selectPopUpOption(
                named: "Numeric",
                picker: authoringApp.popUpButtons.identified("addItemTypePicker"),
                in: authoringApp
            )
            selectPopUpOption(
                named: "Empty Deck",
                picker: authoringApp.popUpButtons.identified("addItemDeckPicker"),
                in: authoringApp
            )
            enterText("Count", into: field(named: "Front", in: authoringApp), app: authoringApp)
            enterText("42", into: field(named: "Back", in: authoringApp), app: authoringApp)
            saveAddItem(in: authoringApp)
            waitForItem(named: "Count", in: authoringApp)
        }
        try runJourneyActivity("LibraryUITests.testAddItemWithDeckPicker") {
            XCTAssertTrue(
                authoringApp.descendants(matching: .any)["itemRow-Count"].exists,
                "The item created with the deck picker should appear in that deck"
            )
        }

        try runJourneyActivity("AuthoringUITests.testAddItemWithMultipleItemTypes") {
            openAddItem(in: authoringApp, waitForDefaultField: false)
            selectPopUpOption(
                named: "Secondary",
                picker: authoringApp.popUpButtons.identified("addItemTypePicker"),
                in: authoringApp
            )
            authoringApp.buttons.identified("cancelAddItem").click()
        }

        try runJourneyActivity("AuthoringUITests.testClozeAuthoringMarkBlank") {
            openAddItem(in: authoringApp, waitForDefaultField: false)
            selectPopUpOption(
                named: "Cloze Author",
                picker: authoringApp.popUpButtons.identified("addItemTypePicker"),
                in: authoringApp
            )

            let clozeField = authoringApp.textViews.identified("field-Front")
            XCTAssertTrue(clozeField.waitUntilExists(timeout: 5))
            clozeField.click()
            clozeField.typeText("The capital of France is Paris.")
            clozeField.typeKey("a", modifierFlags: [.command])

            let markBlank = authoringApp.buttons.identified("field-Front-markBlank")
            XCTAssertTrue(markBlank.waitUntilExists(timeout: 3))
            markBlank.click()
            authoringApp.buttons.identified("cancelAddItem").click()
        }

        try runJourneyActivity("AuthoringUITests.testItemPreviewRendersRichText") {
            openAddItem(in: authoringApp, waitForDefaultField: false)
            let itemTypePicker = authoringApp.popUpButtons.identified("addItemTypePicker")
            if itemTypePicker.exists {
                selectPopUpOption(named: "Basic", picker: itemTypePicker, in: authoringApp)
            }
            assertFormattedField(
                named: "Front",
                buttonID: "formatBold",
                style: "bold",
                text: "PreviewBold",
                in: authoringApp
            )
            enterText(
                "Preview Back",
                into: field(named: "Back", in: authoringApp),
                app: authoringApp
            )
            saveAddItem(in: authoringApp)
            openItemDetail(named: "PreviewBold", in: authoringApp)
            XCTAssertTrue(
                authoringApp.staticTexts.matching(
                    NSPredicate(
                        format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "PreviewBold",
                        "PreviewBold"
                    )
                ).firstMatch.waitUntilExists(timeout: 5)
            )
            returnToLibrary(in: authoringApp)
        }

        let mediaApp = launchApp(scenario: "image-missing-description")
        waitForItem(named: "Image", in: mediaApp)
        openItemDetail(named: "Image", in: mediaApp)
        openItemEditor(in: mediaApp)
        let mediaSave = mediaApp.buttons.identified("saveEditItem")
        try runJourneyActivity("AuthoringUITests.testMediaFieldRequiresDescription") {
            XCTAssertTrue(mediaSave.exists)
            XCTAssertFalse(mediaSave.isEnabled)
        }
        try runJourneyActivity("LibraryUITests.testImageEditRequiresDescriptionBeforeSaving") {
            let save = mediaApp.buttons.identified("saveEditItem")
            XCTAssertTrue(save.exists)
            XCTAssertFalse(save.isEnabled)
        }
        mediaApp.buttons.identified("cancelEditItem").click()
        returnToLibrary(in: mediaApp)

        try runJourneyActivity("AuthoringUITests.testEditItemChangeItemType") {
            openItemDetail(named: "Image", in: mediaApp)
            openItemEditor(in: mediaApp)
            XCTAssertTrue(mediaApp.buttons.identified("saveEditItem").exists)
            XCTAssertFalse(
                mediaApp.popUpButtons.identified("addItemTypePicker").exists,
                "Changing item type after creation is intentionally unavailable"
            )
            mediaApp.buttons.identified("cancelEditItem").click()
        }
    }

    private func renameDeck(from oldName: String, to newName: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any).identified("deckRow-\(oldName)")
        row.rightClick()
        selectMenuItem("Rename", in: app)
        guard let container = modalContainer(in: app) else {
            XCTFail("Rename dialog did not appear")
            return
        }
        enterText(newName, into: container.textFields.firstMatch, app: app)
        if app.buttons.identified("confirmRenameDeck").exists {
            app.buttons.identified("confirmRenameDeck").click()
        } else {
            container.buttons.identified("Save").click()
        }
    }

    private func openDeckDeleteConfirmation(for row: XCUIElement, in app: XCUIApplication) {
        let confirmation = app.buttons.identified("confirmDeleteDeck")
        for _ in 0..<2 {
            row.rightClick()
            let contextDelete = app.menuItems.matching(
                NSPredicate(format: "title == 'Delete' AND enabled == true")
            ).firstMatch
            XCTAssertTrue(contextDelete.waitUntilExists(timeout: 3))
            contextDelete.click()
            if confirmation.waitUntilExists(timeout: 2) { return }
        }
        XCTFail("Delete deck confirmation did not appear")
    }

    private func confirmDeckDeletion(in app: XCUIApplication) {
        if app.buttons.identified("confirmDeleteDeck").waitUntilExists(timeout: 3) {
            app.buttons.identified("confirmDeleteDeck").click()
        } else if let container = modalContainer(in: app) {
            container.buttons.identified("Delete Deck").click()
        } else {
            XCTFail("Delete deck confirmation did not appear")
        }
    }

    func checkDeckUITestsCreateDeckFromSidebar() throws {
        let app = launchApp()
        createDeck(named: "Geography", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["deckRow-Geography"].exists)
    }

    func checkDeckUITestsRenameDeck() throws {
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

        XCTAssertTrue(app.descendants(matching: .any)["deckRow-New Name"].waitUntilExists(timeout: 10))
    }

    func checkDeckUITestsDeleteDeckWithConfirmation() throws {
        let app = launchApp()
        createDeck(named: "Temporary", in: app)

        showSidebar(in: app)
        let deckRow = app.descendants(matching: .any).identified("deckRow-Temporary")
        deckRow.rightClick()
        let contextDelete = app.menuItems.matching(
            NSPredicate(format: "title == 'Delete' AND enabled == true")
        ).firstMatch
        if contextDelete.exists {
            contextDelete.click()
        } else {
            app.menuItems["Delete"].firstMatch.click()
        }

        if app.buttons.identified("confirmDeleteDeck").waitUntilExists(timeout: 5) {
            app.buttons.identified("confirmDeleteDeck").click()
        } else if let container = modalContainer(in: app) {
            container.buttons.identified("Delete Deck").click()
        } else {
            XCTFail("Delete deck confirmation did not appear")
        }

        XCTAssertTrue(app.descendants(matching: .any)["deckRow-Temporary"].waitUntilGone(timeout: 3))
    }

    func checkDeckUITestsSwitchScopesFiltersItems() throws {
        let app = launchApp()
        createDeck(named: "Scoped", in: app)

        selectScope("scopeRow-AllDecks", in: app)
        addBasicItem(front: "Unassigned Item", back: "A", in: app)

        openAddItem(in: app)
        let deckPicker = app.popUpButtons.identified("addItemDeckPicker")
        if deckPicker.waitUntilExists(timeout: 2) {
            deckPicker.click()
            app.menuItems.identified("Scoped").click()
        }
        enterText("Deck Item", into: field(named: "Front", in: app), app: app)
        enterText("B", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("scopeRow-Unassigned", in: app)
        waitForItem(named: "Unassigned Item", in: app)
        assertNoItem(named: "Deck Item", in: app)

        selectScope("deckRow-Scoped", in: app)
        waitForItem(named: "Deck Item", in: app)
        assertNoItem(named: "Unassigned Item", in: app)
    }

    func checkDeckUITestsScopedStudyFromDeckSelection() throws {
        let app = launchApp()
        createDeck(named: "Study Deck", in: app)

        openAddItem(in: app)
        if app.popUpButtons.identified("addItemDeckPicker").waitUntilExists(timeout: 2) {
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

        assertNothingDue(in: app)
    }

    func checkDeckUITestsCancelCreatingDeckLeavesSidebarUnchanged() throws {
        let app = launchApp()
        app.buttons.identified("newDeckToolbar").click()
        XCTAssertTrue(app.buttons.identified("cancelCreateDeck").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelCreateDeck").click()

        XCTAssertFalse(app.descendants(matching: .any)["deckRow-Cancelled"].exists)
        XCTAssertTrue(app.buttons.identified("newDeckToolbar").waitUntilExists(timeout: 3))
    }

    func checkDeckUITestsCancelRenameKeepsOriginalDeckName() throws {
        let app = launchApp()
        createDeck(named: "Keep Name", in: app)

        let row = app.descendants(matching: .any).identified("deckRow-Keep Name")
        row.rightClick()
        app.menuItems.identified("Rename").click()
        XCTAssertTrue(app.buttons.identified("cancelRenameDeck").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelRenameDeck").click()

        XCTAssertTrue(row.waitUntilExists(timeout: 3))
    }

    func checkDeckUITestsCancelDeleteKeepsDeck() throws {
        let app = launchApp()
        createDeck(named: "Keep Deck", in: app)

        let row = app.descendants(matching: .any).identified("deckRow-Keep Deck")
        row.rightClick()
        let contextDelete = app.menuItems.matching(
            NSPredicate(format: "title == 'Delete' AND enabled == true")
        ).firstMatch
        XCTAssertTrue(contextDelete.waitUntilExists(timeout: 3))
        contextDelete.click()
        XCTAssertNotNil(modalContainer(in: app))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(row.waitUntilExists(timeout: 3))
    }

    func checkDeckUITestsCreateSubdeckFromContextMenu() throws {
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

        XCTAssertTrue(app.staticTexts["Child"].waitUntilExists(timeout: 5))
    }

    func checkDeckUITestsSelectingParentDoesNotExpandItsSubdecks() throws {
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

        let child = app.descendants(matching: .any).identified("deckRow-Child")
        XCTAssertTrue(child.waitUntilExists(timeout: 5))
        let collapseButton = app.disclosureTriangles.firstMatch
        XCTAssertTrue(collapseButton.waitUntilExists(timeout: 3))
        collapseButton.click()
        XCTAssertTrue(child.waitUntilGone(timeout: 3))

        selectScope("deckRow-Parent", in: app)
        XCTAssertFalse(child.exists, "Selecting a parent row should leave it collapsed")

        let expandButton = app.disclosureTriangles.firstMatch
        XCTAssertTrue(expandButton.waitUntilExists(timeout: 3))
        expandButton.click()
        XCTAssertTrue(child.waitUntilExists(timeout: 3))
    }

    func checkDeckUITestsDeleteDeckRemovesSubdecksAndItems() throws {
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
        XCTAssertTrue(app.staticTexts["Child"].waitUntilExists(timeout: 5))

        selectScope("deckRow-Child", in: app)
        addBasicItem(front: "Nested Item", back: "Answer", in: app)

        showSidebar(in: app)
        parent.rightClick()
        app.menuItems.matching(
            NSPredicate(format: "title == 'Delete' AND enabled == true")
        ).firstMatch.click()
        XCTAssertTrue(app.buttons.identified("confirmDeleteDeck").waitUntilExists(timeout: 5))
        app.buttons.identified("confirmDeleteDeck").click()

        XCTAssertTrue(app.descendants(matching: .any)["deckRow-Parent"].waitUntilGone(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["deckRow-Child"].exists)
        selectScope("scopeRow-AllDecks", in: app)
        assertNoItem(named: "Nested Item", in: app)
    }
}
