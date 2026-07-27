import XCTest

final class AuthoringUITests: NeoAnkiUITestCase {
    func testAddItemWithNumberField() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Numeric")

        saveItemType(in: app)
        closeTemplates(in: app)

        openAddItem(in: app)
        let picker = app.popUpButtons.identified("addItemTypePicker")
        if picker.waitForExistence(timeout: 3) {
            selectPopUpOption(named: "Numeric", picker: picker, in: app)
        }
        enterText("Count", into: field(named: "Front", in: app), app: app)
        enterText("42", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)
        waitForItem(named: "Count", in: app)
    }

    func testAddItemWithMultipleItemTypes() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Secondary")
        saveItemType(in: app)
        closeTemplates(in: app)

        openAddItem(in: app)
        selectPopUpOption(
            named: "Secondary",
            picker: app.popUpButtons.identified("addItemTypePicker"),
            in: app
        )
        app.buttons.identified("cancelAddItem").click()
    }

    func testClozeAuthoringMarkBlank() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Cloze Author")

        let typePickers = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'itemTypeFieldType-'")
        )
        if typePickers.firstMatch.waitForExistence(timeout: 3) {
            typePickers.firstMatch.click()
            if app.menuItems["Cloze"].waitForExistence(timeout: 2) {
                selectMenuItem("Cloze", in: app)
            }
        }
        saveItemType(in: app)
        closeTemplates(in: app)

        openAddItem(in: app)
        if app.popUpButtons.identified("addItemTypePicker").exists {
            selectPopUpOption(
                named: "Cloze Author",
                picker: app.popUpButtons.identified("addItemTypePicker"),
                in: app
            )
        }

        let clozeField = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH 'field-'")
        ).firstMatch
        if clozeField.waitForExistence(timeout: 5) {
            clozeField.click()
            clozeField.typeText("The capital of France is Paris.")
            clozeField.typeKey("a", modifierFlags: [.command])
        }

        let markBlank = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'markBlank'")
        ).firstMatch
        if markBlank.waitForExistence(timeout: 3) {
            markBlank.click()
        }
        app.buttons.identified("cancelAddItem").click()
    }

    func testMediaFieldRequiresDescription() throws {
        let app = launchApp(scenario: "image-missing-description")
        waitForItem(named: "Image", in: app)
        openItemDetail(named: "Image", in: app)
        app.buttons.identified("editItem").click()

        let save = app.buttons.identified("saveEditItem")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        app.buttons.identified("cancelEditItem").click()
        returnToLibrary(in: app)
    }

    func testEmptyDeckAddItem() throws {
        let app = launchApp()
        createDeck(named: "Empty Deck", in: app)
        selectScope("deckRow-Empty Deck", in: app)
        XCTAssertTrue(app.buttons.identified("addItemEmptyState").waitForExistence(timeout: 5))
        app.buttons.identified("addItemEmptyState").click()
        XCTAssertTrue(field(named: "Front", in: app).waitForExistence(timeout: 10))
        app.buttons.identified("cancelAddItem").click()
    }

    func testUnassignedScopeEmptyState() throws {
        let app = launchApp()
        selectScope("scopeRow-Unassigned", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["emptyUnassignedState"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.buttons.identified("addItemEmptyState").waitForExistence(timeout: 2))
    }

    func testItemPreviewRendersRichText() throws {
        let app = launchApp()
        openAddItem(in: app)
        assertFormattedField(named: "Front", buttonID: "formatBold", style: "bold", text: "PreviewBold", in: app)
        enterText("Preview Back", into: field(named: "Back", in: app), app: app)
        saveAddItem(in: app)

        openItemDetail(named: "PreviewBold", in: app)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "PreviewBold", "PreviewBold")
            ).firstMatch.waitForExistence(timeout: 5)
        )
        returnToLibrary(in: app)
    }

    func testEditItemChangeItemType() throws {
        throw XCTSkip("Changing item type after creation is not supported in the current UI.")
    }
}
