import XCTest

extension FastFunctionalJourneyTests {
    /// Protected FastFunctional coverage for Item Type Studio boundaries that
    /// require isolated repositories. These run here, rather than as an
    /// additionally selected XCTest class, so each journey executes exactly once.
    func runProtectedItemTypeSafeguardJourneys() throws {
        let studyApp = launchApp(databaseLabel: "studio-created-type-study")
        runJourneyActivity("ItemTypeStudio.savedSetupGeneratesStudyCard") {
            let typeName = "Studio Study Type"
            let prompt = "Studio-created prompt"
            let answer = "Studio-created answer"

            openTemplates(in: studyApp)
            clickAddItemType(in: studyApp)
            assertPrefilledStudio(in: studyApp)
            enterText(
                typeName,
                into: studyApp.textFields.identified("itemTypeStudioName"),
                app: studyApp
            )
            saveItemType(in: studyApp)
            XCTAssertTrue(
                studyApp.descendants(matching: .any)["itemTypeRow-\(typeName)"]
                    .waitUntilExists(timeout: 5)
            )
            closeTemplates(in: studyApp)

            openAddItem(in: studyApp)
            let itemTypePicker = studyApp.popUpButtons.identified("addItemTypePicker")
            selectPopUpOption(named: typeName, picker: itemTypePicker, in: studyApp)
            XCTAssertTrue(
                (itemTypePicker.value as? String)?.contains(typeName) == true,
                "Item authoring did not retain the exact Studio-created item type"
            )
            enterText(prompt, into: field(named: "Front", in: studyApp), app: studyApp)
            enterText(answer, into: field(named: "Back", in: studyApp), app: studyApp)
            saveAddItem(in: studyApp)
            waitForItem(named: prompt, in: studyApp)

            startStudy(in: studyApp)
            XCTAssertTrue(
                studyApp.descendants(matching: .any)["studyPrompt"]
                    .waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(studyApp.staticTexts[prompt].waitUntilExists(timeout: 3))
            XCTAssertFalse(studyApp.staticTexts[answer].exists)

            triggerPrimaryStudyAction(in: studyApp)
            XCTAssertTrue(
                studyApp.descendants(matching: .any)["studyAnswer"]
                    .waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(studyApp.staticTexts[answer].waitUntilExists(timeout: 3))
        }

        let duplicateApp = launchApp(
            databaseLabel: "studio-included-duplicate",
            scenario: "deck-included-item-types"
        )
        runJourneyActivity("ItemTypeStudio.includedReadOnlyAndDuplicate") {
            openTemplates(in: duplicateApp)
            openIncludedItemType(named: "Poem Line", deck: "Poetry Lab", in: duplicateApp)
            XCTAssertTrue(
                duplicateApp.descendants(matching: .any)
                    .identified("includedItemTypeOwner")
                    .waitUntilExists(timeout: 3)
            )
            XCTAssertFalse(duplicateApp.buttons.identified("editItemType").exists)
            XCTAssertFalse(duplicateApp.buttons.identified("deleteItemType").exists)

            duplicateApp.buttons.identified("duplicateIncludedItemType").click()
            let confirm = duplicateApp.buttons.identified("confirmDuplicateItemType")
            XCTAssertTrue(confirm.waitUntilExists(timeout: 3))
            confirm.click()
            XCTAssertTrue(
                duplicateApp.descendants(matching: .any)
                    .identified("itemTypeRow-Poem Line Copy")
                    .waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(duplicateApp.buttons.identified("editItemType").exists)
        }

        let unlockApp = launchApp(
            databaseLabel: "studio-included-unlock",
            scenario: "deck-included-item-types"
        )
        runJourneyActivity("ItemTypeStudio.includedUnlockInPlace") {
            openTemplates(in: unlockApp)
            openIncludedItemType(named: "Poem Line", deck: "Poetry Lab", in: unlockApp)
            unlockApp.buttons.identified("unlockIncludedItemType").click()

            let confirm = unlockApp.buttons.identified("confirmUnlockIncludedItemType")
            XCTAssertTrue(confirm.waitUntilExists(timeout: 3))
            confirm.click()
            XCTAssertTrue(
                unlockApp.descendants(matching: .any)
                    .identified("itemTypeRow-Poem Line")
                    .waitUntilExists(timeout: 5)
            )
            XCTAssertTrue(unlockApp.buttons.identified("editItemType").exists)
            XCTAssertFalse(
                unlockApp.descendants(matching: .any)
                    .identified("includedItemTypeOwner")
                    .exists
            )
        }

        let impactApp = launchApp(
            databaseLabel: "studio-populated-field-impact",
            scenario: "item-type-risky-edit"
        )
        runJourneyActivity("ItemTypeStudio.populatedFieldRemovalImpact") {
            openTemplates(in: impactApp)
            openItemTypeStudio(named: "Risky Edit", in: impactApp)

            let removeNotes = impactApp.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'removeStudioField-'")
            ).element(boundBy: 2)
            XCTAssertTrue(removeNotes.waitUntilExists(timeout: 5))
            removeNotes.click()
            let confirmRemoval = impactApp.buttons.identified("confirmRemoveStudioField")
            XCTAssertTrue(confirmRemoval.waitUntilExists(timeout: 3))
            confirmRemoval.click()
            impactApp.buttons.identified("saveItemTypeStudio").click()

            let keepEditing = impactApp.buttons.identified("cancelItemTypeStudioSaveImpact")
            XCTAssertTrue(keepEditing.waitUntilExists(timeout: 3))
            let confirmImpact = impactApp.buttons.identified("confirmItemTypeStudioSaveImpact")
            XCTAssertTrue(confirmImpact.exists)
            XCTAssertTrue(confirmImpact.label.contains("Affect 1 populated item"))
            XCTAssertTrue(confirmImpact.label.contains("Remove Notes"))
            keepEditing.click()

            impactApp.buttons.identified("saveItemTypeStudio").click()
            XCTAssertTrue(confirmImpact.waitUntilExists(timeout: 3))
            confirmImpact.click()
            XCTAssertTrue(impactApp.buttons.identified("editItemType").waitUntilExists(timeout: 5))
            impactApp.buttons.identified("editItemType").click()
            XCTAssertEqual(
                impactApp.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH 'studioFieldRow-'")
                ).count,
                2
            )
        }
    }

    private func openIncludedItemType(
        named itemType: String,
        deck: String,
        in app: XCUIApplication
    ) {
        let group = app.buttons.identified("includedDeckGroup-\(deck)")
        XCTAssertTrue(group.waitUntilExists(timeout: 5))
        group.click()
        let row = app.descendants(matching: .any)
            .identified("includedItemTypeRow-\(itemType)")
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        row.click()
    }

    func checkTemplatesAdvancedUITestsTemplateInteractionPickerAllTypes() throws {
        let app = launchNewStudio(label: "studio-answer-methods")
        for method in ["Type Answer", "Choose", "Record", "Cloze", "Arrange", "Reveal"] {
            chooseAnswerMethod(method, in: app)
        }
        chooseAnswerMethod("Audio Submission", in: app)
        XCTAssertTrue(app.buttons["Remove Answer and Continue"].waitUntilExists(timeout: 3))
    }

    func checkTemplatesAdvancedUITestsTemplateAdvancedSettingsExpand() throws {
        let app = launchNewStudio(label: "studio-advanced")
        let advanced = revealCardSetupAdvanced(in: app)
        advanced.click()
        XCTAssertEqual(advanced.value as? String, "Expanded")
        revealCardSetupElement(app.checkBoxes["Availability rule"], in: app)
        revealCardSetupElement(app.buttons["Use recommended route"], in: app)
    }

    func checkTemplatesAdvancedUITestsRepairCorruptedItemType() throws {
        let app = launchApp(databaseLabel: "studio-repair", scenario: "corrupted-item-type")
        openTemplates(in: app)
        app.buttons.identified("repairItemType-Damaged").click()
        app.buttons.identified("confirmRepairItemType").click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Damaged"].waitUntilExists(timeout: 5))
    }

    func checkTemplatesAdvancedUITestsFieldTypePicker() throws {
        let app = launchNewStudio(label: "studio-field-type")
        addStudioField(named: "Picture", type: "Image", in: app)
        XCTAssertEqual(studioFieldRows(in: app).count, 3)
    }

    func checkTemplatesAdvancedUITestsDeleteTemplateCancel() throws {
        let app = launchNewStudio(label: "studio-setup-undo")
        addCardSetupStarter("Reverse", in: app)
        app.buttons["Remove Reverse Card setup"].click()
        app.buttons.identified("itemTypeStudio.undoCardSetupRemoval").click()
        XCTAssertTrue(app.buttons["Remove Reverse Card setup"].exists)
    }

    func checkTemplatesAdvancedUITestsCannotDeleteItemTypeWithItems() throws {
        let app = launchApp(databaseLabel: "studio-delete-protected", scenario: "deck-with-due-items")
        openTemplates(in: app)
        app.descendants(matching: .any).identified("itemTypeRow-Basic").click()
        app.buttons.identified("deleteItemType").click()
        XCTAssertTrue(app.descendants(matching: .any).identified("itemTypeStudioActionError").waitUntilExists(timeout: 5))
        XCTAssertFalse(app.buttons.identified("confirmDeleteItemType").exists)
    }

    func checkTemplatesAdvancedUITestsTemplatesKeyboardShortcut() throws {
        let app = launchApp(databaseLabel: "studio-keyboard-a11y")
        app.typeKey("t", modifierFlags: [.command, .shift])
        waitForTemplatesReady(in: app)
        clickAddItemType(in: app)
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertEqual(studioFieldRows(in: app).count, 3)
        try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription])
    }
}

