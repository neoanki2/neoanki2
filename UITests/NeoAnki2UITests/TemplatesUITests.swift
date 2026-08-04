import XCTest

extension FastFunctionalJourneyTests {
    func runSharedTemplatesAndItemTypesJourney() throws {
        let app = launchApp()

        runJourneyActivity("TemplatesAdvancedUITests.testTemplatesKeyboardShortcut") {
            app.typeKey("t", modifierFlags: [.command, .shift])
            XCTAssertTrue(app.buttons.identified("templatesDone").waitUntilExists(timeout: 5))
            waitForTemplatesReady(in: app)
        }

        runJourneyActivity("TemplatesUITests.testTemplatesOpensAndShowsBasicTemplate") {
            XCTAssertTrue(app.descendants(matching: .any)["templatesItemTypesHeader"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].exists)
            XCTAssertTrue(app.buttons.identified("templateRow-Card").exists)
        }

        runJourneyActivity("TemplatesUITests.testTemplatesLayoutDoesNotOverlapColumns") {
            let basicRow = app.descendants(matching: .any).identified("itemTypeRow-Basic")
            let cardTemplate = app.buttons.identified("templateRow-Card")
            let detailTitle = app.staticTexts.identified("templatesDetailTitle-Basic")
            XCTAssertLessThan(basicRow.frame.maxX, cardTemplate.frame.minX)
            if detailTitle.exists {
                XCTAssertLessThan(basicRow.frame.maxX, detailTitle.frame.minX)
            }
        }

        openNewTemplateEditor(in: app)
        let advanced = app.descendants(matching: .any).identified("templateAdvancedSettings")
        runJourneyActivity("TemplatesUITests.testNewTemplateKeepsAdvancedSettingsCollapsedByDefault") {
            XCTAssertTrue(advanced.waitUntilExists(timeout: 3))
            XCTAssertEqual(advanced.value as? String, "Collapsed")
        }

        runJourneyActivity("TemplatesAdvancedUITests.testTemplateAdvancedSettingsExpand") {
            let automaticSkill = app.descendants(matching: .any)["templateAutomaticSkill"]
            XCTAssertFalse(automaticSkill.exists)
            advanced.click()
            XCTAssertTrue(automaticSkill.waitUntilExists(timeout: 3))
            XCTAssertEqual(advanced.value as? String, "Expanded")
        }

        runJourneyActivity("TemplatesUITests.testTemplateValidationAndDiscardConfirmation") {
            let save = app.buttons.identified("saveTemplate")
            XCTAssertFalse(save.isEnabled)
            enterText(
                "Unsaved Template",
                into: app.textFields.identified("templateNameField"),
                app: app
            )
            app.buttons.identified("cancelTemplateEditor").click()
            XCTAssertTrue(app.buttons.identified("cancelDiscardTemplate").waitUntilExists(timeout: 3))
            app.buttons.identified("cancelDiscardTemplate").click()
            XCTAssertTrue(app.textFields.identified("templateNameField").exists)
            app.buttons.identified("cancelTemplateEditor").click()
            app.buttons.identified("confirmDiscardTemplate").click()
            XCTAssertFalse(app.buttons.identified("templateRow-Unsaved Template").exists)
        }

        runJourneyActivity("TemplatesUITests.testTemplatesCancelTemplateEditor") {
            openNewTemplateEditor(in: app)
            enterText(
                "Cancelled",
                into: app.textFields.identified("templateNameField"),
                app: app
            )
            app.buttons.identified("cancelTemplateEditor").click()
            if app.buttons.identified("confirmDiscardTemplate").waitUntilExists(timeout: 2) {
                app.buttons.identified("confirmDiscardTemplate").click()
            }
            XCTAssertFalse(app.buttons.identified("templateRow-Cancelled").exists)
        }

        runJourneyActivity("TemplatesAdvancedUITests.testTemplateInteractionPickerAllTypes") {
            openNewTemplateEditor(in: app)
            let picker = app.popUpButtons.identified("templateInteractionPicker")
            XCTAssertTrue(picker.waitUntilHittable(timeout: 2))
            picker.click()
            for interaction in ["Reveal", "Cloze", "Type answer", "Choose", "Arrange", "Record"] {
                XCTAssertTrue(
                    picker.menuItems[interaction].waitUntilExists(timeout: 2),
                    "Missing interaction option \(interaction)"
                )
            }
            picker.menuItems["Record"].click()
            XCTAssertTrue(waitUntil(timeout: 2) {
                (picker.value as? String)?.contains("Record") == true
            })
            app.buttons.identified("cancelTemplateEditor").click()
            if app.buttons.identified("confirmDiscardTemplate").waitUntilExists(timeout: 2) {
                app.buttons.identified("confirmDiscardTemplate").click()
            }
        }

        runJourneyActivity("TemplatesUITests.testTemplatesAddReverseTemplate") {
            openNewTemplateEditor(in: app)
            enterText("Reverse", into: app.textFields.identified("templateNameField"), app: app)
            selectPopUpOption(
                named: "Back",
                picker: app.popUpButtons.identified("templatePromptField"),
                in: app
            )
            selectPopUpOption(
                named: "Front",
                picker: app.popUpButtons.identified("templateAnswerField"),
                in: app
            )
            saveTemplateEditor(in: app)
            XCTAssertTrue(app.buttons.identified("templateRow-Reverse").waitUntilExists(timeout: 5))
        }

        runJourneyActivity("TemplatesUITests.testTemplatesEditTemplateName") {
            openTemplateEditor(named: "Reverse", in: app)
            enterText(
                "Renamed",
                into: app.textFields.identified("templateNameField"),
                app: app
            )
            saveTemplateEditor(in: app)
            XCTAssertTrue(app.buttons.identified("templateRow-Renamed").waitUntilExists(timeout: 5))
        }

        runJourneyActivity("TemplatesUITests.testDeleteTemplateCanBeCancelled") {
            cancelDeletingTemplate(named: "Card", in: app)
        }

        runJourneyActivity("TemplatesAdvancedUITests.testDeleteTemplateCancel") {
            XCTAssertTrue(app.buttons.identified("templateRow-Card").exists)
        }

        runJourneyActivity("TemplatesUITests.testTemplatesDeleteTemplate") {
            openTemplateEditor(named: "Renamed", in: app)
            app.buttons.identified("deleteTemplate").click()
            let confirm = app.buttons.identified("confirmDeleteTemplate")
            XCTAssertTrue(confirm.waitUntilExists(timeout: 3))
            confirm.click()
            XCTAssertTrue(app.buttons.identified("templateRow-Renamed").waitUntilGone(timeout: 3))
        }

        clickAddItemType(in: app)
        runJourneyActivity("TemplatesUITests.testItemTypeValidationDisablesSaveForBlankName") {
            XCTAssertFalse(app.buttons.identified("saveItemType").isEnabled)
        }

        runJourneyActivity("TemplatesUITests.testDirtyItemTypeCanKeepEditingThenDiscard") {
            enterText(
                "Unsaved Type",
                into: app.textFields.identified("itemTypeNameField"),
                app: app
            )
            app.buttons.identified("cancelItemTypeEditor").click()
            XCTAssertTrue(app.buttons.identified("cancelDiscardItemType").waitUntilExists(timeout: 3))
            app.buttons.identified("cancelDiscardItemType").click()
            XCTAssertTrue(app.textFields.identified("itemTypeNameField").exists)
            app.buttons.identified("cancelItemTypeEditor").click()
            app.buttons.identified("confirmDiscardItemType").click()
            XCTAssertFalse(app.descendants(matching: .any)["itemTypeRow-Unsaved Type"].exists)
        }

        clickAddItemType(in: app)
        enterText("Structured", into: app.textFields.identified("itemTypeNameField"), app: app)
        app.buttons.identified("addItemTypeField").click()

        runJourneyActivity("TemplatesAdvancedUITests.testFieldTypePicker") {
            let typePicker = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'itemTypeFieldType-'")
            ).firstMatch
            XCTAssertTrue(typePicker.waitUntilExists(timeout: 3))
            selectPopUpOption(named: "Rich Text", picker: typePicker, in: app)
        }

