import XCTest

final class TemplatesUITests: NeoAnkiUITestCase {
    func testTemplatesOpensAndShowsBasicTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["templatesItemTypesHeader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.identified("templateRow-Card").waitForExistence(timeout: 5))

        closeTemplates(in: app)
        assertEmptyLibrary(in: app)
    }

    func testTemplatesLayoutDoesNotOverlapColumns() throws {
        let app = launchApp()
        openTemplates(in: app)

        let basicRow = app.descendants(matching: .any).identified("itemTypeRow-Basic")
        let cardTemplate = app.buttons.identified("templateRow-Card")
        let detailTitle = app.staticTexts.identified("templatesDetailTitle-Basic")

        XCTAssertTrue(basicRow.waitForExistence(timeout: 5))
        XCTAssertTrue(cardTemplate.waitForExistence(timeout: 5))
        XCTAssertLessThan(basicRow.frame.maxX, cardTemplate.frame.minX)

        if detailTitle.waitForExistence(timeout: 2) {
            XCTAssertLessThan(basicRow.frame.maxX, detailTitle.frame.minX)
        }

        closeTemplates(in: app)
    }

    func testTemplatesAddReverseTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitForExistence(timeout: 5))

        if app.buttons.identified("addTemplateToolbar").waitForExistence(timeout: 2) {
            app.buttons.identified("addTemplateToolbar").click()
        } else {
            app.buttons.identified("Add Template").click()
        }

        app.textFields.identified("templateNameField").click()
        app.textFields.identified("templateNameField").typeText("Reverse")

        app.popUpButtons.identified("templatePromptField").click()
        app.menuItems.identified("Back").click()
        app.popUpButtons.identified("templateAnswerField").click()
        app.menuItems.identified("Front").click()
        app.buttons.identified("saveTemplate").click()

        XCTAssertTrue(app.buttons.identified("templateRow-Reverse").waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testNewTemplateKeepsAdvancedSettingsCollapsedByDefault() throws {
        let app = launchApp()
        openTemplates(in: app)
        app.buttons.identified("addTemplateToolbar").click()

        XCTAssertTrue(app.popUpButtons.identified("templatePromptField").waitForExistence(timeout: 5))

        let advanced = app.descendants(matching: .any).identified("templateAdvancedSettings")
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        XCTAssertEqual(advanced.value as? Int, 0)
    }

    func testTemplatesCreateItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Capitals")

        app.buttons.identified("saveItemType").click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Capitals"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesEditItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Editable")
        app.buttons.identified("saveItemType").click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Editable"].waitForExistence(timeout: 5))

        app.buttons.identified("editItemType").click()
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeKey("a", modifierFlags: [.command])
        app.textFields.identified("itemTypeNameField").typeText("Renamed Type")
        app.buttons.identified("saveItemType").click()

        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Renamed Type"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesDeleteBasicStarter() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.descendants(matching: .any)["itemTypeRow-Basic"].click()
        app.buttons.identified("deleteItemType").click()
        app.buttons.identified("confirmDeleteItemType").click()
        XCTAssertFalse(app.descendants(matching: .any)["itemTypeRow-Basic"].waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }

    func testTemplatesDeleteCustomItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Disposable")
        app.buttons.identified("saveItemType").click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Disposable"].waitForExistence(timeout: 5))

        app.buttons.identified("deleteItemType").click()
        app.buttons.identified("confirmDeleteItemType").click()

        XCTAssertFalse(app.descendants(matching: .any)["itemTypeRow-Disposable"].waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }

    func testTemplatesEditTemplateName() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons.identified("addTemplateToolbar").click()
        let nameField = app.textFields.identified("templateNameField")
        nameField.click()
        nameField.typeText("Original")
        app.popUpButtons.identified("templatePromptField").click()
        app.menuItems.identified("Front").click()
        app.popUpButtons.identified("templateAnswerField").click()
        app.menuItems.identified("Back").click()
        app.buttons.identified("saveTemplate").click()
        XCTAssertTrue(app.buttons.identified("saveTemplate").waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons.identified("templateRow-Original").waitForExistence(timeout: 5))

        openTemplateEditor(named: "Original", in: app)
        let editNameField = app.textFields.identified("templateNameField")
        editNameField.click()
        editNameField.typeKey("a", modifierFlags: [.command])
        editNameField.typeText("Renamed")
        app.buttons.identified("saveTemplate").click()

        XCTAssertTrue(app.buttons.identified("templateRow-Renamed").waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesDeleteTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons.identified("addTemplateToolbar").click()
        let nameField = app.textFields.identified("templateNameField")
        nameField.click()
        nameField.typeText("To Delete")
        app.popUpButtons.identified("templatePromptField").click()
        app.menuItems.identified("Front").click()
        app.popUpButtons.identified("templateAnswerField").click()
        app.menuItems.identified("Back").click()
        app.buttons.identified("saveTemplate").click()
        XCTAssertTrue(app.buttons.identified("saveTemplate").waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons.identified("templateRow-To Delete").waitForExistence(timeout: 5))

        openTemplateEditor(named: "To Delete", in: app)
        app.buttons.identified("deleteTemplate").click()

        XCTAssertFalse(app.buttons.identified("templateRow-To Delete").waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }

    func testTemplatesCancelTemplateEditor() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons.identified("addTemplateToolbar").click()
        let nameField = app.textFields.identified("templateNameField")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Cancelled")
        app.buttons.identified("cancelTemplateEditor").click()

        XCTAssertFalse(app.buttons.identified("templateRow-Cancelled").waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }

    func testItemTypeValidationDisablesSaveForBlankName() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)

        XCTAssertFalse(app.buttons.identified("saveItemType").isEnabled)
    }

    func testDirtyItemTypeCanKeepEditingThenDiscard() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        enterText("Unsaved Type", into: app.textFields.identified("itemTypeNameField"), app: app)

        app.buttons.identified("cancelItemTypeEditor").click()
        XCTAssertTrue(app.buttons.identified("cancelDiscardItemType").waitForExistence(timeout: 3))
        app.buttons.identified("cancelDiscardItemType").click()
        XCTAssertTrue(app.textFields.identified("itemTypeNameField").exists)

        app.buttons.identified("cancelItemTypeEditor").click()
        app.buttons.identified("confirmDiscardItemType").click()
        XCTAssertFalse(app.descendants(matching: .any)["itemTypeRow-Unsaved Type"].exists)
    }

    func testItemTypeFieldsCanBeAddedReorderedAndRemoved() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        enterText("Structured", into: app.textFields.identified("itemTypeNameField"), app: app)

        app.buttons.identified("addItemTypeField").click()
        let moveUp = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "moveFieldUp-")
        )
        XCTAssertEqual(moveUp.count, 3)
        moveUp.element(boundBy: 2).click()

        let remove = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "removeItemTypeField-")
        )
        XCTAssertEqual(remove.count, 3)
        remove.element(boundBy: 2).click()
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "moveFieldUp-")
            ).count,
            2
        )
    }

    func testTemplateValidationAndDiscardConfirmation() throws {
        let app = launchApp()
        openTemplates(in: app)
        app.buttons.identified("addTemplateToolbar").click()

        XCTAssertFalse(app.buttons.identified("saveTemplate").isEnabled)
        enterText("Unsaved Template", into: app.textFields.identified("templateNameField"), app: app)
        app.buttons.identified("cancelTemplateEditor").click()
        XCTAssertTrue(app.buttons.identified("cancelDiscardTemplate").waitForExistence(timeout: 3))
        app.buttons.identified("cancelDiscardTemplate").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").exists)

        app.buttons.identified("cancelTemplateEditor").click()
        app.buttons.identified("confirmDiscardTemplate").click()
        XCTAssertFalse(app.buttons.identified("templateRow-Unsaved Template").exists)
    }

    func testDeleteTemplateCanBeCancelled() throws {
        let app = launchApp()
        openTemplates(in: app)
        openTemplateEditor(named: "Card", in: app)

        app.buttons.identified("deleteTemplate").click()
        XCTAssertTrue(app.buttons.identified("cancelDeleteTemplate").waitForExistence(timeout: 3))
        app.buttons.identified("cancelDeleteTemplate").click()

        XCTAssertTrue(app.textFields.identified("templateNameField").exists)
    }
}
