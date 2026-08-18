import XCTest

extension FastFunctionalJourneyTests {
    func runSharedLibraryAndBrowseJourney() throws {
        let persistenceLabel = "fast-library-\(UUID().uuidString)"
        let app = launchApp(databaseLabel: persistenceLabel)

        runJourneyActivity("LibraryUITests.testAppLaunchesWithEmptyLibrary") {
            assertEmptyLibrary(in: app)
        }

        runJourneyActivity("ScopeHomeAndBrowseUITests.testAddItemHasAMenuHomeUnderFile") {
            let cancel = app.buttons.identified("cancelAddItem")
            for _ in 0..<2 where !cancel.exists {
                app.menuBarItems["File"].click()
                let newItem = app.menuItems.identified("New Item")
                XCTAssertTrue(newItem.waitUntilExists(timeout: 3))
                XCTAssertTrue(newItem.isEnabled)
                newItem.click()
                if cancel.waitUntilExists(timeout: 2) { break }
                dismissOpenMenus(in: app)
            }
            XCTAssertTrue(app.buttons.identified("cancelAddItem").waitUntilExists(timeout: 3))
            XCTAssertTrue(field(named: "Front", in: app).waitUntilExists(timeout: 3))
        }

        runJourneyActivity("LibraryUITests.testAddItemValidationDisablesSave") {
            enterText("Only front", into: field(named: "Front", in: app), app: app)
            XCTAssertFalse(app.buttons.identified("saveAddItem").isEnabled)
        }

        runJourneyActivity("LibraryUITests.testWhitespaceOnlyRequiredFieldsCannotBeSaved") {
            enterText("   ", into: field(named: "Front", in: app), app: app)
            XCTAssertFalse(app.buttons.identified("saveAddItem").isEnabled)
        }

        runJourneyActivity("LibraryUITests.testRichTextEditorFormattingButtonsApplyStyles") {
            assertFormattedStyles(
                named: "Front",
                text: "FrontStyles",
                styles: [
                    ("formatBold", "bold"),
                    ("formatItalic", "italic"),
                    ("formatUnderline", "underline"),
                ],
                in: app
            )
            assertFormattedStyles(
                named: "Back",
                text: "BackStyles",
                styles: [
                    ("formatStrikethrough", "strikethrough"),
                    ("formatHighlight", "highlight"),
                    ("formatCode", "code"),
                ],
                in: app
            )
        }

        runJourneyActivity("LibraryUITests.testAddItemCancelReturnsToLibrary") {
            app.buttons.identified("cancelAddItem").click()
            if app.buttons.identified("confirmDiscardItem").exists {
                app.buttons.identified("confirmDiscardItem").click()
            }
            assertEmptyLibrary(in: app)
        }

        runJourneyActivity("LibraryUITests.testAddItemFromEmptyState") {
            addBasicItem(front: "Alpha", back: "Beta", in: app)
        }

        runJourneyActivity("LibraryUITests.testAddItemFromToolbar") {
            returnToLibrary(in: app)
            openAddItem(in: app)
            enterText("France", into: field(named: "Front", in: app), app: app)
            enterText("Paris", into: field(named: "Back", in: app), app: app)
            saveAddItem(in: app)
            app.terminate()
        }

        let relaunched = launchApp(databaseLabel: persistenceLabel)
        waitForItem(named: "Alpha", in: relaunched)
        leaveBrowseMode(in: relaunched)

        runJourneyActivity("ScopeHomeAndBrowseUITests.testScopeHomeLeadsWithDueCountAndStudy") {
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["scopeHomeDueHeadline"]
                    .waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(relaunched.descendants(matching: .any)["scopeHomeCardStates"].exists)
            XCTAssertTrue(relaunched.buttons.identified("studyButton").isEnabled)
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["scopeHomeBrowseLink"]
                    .waitUntilExists(timeout: 3)
            )
        }