        runJourneyActivity("TemplatesUITests.testItemTypeFieldsCanBeAddedReorderedAndRemoved") {
            let moveUp = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "moveFieldUp-")
            )
            XCTAssertEqual(moveUp.count, 3)
            moveUp.element(boundBy: 2).click()

            let remove = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "removeItemTypeField-")
            )
            XCTAssertEqual(remove.count, 3)
            activateCompactButton(remove.element(boundBy: 2))
            XCTAssertEqual(
                app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "moveFieldUp-")
                ).count,
                2
            )
        }

        runJourneyActivity("TemplatesUITests.testTemplatesCreateItemType") {
            enterText(
                "Capitals",
                into: app.textFields.identified("itemTypeNameField"),
                app: app
            )
            saveItemType(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Capitals"].waitUntilExists(timeout: 5))
        }

        runJourneyActivity("TemplatesUITests.testTemplatesEditItemType") {
            app.buttons.identified("editItemType").click()
            enterText(
                "Renamed Type",
                into: app.textFields.identified("itemTypeNameField"),
                app: app
            )
            saveItemType(in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)["itemTypeRow-Renamed Type"]
                    .waitUntilExists(timeout: 5)
            )
        }

        runJourneyActivity("TemplatesUITests.testTemplatesDeleteBasicStarter") {
            let basic = app.descendants(matching: .any)["itemTypeRow-Basic"]
            basic.click()
            let delete = app.buttons.identified("deleteItemType")
            if !delete.waitUntilHittable(timeout: 2) {
                basic.click()
            }
            XCTAssertTrue(delete.waitUntilHittable(timeout: 3))
            delete.click()
            app.buttons.identified("confirmDeleteItemType").click()
            XCTAssertTrue(
                app.descendants(matching: .any)["itemTypeRow-Basic"].waitUntilGone(timeout: 3)
            )
        }

        runJourneyActivity("TemplatesUITests.testTemplatesDeleteCustomItemType") {
            let renamed = app.descendants(matching: .any)["itemTypeRow-Renamed Type"]
            XCTAssertTrue(renamed.waitUntilHittable(timeout: 3))
            renamed.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["templatesDetailTitle-Renamed Type"]
                    .waitUntilExists(timeout: 3)
            )
            let delete = app.buttons.identified("deleteItemType")
            XCTAssertTrue(delete.waitUntilHittable(timeout: 3))
            delete.click()
            app.buttons.identified("confirmDeleteItemType").click()
            XCTAssertTrue(
                app.descendants(matching: .any)["itemTypeRow-Renamed Type"]
                    .waitUntilGone(timeout: 3)
            )
        }
        closeTemplates(in: app)

        let corruptedApp = launchApp(scenario: "corrupted-item-type")
        runJourneyActivity("TemplatesAdvancedUITests.testRepairCorruptedItemType") {
            openTemplates(in: corruptedApp)
            let repair = corruptedApp.buttons.identified("repairItemType-Damaged")
            XCTAssertTrue(repair.waitUntilExists(timeout: 5))
            repair.click()
            corruptedApp.buttons.identified("confirmRepairItemType").click()
            XCTAssertTrue(
                corruptedApp.descendants(matching: .any)["itemTypeRow-Damaged"]
                    .waitUntilExists(timeout: 5)
            )
            closeTemplates(in: corruptedApp)
        }

        let protectedApp = launchApp(scenario: "deck-with-due-items")
        runJourneyActivity("TemplatesAdvancedUITests.testCannotDeleteItemTypeWithItems") {
            openTemplates(in: protectedApp)
            protectedApp.descendants(matching: .any).identified("itemTypeRow-Basic").click()
            let deleteButton = protectedApp.buttons.identified("deleteItemType")
            if deleteButton.exists {
                XCTAssertFalse(deleteButton.isEnabled)
            }
            closeTemplates(in: protectedApp)
        }
    }

    private func cancelDeletingTemplate(named name: String, in app: XCUIApplication) {
        openTemplateEditor(named: name, in: app)
        app.buttons.identified("deleteTemplate").click()
        let cancel = app.buttons.identified("cancelDeleteTemplate")
        XCTAssertTrue(cancel.waitUntilExists(timeout: 3))
        cancel.click()
        XCTAssertTrue(app.textFields.identified("templateNameField").exists)
        app.buttons.identified("cancelTemplateEditor").click()
    }

    private func openNewTemplateEditor(in app: XCUIApplication) {
        let editor = app.textFields.identified("templateNameField")
        let add = app.buttons.identified("addTemplateToolbar")
        for _ in 0..<3 where !editor.exists {
            XCTAssertTrue(add.waitUntilHittable(timeout: 1))
            add.click()
            if editor.waitUntilExists(timeout: 0.75) { return }
        }
        XCTAssertTrue(editor.exists, "New-template editor did not open")
    }

    func checkTemplatesUITestsTemplatesOpensAndShowsBasicTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["templatesItemTypesHeader"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons.identified("templateRow-Card").waitUntilExists(timeout: 5))

        closeTemplates(in: app)
        assertEmptyLibrary(in: app)
    }

    func checkTemplatesUITestsTemplatesLayoutDoesNotOverlapColumns() throws {
        let app = launchApp()
        openTemplates(in: app)

        let basicRow = app.descendants(matching: .any).identified("itemTypeRow-Basic")
        let cardTemplate = app.buttons.identified("templateRow-Card")
        let detailTitle = app.staticTexts.identified("templatesDetailTitle-Basic")

        XCTAssertTrue(basicRow.waitUntilExists(timeout: 5))
        XCTAssertTrue(cardTemplate.waitUntilExists(timeout: 5))
        XCTAssertLessThan(basicRow.frame.maxX, cardTemplate.frame.minX)

        if detailTitle.waitUntilExists(timeout: 2) {
            XCTAssertLessThan(basicRow.frame.maxX, detailTitle.frame.minX)
        }

        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesAddReverseTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitUntilExists(timeout: 5))

        if app.buttons.identified("addTemplateToolbar").waitUntilExists(timeout: 2) {
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
        saveTemplateEditor(in: app)

        XCTAssertTrue(app.buttons.identified("templateRow-Reverse").waitUntilExists(timeout: 5))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsNewTemplateKeepsAdvancedSettingsCollapsedByDefault() throws {
        let app = launchApp()
        openTemplates(in: app)
        app.buttons.identified("addTemplateToolbar").click()

        XCTAssertTrue(app.popUpButtons.identified("templatePromptField").waitUntilExists(timeout: 5))

        let advanced = app.descendants(matching: .any).identified("templateAdvancedSettings")
        XCTAssertTrue(advanced.waitUntilExists(timeout: 5))
        XCTAssertEqual(advanced.value as? String, "Collapsed")
    }

    func checkTemplatesUITestsTemplatesCreateItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Capitals")

        saveItemType(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Capitals"].waitUntilExists(timeout: 5))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesEditItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Editable")
        saveItemType(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Editable"].waitUntilExists(timeout: 5))

        app.buttons.identified("editItemType").click()
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeKey("a", modifierFlags: [.command])
        app.textFields.identified("itemTypeNameField").typeText("Renamed Type")
        saveItemType(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Renamed Type"].waitUntilExists(timeout: 5))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesDeleteBasicStarter() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.descendants(matching: .any)["itemTypeRow-Basic"].click()
        app.buttons.identified("deleteItemType").click()
        app.buttons.identified("confirmDeleteItemType").click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].waitUntilGone(timeout: 2))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesDeleteCustomItemType() throws {
        let app = launchApp()
        openTemplates(in: app)

        clickAddItemType(in: app)
        app.textFields.identified("itemTypeNameField").click()
        app.textFields.identified("itemTypeNameField").typeText("Disposable")
        saveItemType(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Disposable"].waitUntilExists(timeout: 5))

        app.buttons.identified("deleteItemType").click()
        app.buttons.identified("confirmDeleteItemType").click()

        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Disposable"].waitUntilGone(timeout: 2))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesEditTemplateName() throws {
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
        saveTemplateEditor(in: app)
        XCTAssertTrue(app.buttons.identified("templateRow-Original").waitUntilExists(timeout: 5))

        openTemplateEditor(named: "Original", in: app)
        let editNameField = app.textFields.identified("templateNameField")
        editNameField.click()
        editNameField.typeKey("a", modifierFlags: [.command])
        editNameField.typeText("Renamed")
        saveTemplateEditor(in: app)

        XCTAssertTrue(app.buttons.identified("templateRow-Renamed").waitUntilExists(timeout: 5))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesDeleteTemplate() throws {
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
        saveTemplateEditor(in: app)
        XCTAssertTrue(app.buttons.identified("templateRow-To Delete").waitUntilExists(timeout: 5))

        openTemplateEditor(named: "To Delete", in: app)
        app.buttons.identified("deleteTemplate").click()
        // Deleting asks first, and leaving the confirmation up keeps the editor
        // open — which later reads as the panel refusing to close.
        let confirm = app.buttons.identified("confirmDeleteTemplate")
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5))
        confirm.click()

        XCTAssertTrue(app.buttons.identified("templateRow-To Delete").waitUntilGone(timeout: 5))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsTemplatesCancelTemplateEditor() throws {
        let app = launchApp()
        openTemplates(in: app)

        app.buttons.identified("addTemplateToolbar").click()
        let nameField = app.textFields.identified("templateNameField")
        XCTAssertTrue(nameField.waitUntilExists(timeout: 5))
        nameField.click()
        nameField.typeText("Cancelled")
        app.buttons.identified("cancelTemplateEditor").click()
        // Cancelling an edited template asks before discarding, and an
        // unanswered confirmation keeps the editor — and the panel — open.
        let discard = app.buttons.identified("confirmDiscardTemplate")
        if discard.waitUntilExists(timeout: 3) {
            discard.click()
        }

        XCTAssertTrue(app.buttons.identified("templateRow-Cancelled").waitUntilGone(timeout: 5))
        closeTemplates(in: app)
    }

    func checkTemplatesUITestsItemTypeValidationDisablesSaveForBlankName() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)

        XCTAssertFalse(app.buttons.identified("saveItemType").isEnabled)
    }

    func checkTemplatesUITestsDirtyItemTypeCanKeepEditingThenDiscard() throws {
        let app = launchApp()
        openTemplates(in: app)
        clickAddItemType(in: app)
        enterText("Unsaved Type", into: app.textFields.identified("itemTypeNameField"), app: app)

        app.buttons.identified("cancelItemTypeEditor").click()
        XCTAssertTrue(app.buttons.identified("cancelDiscardItemType").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelDiscardItemType").click()
        XCTAssertTrue(app.textFields.identified("itemTypeNameField").exists)

        app.buttons.identified("cancelItemTypeEditor").click()
        app.buttons.identified("confirmDiscardItemType").click()
        XCTAssertFalse(app.descendants(matching: .any)["itemTypeRow-Unsaved Type"].exists)
    }

    func checkTemplatesUITestsItemTypeFieldsCanBeAddedReorderedAndRemoved() throws {
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
        activateCompactButton(remove.element(boundBy: 2))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "moveFieldUp-")
            ).count,
            2
        )
    }

    func checkTemplatesUITestsTemplateValidationAndDiscardConfirmation() throws {
        let app = launchApp()
        openTemplates(in: app)
        app.buttons.identified("addTemplateToolbar").click()

        XCTAssertFalse(app.buttons.identified("saveTemplate").isEnabled)
        enterText("Unsaved Template", into: app.textFields.identified("templateNameField"), app: app)
        app.buttons.identified("cancelTemplateEditor").click()
        XCTAssertTrue(app.buttons.identified("cancelDiscardTemplate").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelDiscardTemplate").click()
        XCTAssertTrue(app.textFields.identified("templateNameField").exists)

        app.buttons.identified("cancelTemplateEditor").click()
        app.buttons.identified("confirmDiscardTemplate").click()
        XCTAssertFalse(app.buttons.identified("templateRow-Unsaved Template").exists)
    }

    func checkTemplatesUITestsDeleteTemplateCanBeCancelled() throws {
        let app = launchApp()
        openTemplates(in: app)
        openTemplateEditor(named: "Card", in: app)

        app.buttons.identified("deleteTemplate").click()
        XCTAssertTrue(app.buttons.identified("cancelDeleteTemplate").waitUntilExists(timeout: 3))
        app.buttons.identified("cancelDeleteTemplate").click()

        XCTAssertTrue(app.textFields.identified("templateNameField").exists)
    }
}
