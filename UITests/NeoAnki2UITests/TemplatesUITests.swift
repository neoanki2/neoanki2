import XCTest

final class TemplatesUITests: NeoAnkiUITestCase {
    func testTemplatesOpensAndShowsBasicTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["templatesItemTypesHeader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["templateRow-Card"].waitForExistence(timeout: 5))

        closeTemplates(in: app)
        assertEmptyLibrary(in: app)
    }

    func testTemplatesLayoutDoesNotOverlapColumns() throws {
        let app = launchApp()
        openTemplates(in: app)

        let basicRow = app.descendants(matching: .any)["itemTypeRow-Basic"]
        let cardTemplate = app.buttons["templateRow-Card"]
        let detailTitle = app.staticTexts["templatesDetailTitle-Basic"]

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

        if app.buttons["addTemplateToolbar"].waitForExistence(timeout: 2) {
            app.buttons["addTemplateToolbar"].click()
        } else {
            app.buttons["Add Template"].click()
        }

        app.textFields["templateNameField"].click()
        app.textFields["templateNameField"].typeText("Reverse")

        app.popUpButtons["templatePromptField"].click()
        app.menuItems["Back"].click()
        app.popUpButtons["templateAnswerField"].click()
        app.menuItems["Front"].click()
        app.buttons["saveTemplate"].click()

        XCTAssertTrue(app.buttons["templateRow-Reverse"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesCreateItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields["itemTypeNameField"].click()
        app.textFields["itemTypeNameField"].typeText("Capitals")

        app.buttons["saveItemType"].click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Capitals"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesEditItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields["itemTypeNameField"].click()
        app.textFields["itemTypeNameField"].typeText("Editable")
        app.buttons["saveItemType"].click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Editable"].waitForExistence(timeout: 5))

        app.buttons["editItemType"].click()
        app.textFields["itemTypeNameField"].click()
        app.textFields["itemTypeNameField"].typeKey("a", modifierFlags: [.command])
        app.textFields["itemTypeNameField"].typeText("Renamed Type")
        app.buttons["saveItemType"].click()

        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Renamed Type"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesBlockDeletingBuiltInBasic() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.descendants(matching: .any)["itemTypeRow-Basic"].click()
        let deleteButton = app.buttons["deleteItemType"]
        XCTAssertFalse(deleteButton.exists)
        closeTemplates(in: app)
    }

    func testTemplatesDeleteCustomItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields["itemTypeNameField"].click()
        app.textFields["itemTypeNameField"].typeText("Disposable")
        app.buttons["saveItemType"].click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Disposable"].waitForExistence(timeout: 5))

        app.buttons["deleteItemType"].click()
        app.buttons["confirmDeleteItemType"].click()

        XCTAssertFalse(app.descendants(matching: .any)["itemTypeRow-Disposable"].waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }

    func testTemplatesEditTemplateName() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons["addTemplateToolbar"].click()
        let nameField = app.textFields["templateNameField"]
        nameField.click()
        nameField.typeText("Original")
        app.popUpButtons["templatePromptField"].click()
        app.menuItems["Front"].click()
        app.popUpButtons["templateAnswerField"].click()
        app.menuItems["Back"].click()
        app.buttons["saveTemplate"].click()
        XCTAssertTrue(app.buttons["saveTemplate"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["templateRow-Original"].waitForExistence(timeout: 5))

        openTemplateEditor(named: "Original", in: app)
        let editNameField = app.textFields["templateNameField"]
        editNameField.click()
        editNameField.typeKey("a", modifierFlags: [.command])
        editNameField.typeText("Renamed")
        app.buttons["saveTemplate"].click()

        XCTAssertTrue(app.buttons["templateRow-Renamed"].waitForExistence(timeout: 5))
        closeTemplates(in: app)
    }

    func testTemplatesDeleteTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons["addTemplateToolbar"].click()
        let nameField = app.textFields["templateNameField"]
        nameField.click()
        nameField.typeText("To Delete")
        app.popUpButtons["templatePromptField"].click()
        app.menuItems["Front"].click()
        app.popUpButtons["templateAnswerField"].click()
        app.menuItems["Back"].click()
        app.buttons["saveTemplate"].click()
        XCTAssertTrue(app.buttons["saveTemplate"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["templateRow-To Delete"].waitForExistence(timeout: 5))

        openTemplateEditor(named: "To Delete", in: app)
        app.buttons["deleteTemplate"].click()

        XCTAssertFalse(app.buttons["templateRow-To Delete"].waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }

    func testTemplatesCancelTemplateEditor() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons["addTemplateToolbar"].click()
        let nameField = app.textFields["templateNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Cancelled")
        app.buttons["cancelTemplateEditor"].click()

        XCTAssertFalse(app.buttons["templateRow-Cancelled"].waitForExistence(timeout: 2))
        closeTemplates(in: app)
    }
}
