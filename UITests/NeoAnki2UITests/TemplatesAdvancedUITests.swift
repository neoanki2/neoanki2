import XCTest

extension FastFunctionalJourneyTests {
    func checkTemplatesAdvancedUITestsTemplateInteractionPickerAllTypes() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Interactions")
        saveItemType(in: app)

        let interactions = ["Reveal", "Cloze", "Type answer", "Choose", "Arrange", "Record"]
        for interaction in interactions {
            app.buttons.identified("addTemplateToolbar").click()

            let picker = app.popUpButtons.identified("templateInteractionPicker")
            selectPopUpOption(named: interaction, picker: picker, in: app)
            XCTAssertTrue(waitUntil(timeout: 3) {
                (picker.value as? String)?.contains(interaction) == true
            })

            app.buttons.identified("cancelTemplateEditor").click()
            let discard = app.buttons.identified("confirmDiscardTemplate")
            if discard.waitUntilExists(timeout: 2) {
                discard.click()
            }
            XCTAssertTrue(picker.waitUntilGone(timeout: 5))
        }
        closeTemplates(in: app)
    }

    func checkTemplatesAdvancedUITestsTemplateAdvancedSettingsExpand() throws {
        let app = launchApp()
        openTemplates(in: app)
        app.buttons.identified("addTemplateToolbar").click()

        let advanced = app.descendants(matching: .any).identified("templateAdvancedSettings")
        let automaticSkill = app.descendants(matching: .any)["templateAutomaticSkill"]
        XCTAssertTrue(advanced.waitUntilExists(timeout: 5))
        XCTAssertFalse(automaticSkill.exists)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        advanced.click()

        XCTAssertTrue(automaticSkill.waitUntilExists(timeout: 3))
        XCTAssertEqual(advanced.value as? String, "Expanded")
        app.buttons.identified("cancelTemplateEditor").click()
        closeTemplates(in: app)
    }

    func checkTemplatesAdvancedUITestsRepairCorruptedItemType() throws {
        let app = launchApp(scenario: "corrupted-item-type")
        openTemplates(in: app)

        let repair = app.buttons.identified("repairItemType-Damaged")
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        repair.click()
        app.buttons.identified("confirmRepairItemType").click()

        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Damaged"].waitForExistence(timeout: 10))
        closeTemplates(in: app)
    }

    func checkTemplatesAdvancedUITestsFieldTypePicker() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Field Types")

        app.buttons.identified("addItemTypeField").click()
        let typePicker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'itemTypeFieldType-'")
        ).firstMatch
        XCTAssertTrue(typePicker.waitForExistence(timeout: 5))
        typePicker.click()
        XCTAssertTrue(app.menuItems["Rich Text"].waitForExistence(timeout: 3))
        app.menuItems["Rich Text"].click()

        app.buttons.identified("cancelItemTypeEditor").click()
        if app.buttons.identified("confirmDiscardItemType").waitForExistence(timeout: 2) {
            app.buttons.identified("confirmDiscardItemType").click()
        }
        closeTemplates(in: app)
    }

    func checkTemplatesAdvancedUITestsDeleteTemplateCancel() throws {
        let app = launchApp()
        openTemplates(in: app)
        openTemplateEditor(named: "Card", in: app)
        app.menuButtons.identified("templateMoreMenu").click()
        app.menuItems.identified("deleteTemplate").click()
        app.buttons.identified("cancelDeleteTemplate").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").waitForExistence(timeout: 3))
        app.buttons.identified("cancelTemplateEditor").click()
        closeTemplates(in: app)
    }

    func checkTemplatesAdvancedUITestsCannotDeleteItemTypeWithItems() throws {
        let app = launchApp()
        addBasicItem(front: "Block Delete", back: "Answer", in: app)
        openTemplates(in: app)

        app.descendants(matching: .any).identified("itemTypeRow-Basic").click()
        let deleteButton = app.buttons.identified("deleteItemType")
        if deleteButton.waitForExistence(timeout: 3) {
            XCTAssertFalse(deleteButton.isEnabled)
        }
        closeTemplates(in: app)
    }

    func checkTemplatesAdvancedUITestsTemplatesKeyboardShortcut() throws {
        let app = launchApp()
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons.identified("templatesDone").waitForExistence(timeout: 5))
        closeTemplates(in: app)
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

    func testIncludedDefinitionsAreGroupedReadOnlyAndDuplicateAsNormal() throws {
        let app = launchApp(scenario: "deck-included-item-types")
        openTemplates(in: app)
        let includedDeckGroup = app.buttons.identified("includedDeckGroup-Poetry Lab")
        XCTAssertTrue(includedDeckGroup.waitUntilExists(timeout: 5))
        includedDeckGroup.click()

        let included = app.descendants(matching: .any)
            .identified("includedItemTypeRow-Poem Line")
        XCTAssertTrue(included.waitUntilExists(timeout: 5))
        included.click()
        XCTAssertTrue(app.descendants(matching: .any).identified("includedItemTypeOwner").exists)
        XCTAssertFalse(app.buttons.identified("editItemType").exists)
        XCTAssertFalse(app.buttons.identified("deleteItemType").exists)
        XCTAssertFalse(app.buttons.identified("addTemplateToolbar").exists)

        app.buttons.identified("duplicateIncludedItemType").click()
        XCTAssertTrue(app.buttons.identified("confirmDuplicateItemType").waitUntilExists(timeout: 3))
        app.buttons.identified("confirmDuplicateItemType").click()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .identified("itemTypeRow-Poem Line Copy")
                .waitUntilExists(timeout: 5)
        )
        XCTAssertTrue(app.buttons.identified("editItemType").exists)
    }

    func testIncludedDefinitionCanBeUnlockedInPlace() throws {
        let app = launchApp(scenario: "deck-included-item-types")
        openTemplates(in: app)
        let includedDeckGroup = app.buttons.identified("includedDeckGroup-Poetry Lab")
        XCTAssertTrue(includedDeckGroup.waitUntilExists(timeout: 5))
        includedDeckGroup.click()

        let included = app.descendants(matching: .any)
            .identified("includedItemTypeRow-Poem Line")
        XCTAssertTrue(included.waitUntilExists(timeout: 5))
        included.click()
        app.buttons.identified("unlockIncludedItemType").click()

        let confirm = app.buttons.identified("confirmUnlockIncludedItemType")
        XCTAssertTrue(confirm.waitUntilExists(timeout: 3))
        confirm.click()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .identified("itemTypeRow-Poem Line")
                .waitUntilExists(timeout: 5)
        )
        XCTAssertTrue(app.buttons.identified("editItemType").exists)
        XCTAssertFalse(app.descendants(matching: .any).identified("includedItemTypeOwner").exists)
    }

    func testPopulatedFieldRemovalRequiresExplicitConfirmation() throws {
        let app = launchApp(scenario: "item-type-risky-edit")
        openTemplates(in: app)
        app.descendants(matching: .any).identified("itemTypeRow-Risky Edit").click()
        app.buttons.identified("editItemType").click()

        let removeNotes = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'removeItemTypeField-'")
        ).element(boundBy: 2)
        XCTAssertTrue(removeNotes.waitUntilExists(timeout: 5))
        removeNotes.click()
        app.buttons.identified("saveItemType").click()

        let keepEditing = app.buttons.identified("cancelRiskyItemTypeChanges")
        XCTAssertTrue(keepEditing.waitUntilExists(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "1 existing item has stored content")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Removed: Notes.")
        ).firstMatch.exists)
        keepEditing.click()
        XCTAssertTrue(app.textFields.identified("itemTypeNameField").exists)

        app.buttons.identified("saveItemType").click()
        let confirm = app.buttons.identified("confirmRiskyItemTypeChanges")
        XCTAssertTrue(confirm.waitUntilExists(timeout: 3))
        confirm.click()
        XCTAssertTrue(app.buttons.identified("editItemType").waitUntilExists(timeout: 5))

        app.buttons.identified("editItemType").click()
        XCTAssertEqual(
            app.textFields.matching(
                NSPredicate(format: "identifier BEGINSWITH 'itemTypeField-'")
            ).count,
            2
        )
    }
}
