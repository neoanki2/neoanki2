import XCTest

extension FastFunctionalJourneyTests {
    func checkTemplatesAdvancedUITestsTemplateInteractionPickerAllTypes() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Interactions")
        app.buttons.identified("saveItemType").click()

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
        app.buttons.identified("deleteTemplate").click()
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