        runJourneyActivity("ScopeHomeAndBrowseUITests.testScopeHomeDoesNotRevealAnswers") {
            XCTAssertFalse(
                relaunched.staticTexts.matching(
                    NSPredicate(
                        format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "Paris",
                        "Paris"
                    )
                ).firstMatch.exists
            )
        }

        runJourneyActivity(
            "ScopeHomeAndBrowseUITests.testBrowseOpensWithKeyboardShortcutAndClosesWithEscape"
        ) {
            relaunched.typeKey("b", modifierFlags: [.command, .option])
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["itemBrowserTable"]
                    .waitUntilExists(timeout: 3)
            )
            XCTAssertTrue(relaunched.descendants(matching: .any)["itemRow-Alpha"].exists)
            relaunched.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["scopeHomeDueHeadline"]
                    .waitUntilExists(timeout: 3)
            )
        }

        runJourneyActivity("ScopeHomeAndBrowseUITests.testBrowseOpensFromTheLibraryMenu") {
            relaunched.menuBarItems["Library"].click()
            selectMenuItem("Browse Items", in: relaunched)
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["itemBrowserTable"]
                    .waitUntilExists(timeout: 3)
            )
        }

        let paris = relaunched.staticTexts.matching(
            NSPredicate(format: "value == %@ OR label == %@", "Paris", "Paris")
        ).firstMatch
        runJourneyActivity("ScopeHomeAndBrowseUITests.testBrowseHidesTheAnswerColumnByDefault") {
            XCTAssertTrue(relaunched.descendants(matching: .any)["itemRow-France"].exists)
            XCTAssertFalse(paris.exists)
        }

        runJourneyActivity(
            "ScopeHomeAndBrowseUITests.testBrowseRevealsTheAnswerColumnFromTheLibraryMenu"
        ) {
            relaunched.menuBarItems["Library"].click()
            selectMenuItem("Show Answer Column", in: relaunched)
            XCTAssertTrue(paris.waitUntilExists(timeout: 3))
            relaunched.menuBarItems["Library"].click()
            selectMenuItem("Hide Answer Column", in: relaunched)
            XCTAssertTrue(paris.waitUntilGone(timeout: 3))
        }

        runJourneyActivity(
            "ScopeHomeAndBrowseUITests.testAnswerColumnChoiceSurvivesLeavingBrowseMode"
        ) {
            relaunched.typeKey("a", modifierFlags: [.command, .option])
            XCTAssertTrue(paris.waitUntilExists(timeout: 3))
            leaveBrowseMode(in: relaunched)
            enterBrowseMode(in: relaunched)
            XCTAssertTrue(paris.exists)
        }

        runJourneyActivity("ScopeHomeAndBrowseUITests.testBrowseSearchNarrowsRowsAndReportsNoResults") {
            let search = relaunched.searchFields.firstMatch
            XCTAssertTrue(search.waitUntilExists(timeout: 3))
            search.click()
            search.typeText("France")
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["itemRow-France"]
                    .waitUntilExists(timeout: 3)
            )
            XCTAssertFalse(relaunched.descendants(matching: .any)["itemRow-Alpha"].exists)
            search.typeKey("a", modifierFlags: [.command])
            search.typeText("Ukraine")
            XCTAssertTrue(
                relaunched.descendants(matching: .any)["browseNoSearchResults"]
                    .waitUntilExists(timeout: 3)
            )
            search.typeKey("a", modifierFlags: [.command])
            search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        }

        let seeded = launchApp(scenario: "library-browse")
        openItemDetail(named: "Original", in: seeded)
        runJourneyActivity("LibraryUITests.testOpenItemDetail") {
            XCTAssertTrue(seeded.buttons.identified("deleteItem").exists)
        }

        runJourneyActivity("LibraryUITests.testDirtyItemEditCanKeepEditingThenDiscard") {
            openItemEditor(in: seeded)
            enterText("Changed", into: field(named: "Front", in: seeded), app: seeded)
            seeded.buttons.identified("cancelEditItem").click()
            XCTAssertTrue(seeded.buttons.identified("cancelDiscardItem").waitUntilExists(timeout: 3))
            seeded.buttons.identified("cancelDiscardItem").click()
            XCTAssertTrue(seeded.buttons.identified("saveEditItem").exists)
            seeded.buttons.identified("cancelEditItem").click()
            seeded.buttons.identified("confirmDiscardItem").click()
            XCTAssertTrue(seeded.buttons.identified("deleteItem").waitUntilExists(timeout: 3))
        }

        runJourneyActivity("LibraryUITests.testEditItemFromDetailUpdatesLibraryAndPreview") {
            openItemEditor(in: seeded)
            enterText("Japan", into: field(named: "Front", in: seeded), app: seeded)
            enterText("Tokyo", into: field(named: "Back", in: seeded), app: seeded)
            let save = seeded.buttons.identified("saveEditItem")
            XCTAssertTrue(save.isEnabled)
            save.click()
            XCTAssertTrue(save.waitUntilGone(timeout: 5))
            XCTAssertTrue(
                seeded.staticTexts.matching(
                    NSPredicate(
                        format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "Japan",
                        "Japan"
                    )
                ).firstMatch.waitUntilExists(timeout: 3)
            )
        }

        runJourneyActivity("LibraryUITests.testBackFromItemDetailReturnsToLibrary") {
            closeItemDetail(in: seeded)
            waitForItem(named: "Japan", in: seeded)
            XCTAssertFalse(seeded.buttons.identified("deleteItem").exists)
            assertNoItem(named: "Original", in: seeded)
        }

        openItemDetail(named: "Keep Item", in: seeded)
        runJourneyActivity("LibraryUITests.testDeleteItemCancellationPreservesItem") {
            seeded.buttons.identified("deleteItem").click()
            XCTAssertTrue(seeded.buttons.identified("cancelDeleteItem").waitUntilExists(timeout: 3))
            seeded.buttons.identified("cancelDeleteItem").click()
            XCTAssertTrue(seeded.buttons.identified("deleteItem").waitUntilExists(timeout: 3))
            returnToLibrary(in: seeded)
            waitForItem(named: "Keep Item", in: seeded)
        }

        openItemDetail(named: "Remove", in: seeded)
        runJourneyActivity("LibraryUITests.testDeleteItemFromDetail") {
            seeded.buttons.identified("deleteItem").click()
            seeded.buttons.identified("confirmDeleteItem").click()
            assertNoItem(named: "Remove", in: seeded)
        }

        openItemDetail(named: "Movable", in: seeded)
        runJourneyActivity("LibraryUITests.testMoveItemToDeckFromDetail") {
            let picker = seeded.descendants(matching: .any).identified("itemDeckPicker")
            XCTAssertTrue(picker.waitUntilExists(timeout: 3))
            selectPopUpOption(named: "Target Deck", picker: picker, in: seeded)
            returnToLibrary(in: seeded)
            selectScope("deckRow-Target Deck", in: seeded)
            waitForItem(named: "Movable", in: seeded)
        }

        selectScope("scopeRow-AllDecks", in: seeded)
        enterBrowseMode(in: seeded)
        runJourneyActivity("ScopeHomeAndBrowseUITests.testBrowseDeletesASelectedItem") {
            let row = seeded.descendants(matching: .any).identified("itemRow-Browse Delete")
            XCTAssertTrue(row.waitUntilExists(timeout: 3))
            row.click()
            seeded.buttons.identified("browseDeleteSelection").click()
            seeded.buttons.identified("browseConfirmDelete").click()
            XCTAssertTrue(row.waitUntilGone(timeout: 5))
            XCTAssertTrue(seeded.descendants(matching: .any)["itemRow-Keep Item"].exists)
        }

        runJourneyActivity("ScopeHomeAndBrowseUITests.testBrowseMovesASelectedItemToADeck") {
            let row = seeded.descendants(matching: .any).identified("itemRow-Browse Move")
            row.click()
            let menu = seeded.descendants(matching: .any).identified("browseMoveToDeck")
            XCTAssertTrue(menu.waitUntilExists(timeout: 3))
            menu.click()
            selectMenuItem("Target Deck", in: seeded)
            selectScope("deckRow-Target Deck", in: seeded)
            waitForItem(named: "Browse Move", in: seeded)
        }

        runJourneyActivity("LibraryUITests.testDeleteAllUnassignedFromToolbar") {
            returnToLibrary(in: seeded)
            selectScope("scopeRow-Unassigned", in: seeded)
            let deleteAll = seeded.buttons.identified("deleteAllUnassignedToolbar")
            XCTAssertTrue(deleteAll.waitUntilExists(timeout: 3))
            deleteAll.click()
            seeded.buttons.identified("confirmDeleteAllUnassigned").click()
            XCTAssertTrue(
                seeded.descendants(matching: .any).identified("scopeRow-Unassigned")
                    .waitUntilGone(timeout: 5),
                "Deleting the final unassigned item should remove the virtual scope"
            )
            selectScope("scopeRow-AllDecks", in: seeded)
            waitForItem(named: "Deck Item", in: seeded)
            assertNoItem(named: "Japan", in: seeded)
        }

        let sidebarDeleteApp = launchApp(scenario: "library-browse")
        runJourneyActivity("LibraryUITests.testDeleteAllUnassignedFromSidebarMenu") {
            showSidebar(in: sidebarDeleteApp)
            let unassigned = sidebarDeleteApp.descendants(matching: .any)
                .identified("scopeRow-Unassigned")
            unassigned.rightClick()
            selectMenuItem("Delete All", in: sidebarDeleteApp)
            sidebarDeleteApp.buttons.identified("confirmDeleteAllUnassigned").click()
            XCTAssertTrue(
                sidebarDeleteApp.descendants(matching: .any).identified("scopeRow-Unassigned")
                    .waitUntilGone(timeout: 5),
                "Deleting the final unassigned item should remove the virtual scope"
            )
            assertNoItem(named: "Original", in: sidebarDeleteApp)
        }

    }

    func checkLibraryUITestsBootstrapFailureShowsSafeErrorState() throws {
        let app = launchApp(
            environment: ["NEOANKI_TEST_BOOTSTRAP_FAILURE": "1"],
            waitForLibrary: false
        )

        XCTAssertTrue(app.descendants(matching: .any)["bootstrapError"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["Could Not Start"].exists)
        XCTAssertFalse(app.buttons.identified("addItemToolbar").exists)
    }

    func checkLibraryUITestsAppLaunchesWithEmptyLibrary() throws {
        let app = launchApp()
        assertEmptyLibrary(in: app)
    }

    func checkLibraryUITestsAddItemFromEmptyState() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
    }

    func checkLibraryUITestsAddItemFromToolbar() throws {
        let databaseLabel = UUID().uuidString
        let app = launchApp(databaseLabel: databaseLabel)
        addBasicItem(front: "Alpha", back: "Beta", in: app)

        app.terminate()
        runningApp = nil

        let relaunched = launchApp(databaseLabel: databaseLabel)
        waitForItem(named: "Alpha", in: relaunched)
    }

    func checkLibraryUITestsRichTextEditorFormattingButtonsApplyStyles() throws {
        let app = launchApp()
        openAddItem(in: app)

        assertFormattedField(named: "Front", buttonID: "formatBold", style: "bold", text: "BoldWord", in: app)
        assertFormattedField(named: "Front", buttonID: "formatItalic", style: "italic", text: "ItalicWord", in: app)
        assertFormattedField(named: "Front", buttonID: "formatUnderline", style: "underline", text: "UnderlineWord", in: app)
        assertFormattedField(named: "Back", buttonID: "formatStrikethrough", style: "strikethrough", text: "StrikeWord", in: app)
        assertFormattedField(named: "Back", buttonID: "formatHighlight", style: "highlight", text: "HighlightWord", in: app)
        assertFormattedField(named: "Back", buttonID: "formatCode", style: "code", text: "CodeWord", in: app)
    }

    func checkLibraryUITestsAddItemCancelReturnsToLibrary() throws {
        let app = launchApp()
        openAddItem(in: app)
        app.buttons.identified("cancelAddItem").click()
        assertEmptyLibrary(in: app)
    }

    func checkLibraryUITestsAddItemValidationDisablesSave() throws {
        let app = launchApp()
        openAddItem(in: app)
        enterText("Only front", into: field(named: "Front", in: app), app: app)

        let save = app.buttons.identified("saveAddItem")
        XCTAssertTrue(save.waitUntilExists(timeout: 2))
        XCTAssertFalse(save.isEnabled)
    }

    func checkLibraryUITestsOpenItemDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Detail", back: "View", in: app)
        openItemDetail(named: "Detail", in: app)
        XCTAssertTrue(app.buttons.identified("deleteItem").exists)
    }

    func checkLibraryUITestsBackFromItemDetailReturnsToLibrary() throws {
        let app = launchApp()
        addBasicItem(front: "Back Test", back: "View", in: app)
        openItemDetail(named: "Back Test", in: app)

        closeItemDetail(in: app)

        waitForItem(named: "Back Test", in: app)
        XCTAssertFalse(app.buttons.identified("deleteItem").exists)
    }

    func checkLibraryUITestsDeleteAllUnassignedFromToolbar() throws {
        let app = launchApp()
        addBasicItem(front: "Loose Item", back: "A", in: app)
        createDeck(named: "Keep Deck", in: app)

        openAddItem(in: app)
        let deckPicker = app.popUpButtons.identified("addItemDeckPicker")
        if deckPicker.waitUntilExists(timeout: 2) {
            deckPicker.click()
            app.menuItems.identified("Keep Deck").click()
        }
        enterText("Deck Item", into: field(named: "Front", in: app), app: app)
        enterText("B", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("scopeRow-Unassigned", in: app)
        waitForItem(named: "Loose Item", in: app)
        returnToLibrary(in: app)

        let deleteAll = app.buttons.identified("deleteAllUnassignedToolbar")
        XCTAssertTrue(deleteAll.waitUntilExists(timeout: 5))
        deleteAll.click()
        XCTAssertTrue(app.buttons.identified("confirmDeleteAllUnassigned").waitUntilExists(timeout: 5))
        app.buttons.identified("confirmDeleteAllUnassigned").click()

        XCTAssertTrue(
            app.descendants(matching: .any).identified("scopeRow-Unassigned")
                .waitUntilGone(timeout: 10),
            "Deleting the final unassigned item should remove the virtual scope"
        )
        selectScope("scopeRow-AllDecks", in: app)
        waitForItem(named: "Deck Item", in: app)
        assertNoItem(named: "Loose Item", in: app)
    }

    func checkLibraryUITestsDeleteAllUnassignedFromSidebarMenu() throws {
        let app = launchApp()
        addBasicItem(front: "Sidebar Delete", back: "A", in: app)

        showSidebar(in: app)
        let unassigned = app.descendants(matching: .any).identified("scopeRow-Unassigned")
        unassigned.rightClick()
        app.menuItems.identified("Delete All").click()
        XCTAssertTrue(app.buttons.identified("confirmDeleteAllUnassigned").waitUntilExists(timeout: 5))
        app.buttons.identified("confirmDeleteAllUnassigned").click()

        XCTAssertTrue(
            app.descendants(matching: .any).identified("scopeRow-Unassigned")
                .waitUntilGone(timeout: 10),
            "Deleting the final unassigned item should remove the virtual scope"
        )
        assertNoItem(named: "Sidebar Delete", in: app)
    }

    func checkLibraryUITestsEditItemFromDetailUpdatesLibraryAndPreview() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        openItemDetail(named: "France", in: app)

        openItemEditor(in: app)
        enterText("Japan", into: field(named: "Front", in: app), app: app)
        enterText("Tokyo", into: field(named: "Back", in: app), app: app)
        let save = app.buttons.identified("saveEditItem")
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitUntilGone(timeout: 10))

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "Japan", "Japan")
        ).firstMatch.waitUntilExists(timeout: 5))
        returnToLibrary(in: app)
        waitForItem(named: "Japan", in: app)
        assertNoItem(named: "France", in: app)
    }

    func checkLibraryUITestsDirtyItemEditCanKeepEditingThenDiscard() throws {
        let app = launchApp()
        addBasicItem(front: "Original", back: "Answer", in: app)
        openItemDetail(named: "Original", in: app)

        openItemEditor(in: app)
        enterText("Changed", into: field(named: "Front", in: app), app: app)
        app.buttons.identified("cancelEditItem").click()
        XCTAssertTrue(app.buttons.identified("cancelDiscardItem").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelDiscardItem").click()
        XCTAssertTrue(app.buttons.identified("saveEditItem").exists)

        app.buttons.identified("cancelEditItem").click()
        app.buttons.identified("confirmDiscardItem").click()
        XCTAssertTrue(app.buttons.identified("deleteItem").waitUntilExists(timeout: 5))
        returnToLibrary(in: app)
        waitForItem(named: "Original", in: app)
        assertNoItem(named: "Changed", in: app)
    }

    func checkLibraryUITestsImageEditRequiresDescriptionBeforeSaving() throws {
        let app = launchApp(scenario: "image-missing-description")
        waitForItem(named: "Image", in: app)
        openItemDetail(named: "Image", in: app)

        openItemEditor(in: app)
        let save = app.buttons.identified("saveEditItem")
        XCTAssertTrue(save.waitUntilExists(timeout: 5))
        XCTAssertFalse(save.isEnabled)
    }

    func checkLibraryUITestsDeleteItemFromDetail() throws {
        let app = launchApp()
        addBasicItem(front: "Remove", back: "Me", in: app)
        openItemDetail(named: "Remove", in: app)

        app.buttons.identified("deleteItem").click()
        app.buttons.identified("confirmDeleteItem").click()

        assertEmptyLibrary(in: app)
        assertNoItem(named: "Remove", in: app)
    }

    func checkLibraryUITestsMoveItemToDeckFromDetail() throws {
        let app = launchApp()
        createDeck(named: "Target Deck", in: app)
        addBasicItem(front: "Movable", back: "Item", in: app)
        openItemDetail(named: "Movable", in: app)

        let picker = app.descendants(matching: .any).identified("itemDeckPicker")
        XCTAssertTrue(picker.waitUntilExists(timeout: 5))
        picker.click()
        let deckMenuItem = app.menuItems.identified("Target Deck")
        XCTAssertTrue(deckMenuItem.waitUntilExists(timeout: 3))
        deckMenuItem.click()

        returnToLibrary(in: app)
        selectScope("deckRow-Target Deck", in: app)
        waitForItem(named: "Movable", in: app, timeout: 15)
    }

    func checkLibraryUITestsAddItemWithDeckPicker() throws {
        let app = launchApp()
        createDeck(named: "History", in: app)

        openAddItem(in: app)
        let deckPicker = app.popUpButtons.identified("addItemDeckPicker")
        if deckPicker.waitUntilExists(timeout: 2) {
            deckPicker.click()
            app.menuItems.identified("History").click()
        }

        enterText("Rome", into: field(named: "Front", in: app), app: app)
        enterText("Italy", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        selectScope("deckRow-History", in: app)
        waitForItem(named: "Rome", in: app)
    }

    func checkLibraryUITestsDeleteItemCancellationPreservesItem() throws {
        let app = launchApp()
        addBasicItem(front: "Keep Item", back: "Still Here", in: app)
        openItemDetail(named: "Keep Item", in: app)

        app.buttons.identified("deleteItem").click()
        XCTAssertTrue(app.buttons.identified("cancelDeleteItem").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelDeleteItem").click()

        XCTAssertTrue(app.buttons.identified("deleteItem").waitUntilExists(timeout: 3))
        returnToLibrary(in: app)
        waitForItem(named: "Keep Item", in: app)
    }

    func checkLibraryUITestsWhitespaceOnlyRequiredFieldsCannotBeSaved() throws {
        let app = launchApp()
        openAddItem(in: app)
        enterText("   ", into: field(named: "Front", in: app), app: app)

        XCTAssertFalse(app.buttons.identified("saveAddItem").isEnabled)
    }

    func checkLibraryUITestsJSONImportThroughSystemFilePicker() throws {
        let file = try makeImportFixture(
            name: "items.json",
            contents: """
            {
              "itemType": "Basic",
              "rows": [
                { "Front": "Imported Question", "Back": "Imported Answer" }
              ]
            }
            """
        )
        let app = launchAppForImport(file: file)
        app.buttons.identified("confirmImport").click()
        _ = app.buttons.identified("confirmImport").waitUntilGone(timeout: 30)
        dismissImportComplete(in: app)
        waitForItem(named: "Imported Question", in: app, timeout: 10)
    }

    func checkLibraryUITestsCSVImportSelectsItemTypeAndImportsRows() throws {
        let file = try makeImportFixture(
            name: "items.csv",
            contents: """
            Front,Back,tags
            CSV Question,CSV Answer,imported
            """
        )
        let app = launchAppForImport(file: file)
        XCTAssertTrue(app.popUpButtons.identified("importItemTypePicker").waitUntilExists(timeout: 3))
        let importButton = app.buttons.identified("confirmImport")
        XCTAssertTrue(importButton.isEnabled)
        importButton.click()
        _ = importButton.waitUntilGone(timeout: 30)
        dismissImportComplete(in: app)
        waitForItem(named: "CSV Question", in: app, timeout: 10)
    }

    func checkLibraryUITestsImportValidationKeepsSheetOpenAndLibraryUnchanged() throws {
        let file = try makeImportFixture(
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
        let app = launchAppForImport(file: file)

        XCTAssertTrue(app.buttons.identified("confirmImport").waitUntilExists(timeout: 10))
        app.buttons.identified("confirmImport").click()
        XCTAssertTrue(app.descendants(matching: .any)["importError"].waitUntilExists(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["importSheet"].exists)
        app.buttons.identified("cancelImport").click()
        assertEmptyLibrary(in: app)
    }

    /// Fitting is automatic, so the Scheduling menu must not offer it — there is
    /// no decision here for the learner to get wrong or forget to make.
    func checkLibraryUITestsSchedulingMenuOffersOnlySettings() throws {
        let app = launchApp()
        app.menuBarItems["Scheduling"].click()
        let settings = app.menuItems.identified("Scheduling Settings…")
        XCTAssertTrue(settings.waitUntilExists(timeout: 3))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(app.menuItems.identified("Optimize Scheduling…").exists)
        XCTAssertFalse(app.menuItems.identified("Optimizing Scheduling…").exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    /// Ending a session with enough history to refit must tune the profile
    /// without saying so: the learner asked to study, not to be reported to.
    func checkLibraryUITestsEndingASessionOptimizesWithoutInterrupting() throws {
        let app = launchApp(scenario: "scheduling-history")
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        endStudyViaMenu(in: app)

        XCTAssertTrue(app.sheets.firstMatch.waitUntilGone(timeout: 5))
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "Scheduling Optimized")
            ).firstMatch.exists
        )
        waitForLibraryReady(in: app)
    }
}
