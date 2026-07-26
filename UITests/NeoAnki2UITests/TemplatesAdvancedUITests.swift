import XCTest

final class TemplatesAdvancedUITests: NeoAnkiUITestCase {
    func testTemplateInteractionPickerAllTypes() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Interactions")
        app.buttons.identified("saveItemType").click()

        let interactions = ["Reveal", "Cloze", "Type", "Choose", "Arrange", "Record"]
        for interaction in interactions {
            app.buttons.identified("addTemplateToolbar").click()
            app.textFields.identified("templateNameField").click()
            app.textFields.identified("templateNameField").typeText(interaction)

            let picker = app.popUpButtons.identified("templateInteractionPicker")
            if picker.waitForExistence(timeout: 3) {
                picker.click()
                if app.menuItems[interaction].waitForExistence(timeout: 2) {
                    app.menuItems[interaction].click()
                }
            }

            app.popUpButtons.identified("templatePromptField").click()
            app.menuItems["Field 1"].click()
            app.popUpButtons.identified("templateAnswerField").click()
            app.menuItems["Field 2"].click()
            app.buttons.identified("saveTemplate").click()
            XCTAssertTrue(app.buttons.identified("templateRow-\(interaction)").waitForExistence(timeout: 5))
        }
        closeTemplates(in: app)
    }

    func testTemplateAdvancedSettingsExpand() throws {
        let app = launchApp()
        openTemplates(in: app)
        app.buttons.identified("addTemplateToolbar").click()

        let advanced = app.descendants(matching: .any).identified("templateAdvancedSettings")
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()

        XCTAssertTrue(app.descendants(matching: .any)["templateAutomaticSkill"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["promptSlotAdd"].waitForExistence(timeout: 3))
        app.buttons.identified("cancelTemplateEditor").click()
        closeTemplates(in: app)
    }

    func testRepairCorruptedItemType() throws {
        let app = launchApp(scenario: "corrupted-item-type")
        openTemplates(in: app)

        let repair = app.buttons.identified("repairItemType-Damaged")
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        repair.click()
        app.buttons.identified("confirmRepairItemType").click()

        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Damaged"].waitForExistence(timeout: 10))
        closeTemplates(in: app)
    }

    func testFieldTypePicker() throws {
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

    func testDeleteTemplateCancel() throws {
        let app = launchApp()
        openTemplates(in: app)
        openTemplateEditor(named: "Card", in: app)
        app.buttons.identified("deleteTemplate").click()
        app.buttons.identified("cancelDeleteTemplate").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").waitForExistence(timeout: 3))
        app.buttons.identified("cancelTemplateEditor").click()
        closeTemplates(in: app)
    }

    func testCannotDeleteItemTypeWithItems() throws {
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

    func testTemplatesKeyboardShortcut() throws {
        let app = launchApp()
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons.identified("templatesDone").waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }
}