final class DeckIncludedItemTypesUITests: NeoAnkiUITestCase {
    func testSpecializedDeckRecommendsItsTypeAndKeepsBasicReachable() throws {
        let app = launchApp(scenario: "deck-included-item-types")
        selectScope("deckRow-Poetry Lab", in: app)
        openAddItem(in: app, waitForDefaultField: false)

        XCTAssertTrue(field(named: "Previous Lines", in: app).waitUntilExists(timeout: 5))
        XCTAssertTrue(field(named: "Next Line", in: app).exists)
        let picker = app.popUpButtons.identified("addItemTypePicker")
        XCTAssertTrue(picker.exists)
        XCTAssertTrue((picker.value as? String)?.contains("Poem Line") == true)

        picker.click()
        XCTAssertTrue(app.menuItems["Basic"].waitUntilExists(timeout: 3))
        XCTAssertFalse(app.menuItems["Translation Entry"].exists)
        app.menuItems["Basic"].click()
        XCTAssertTrue(field(named: "Front", in: app).waitUntilExists(timeout: 3))
    }

    func testManualTypeChangeConfirmsBeforeClearingContent() throws {
        let app = launchApp(scenario: "deck-included-item-types")
        selectScope("deckRow-Poetry Lab", in: app)
        openAddItem(in: app, waitForDefaultField: false)
        enterText(
            "An entered line",
            into: field(named: "Previous Lines", in: app),
            app: app
        )

        let picker = app.popUpButtons.identified("addItemTypePicker")
        picker.click()
        app.menuItems["Basic"].click()

        XCTAssertTrue(app.buttons.identified("confirmChangeItemType").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelChangeItemType").click()
        XCTAssertTrue(field(named: "Previous Lines", in: app).exists)
    }

}
