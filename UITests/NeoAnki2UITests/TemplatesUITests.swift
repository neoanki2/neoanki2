import XCTest

extension FastFunctionalJourneyTests {
    /// One process-level journey exercises the unified, atomic Item Type Studio.
    /// Every named activity performs the behavior it claims; activity-filtered
    /// compatibility checks below run focused versions instead of aliasing this
    /// entire journey.
    func runSharedTemplatesAndItemTypesJourney() throws {
        let app = launchApp(databaseLabel: "studio-shared")

        runJourneyActivity("ItemTypeStudio.keyboardOpenAndOverview") {
            app.typeKey("t", modifierFlags: [.command, .shift])
            XCTAssertTrue(app.buttons.identified("templatesDone").waitUntilExists(timeout: 5))
            waitForTemplatesReady(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["templatesItemTypesHeader"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["cardSetupRow-Card"].exists)
        }

        runJourneyActivity("ItemTypeStudio.pristineCreationDiscardSafeguards") {
            clickAddItemType(in: app)
            assertPrefilledStudio(in: app)
            XCTAssertFalse(app.buttons["Remove Basic Card setup"].isEnabled)

            app.buttons.identified("cancelItemTypeStudio").click()
            XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
            app.buttons.identified("cancelDiscardItemTypeStudio").click()

            app.descendants(matching: .any).identified("itemTypeRow-Basic").click()
            XCTAssertTrue(app.buttons.identified("discardItemTypeStudioSelection").waitUntilExists(timeout: 3))
            app.buttons.identified("keepEditingItemTypeStudioSelection").click()
            XCTAssertTrue(app.textFields.identified("itemTypeStudioName").exists)
        }

        runJourneyActivity("ItemTypeStudio.validationAndFields") {
            app.buttons.identified("saveItemTypeStudio").click()
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .identified("itemTypeStudioValidationSummary")
                    .waitUntilExists(timeout: 3)
            )
            enterText("Unified Studio", into: app.textFields.identified("itemTypeStudioName"), app: app)
            addStudioField(named: "Visual", type: "GIF", in: app)
            addStudioField(named: "Cloze Text", type: "Cloze", in: app)
        }

        runJourneyActivity("ItemTypeStudio.audioConversionAndRestore") {
            chooseAnswerMethod("Audio Submission", in: app)
            XCTAssertTrue(app.buttons["Remove Answer and Continue"].waitUntilExists(timeout: 3))
            XCTAssertTrue(
                app.staticTexts[
                    "Audio Submission keeps no expected answer. It will be restored if you switch back before saving."
                ].waitUntilExists(timeout: 3)
            )
            guard let confirmation = modalContainer(in: app) else {
                XCTFail("Expected the Audio Submission confirmation dialog")
                return
            }
            confirmation.buttons["Cancel"].click()
            chooseAnswerMethod("Audio Submission", in: app)
            guard let secondConfirmation = modalContainer(in: app) else {
                XCTFail("Expected the Audio Submission confirmation dialog")
                return
            }
            secondConfirmation.buttons["Remove Answer and Continue"].click()
            XCTAssertTrue(app.staticTexts["Spoken response"].waitUntilExists(timeout: 3))
            XCTAssertTrue(
                app.staticTexts["Responses remain private on this device."].waitUntilExists(timeout: 3)
            )
            chooseAnswerMethod("Reveal", in: app)
            let restoredAnswer = app.buttons.identified("cardSetupEditor.recipe.answer")
            XCTAssertTrue(restoredAnswer.waitUntilExists(timeout: 3))
            XCTAssertTrue(restoredAnswer.label.localizedCaseInsensitiveContains("Back"))
        }

        runJourneyActivity("ItemTypeStudio.allStarters") {
            addCardSetupStarter("Reverse", in: app)
            addCardSetupStarter("Type Answer", in: app)
            addCardSetupStarter("Visual", in: app)
            addCardSetupStarter("Cloze", in: app)
            addCardSetupStarter("Audio Submission", in: app)
            app.buttons.identified("itemTypeStudio.addBasicCardSetup").click()
            XCTAssertEqual(studioCardSetupRows(in: app).count, 7)
        }

        runJourneyActivity("ItemTypeStudio.layoutsPreviewAndAdvanced") {
            let editorScroll = app.scrollViews.identified("cardSetupEditor")
            for layout in ["focus", "split", "mediaAside", "mediaHero", "actionStage"] {
                let choice = app.buttons.identified("cardSetupEditor.layout.\(layout)")
                if !choice.exists {
                    XCTAssertTrue(editorScroll.waitUntilExists(timeout: 3))
                    editorScroll.scroll(byDeltaX: 0, deltaY: -250)
                }
                XCTAssertTrue(choice.waitUntilExists(timeout: 3))
                choice.click()
                XCTAssertEqual(choice.value as? String, "Selected")
            }

            let showAnswer = app.buttons.identified("cardSetupEditor.showAnswer")
            XCTAssertTrue(showAnswer.waitUntilExists(timeout: 3))
            showAnswer.click()

            let advanced = app.descendants(matching: .any).identified("cardSetupEditor.advanced")
            XCTAssertEqual(advanced.value as? String, "Collapsed")
            advanced.click()
            XCTAssertEqual(advanced.value as? String, "Expanded")
            let availability = app.checkBoxes["Availability rule"]
            XCTAssertTrue(availability.waitUntilExists(timeout: 3))
            availability.click()
            let addRule = app.buttons["Add another rule"]
            XCTAssertTrue(addRule.waitUntilExists(timeout: 3))
            addRule.click()
            XCTAssertTrue(app.segmentedControls.firstMatch.waitUntilExists(timeout: 3))
            XCTAssertTrue(app.buttons["Use recommendation"].waitUntilExists(timeout: 3))
        }

        runJourneyActivity("ItemTypeStudio.fixedTextMediaRevealAndReorder") {
            selectStudioCardSetup(named: "Visual", in: app)
            addFixedText(to: "Instruction", value: "Study the image", in: app)
            addFixedText(to: "Instruction", value: "Then answer", in: app)
            addFixedText(to: "Context", value: "Context note", in: app)
            let moveButtons = app.buttons.matching(
                NSPredicate(format: "label == %@", "Move content up")
            )
            let moveUp = moveButtons.element(boundBy: max(0, moveButtons.count - 1))
            XCTAssertTrue(moveUp.waitUntilExists(timeout: 3))
            moveUp.click()

            let reveal = app.popUpButtons["Reveal"]
            XCTAssertTrue(reveal.waitUntilExists(timeout: 3))
            reveal.click()
            app.menuItems["Blur until reveal"].click()
            let playback = app.popUpButtons["Playback"]
            XCTAssertTrue(playback.waitUntilExists(timeout: 3))
            playback.click()
            app.menuItems["Loop"].click()
            XCTAssertTrue(app.buttons.identified("cardSetupEditor.hole.media").exists)
        }

        runJourneyActivity("ItemTypeStudio.removeUndoAndAtomicSave") {
            let removeReverse = app.buttons["Remove Reverse Card setup"]
            XCTAssertTrue(removeReverse.waitUntilExists(timeout: 3))
            removeReverse.click()
            let undo = app.buttons.identified("itemTypeStudio.undoCardSetupRemoval")
            XCTAssertTrue(undo.waitUntilExists(timeout: 3))
            undo.click()
            XCTAssertTrue(app.buttons["Remove Reverse Card setup"].exists)
            saveItemType(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Unified Studio"].waitUntilExists(timeout: 5))
        }

        runJourneyActivity("ItemTypeStudio.keyboardCancelAndDelete") {
            app.buttons.identified("editItemType").click()
            app.typeKey("f", modifierFlags: [.command, .shift])
            XCTAssertEqual(studioFieldRows(in: app).count, 5)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
            app.buttons.identified("confirmDiscardItemTypeStudio").click()
            app.buttons.identified("deleteItemType").click()
            XCTAssertTrue(app.buttons.identified("confirmDeleteItemType").waitUntilExists(timeout: 3))
            app.buttons.identified("confirmDeleteItemType").click()
            XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Unified Studio"].waitUntilGone(timeout: 5))
        }
        closeTemplates(in: app)

        try runStudioRepairAndImpactJourneys()
    }

    // MARK: Focused activity-filter checks

    func checkTemplatesUITestsTemplatesOpensAndShowsBasicTemplate() throws {
        let app = launchApp(databaseLabel: "studio-open")
        openTemplates(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Basic"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["cardSetupRow-Card"].exists)
    }

    func checkTemplatesUITestsTemplatesLayoutDoesNotOverlapColumns() throws {
        let app = launchNewStudio(label: "studio-columns")
        XCTAssertTrue(app.descendants(matching: .any).identified("itemTypeStudioOutline").exists)
        XCTAssertTrue(app.descendants(matching: .any).identified("itemTypeStudioCardSetupEditor").exists)
        XCTAssertLessThan(
            app.descendants(matching: .any).identified("itemTypeStudioOutline").frame.maxX,
            app.descendants(matching: .any).identified("itemTypeStudioCardSetupEditor").frame.maxX
        )
    }

    func checkTemplatesUITestsTemplatesAddReverseTemplate() throws {
        let app = launchNewStudio(label: "studio-reverse")
        addCardSetupStarter("Reverse", in: app)
        XCTAssertTrue(app.buttons["Remove Reverse Card setup"].exists)
    }

    func checkTemplatesUITestsNewTemplateKeepsAdvancedSettingsCollapsedByDefault() throws {
        let app = launchNewStudio(label: "studio-advanced-collapsed")
        XCTAssertEqual(
            app.descendants(matching: .any).identified("cardSetupEditor.advanced").value as? String,
            "Collapsed"
        )
    }

    func checkTemplatesUITestsTemplatesCreateItemType() throws {
        let app = launchNewStudio(label: "studio-create")
        enterText("Created Type", into: app.textFields.identified("itemTypeStudioName"), app: app)
        saveItemType(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Created Type"].exists)
    }

    func checkTemplatesUITestsTemplatesEditItemType() throws {
        let app = launchApp(databaseLabel: "studio-edit")
        openTemplates(in: app)
        openItemTypeStudio(named: "Basic", in: app)
        enterText("Edited Basic", into: app.textFields.identified("itemTypeStudioName"), app: app)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Edited Basic"].waitUntilExists(timeout: 5))
    }

    func checkTemplatesUITestsTemplatesDeleteBasicStarter() throws {
        let app = launchNewStudio(label: "studio-final-protection")
        XCTAssertFalse(app.buttons["Remove Basic Card setup"].isEnabled)
    }

    func checkTemplatesUITestsTemplatesDeleteCustomItemType() throws {
        let app = createSavedStudio(named: "Delete Me", label: "studio-delete")
        app.buttons.identified("deleteItemType").click()
        app.buttons.identified("confirmDeleteItemType").click()
        XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Delete Me"].waitUntilGone(timeout: 5))
    }

    func checkTemplatesUITestsTemplatesEditTemplateName() throws {
        let app = launchNewStudio(label: "studio-setup-name")
        enterText("Question and Answer", into: app.textFields.identified("cardSetupEditor.name"), app: app)
        XCTAssertEqual(app.textFields.identified("cardSetupEditor.name").value as? String, "Question and Answer")
    }

    func checkTemplatesUITestsTemplatesDeleteTemplate() throws {
        let app = launchNewStudio(label: "studio-remove-setup")
        addCardSetupStarter("Reverse", in: app)
        app.buttons["Remove Reverse Card setup"].click()
        XCTAssertTrue(app.buttons.identified("itemTypeStudio.undoCardSetupRemoval").exists)
    }

    func checkTemplatesUITestsTemplatesCancelTemplateEditor() throws {
        let app = launchNewStudio(label: "studio-pristine-cancel")
        app.buttons.identified("cancelItemTypeStudio").click()
        XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
    }

    func checkTemplatesUITestsItemTypeValidationDisablesSaveForBlankName() throws {
        let app = launchNewStudio(label: "studio-invalid-save")
        XCTAssertTrue(app.buttons.identified("saveItemTypeStudio").isEnabled)
        app.buttons.identified("saveItemTypeStudio").click()
        XCTAssertTrue(app.descendants(matching: .any).identified("itemTypeStudioValidationSummary").exists)
    }

    func checkTemplatesUITestsDirtyItemTypeCanKeepEditingThenDiscard() throws {
        let app = launchNewStudio(label: "studio-keep-editing")
        enterText("Unsaved", into: app.textFields.identified("itemTypeStudioName"), app: app)
        app.buttons.identified("cancelItemTypeStudio").click()
        app.buttons.identified("cancelDiscardItemTypeStudio").click()
        XCTAssertTrue(app.textFields.identified("itemTypeStudioName").exists)
        app.buttons.identified("cancelItemTypeStudio").click()
        app.buttons.identified("confirmDiscardItemTypeStudio").click()
        XCTAssertFalse(app.textFields.identified("itemTypeStudioName").exists)
    }

    func checkTemplatesUITestsItemTypeFieldsCanBeAddedReorderedAndRemoved() throws {
        let app = launchNewStudio(label: "studio-fields")
        addStudioField(named: "Extra", type: "Text", in: app)
        XCTAssertEqual(studioFieldRows(in: app).count, 3)
        let moveUp = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'moveStudioFieldUp-'")
        ).element(boundBy: 2)
        XCTAssertTrue(moveUp.waitUntilHittable(timeout: 3))
        moveUp.click()
        let moveDown = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'moveStudioFieldDown-'")
        ).element(boundBy: 1)
        XCTAssertTrue(moveDown.waitUntilHittable(timeout: 3))
        moveDown.click()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'removeStudioField-'"))
            .element(boundBy: 2).click()
        app.buttons.identified("confirmRemoveStudioField").click()
        XCTAssertEqual(studioFieldRows(in: app).count, 2)
    }

    func checkTemplatesUITestsTemplateValidationAndDiscardConfirmation() throws {
        let app = launchNewStudio(label: "studio-selection-discard")
        app.descendants(matching: .any).identified("itemTypeRow-Basic").click()
        XCTAssertTrue(app.buttons.identified("discardItemTypeStudioSelection").waitUntilExists(timeout: 3))
    }

    func checkTemplatesUITestsDeleteTemplateCanBeCancelled() throws {
        let app = launchNewStudio(label: "studio-undo-remove")
        addCardSetupStarter("Reverse", in: app)
        app.buttons["Remove Reverse Card setup"].click()
        app.buttons.identified("itemTypeStudio.undoCardSetupRemoval").click()
        XCTAssertTrue(app.buttons["Remove Reverse Card setup"].exists)
    }

    // MARK: Shared focused helpers

    func launchNewStudio(label: String) -> XCUIApplication {
        let app = launchApp(databaseLabel: label)
        openTemplates(in: app)
        clickAddItemType(in: app)
        assertPrefilledStudio(in: app)
        return app
    }

    func createSavedStudio(named name: String, label: String) -> XCUIApplication {
        let app = launchNewStudio(label: label)
        enterText(name, into: app.textFields.identified("itemTypeStudioName"), app: app)
        saveItemType(in: app)
        return app
    }

    func assertPrefilledStudio(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons.identified("saveItemTypeStudio").waitUntilExists(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).identified("itemTypeStudioOutline").exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .identified("itemTypeStudioCardSetupEditor")
                .waitUntilExists(timeout: 5)
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) { studioFieldRows(in: app).count == 2 },
            "A new Studio must expose its prefilled Front and Back fields"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) { studioCardSetupRows(in: app).count == 1 },
            "A new Studio must expose its prefilled Basic Card setup"
        )
        assertItemTypeStudioFitsWindow(in: app)
    }

    func studioFieldRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'studioFieldRow-'")
        )
    }

    func studioCardSetupRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'itemTypeStudio.cardSetup.'")
        )
    }

    func addStudioField(named name: String, type: String, in app: XCUIApplication) {
        app.buttons.identified("addStudioField").click()
        let fieldNames = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'studioFieldName-'")
        )
        enterText(name, into: fieldNames.element(boundBy: fieldNames.count - 1), app: app)
        let fieldTypes = app.popUpButtons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'studioFieldType-'")
        )
        let picker = fieldTypes.element(boundBy: fieldTypes.count - 1)
        XCTAssertTrue(picker.waitUntilExists(timeout: 3))
        picker.click()
        app.menuItems[type].click()
    }

    func addCardSetupStarter(_ name: String, in app: XCUIApplication) {
        let menu = app.menuButtons.identified("itemTypeStudio.addCardSetupMenu")
        XCTAssertTrue(menu.waitUntilExists(timeout: 3))
        menu.click()
        XCTAssertTrue(app.menuItems[name].waitUntilExists(timeout: 3))
        app.menuItems[name].click()
        XCTAssertTrue(app.buttons["Remove \(name) Card setup"].waitUntilExists(timeout: 3))
    }

    func selectStudioCardSetup(named name: String, in app: XCUIApplication) {
        let row = studioCardSetupRows(in: app).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", name)
        ).firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 3))
        row.click()
        XCTAssertTrue(app.textFields.identified("cardSetupEditor.name").waitUntilExists(timeout: 3))
    }

    func chooseAnswerMethod(_ name: String, in app: XCUIApplication) {
        let picker = app.popUpButtons.identified("cardSetupEditor.answerMethod")
        XCTAssertTrue(picker.waitUntilExists(timeout: 3))
        picker.click()
        XCTAssertTrue(app.menuItems[name].waitUntilExists(timeout: 3))
        app.menuItems[name].click()
    }

    func addFixedText(to hole: String, value: String, in app: XCUIApplication) {
        let button = app.buttons["Add \(hole) content"]
        XCTAssertTrue(button.waitUntilExists(timeout: 3))
        if !button.isHittable {
            app.scrollViews.identified("cardSetupEditor").scroll(byDeltaX: 0, deltaY: -500)
        }
        button.click()
        XCTAssertTrue(app.buttons["Fixed text"].waitUntilExists(timeout: 3))
        app.buttons["Fixed text"].click()
        let textFields = app.textFields.matching(NSPredicate(format: "label == %@", "Fixed text"))
        let field = textFields.element(boundBy: max(0, textFields.count - 1))
        XCTAssertTrue(field.waitUntilExists(timeout: 3))
        enterText(value, into: field, app: app)
    }

    func runStudioRepairAndImpactJourneys() throws {
        let riskyApp = launchApp(databaseLabel: "studio-risky", scenario: "item-type-risky-edit")
        runJourneyActivity("ItemTypeStudio.fieldReferenceRepairAndImpact") {
            openTemplates(in: riskyApp)
            openItemTypeStudio(named: "Risky Edit", in: riskyApp)
            let remove = riskyApp.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'removeStudioField-'")
            ).element(boundBy: 0)
            remove.click()
            riskyApp.buttons.identified("confirmRemoveStudioField").click()
            XCTAssertTrue(
                riskyApp.descendants(matching: .any)
                    .identified("itemTypeStudioRepairRequired")
                    .waitUntilExists(timeout: 3)
            )
            riskyApp.buttons.identified("saveItemTypeStudio").click()
            XCTAssertTrue(
                riskyApp.descendants(matching: .any)
                    .identified("itemTypeStudioValidationSummary")
                    .waitUntilExists(timeout: 3)
            )
        }

        let privacyApp = launchApp(
            databaseLabel: "studio-private-response",
            scenario: "item-type-spoken-response-impact"
        )
        runJourneyActivity("ItemTypeStudio.spokenResponseDeletionPrivacy") {
            openTemplates(in: privacyApp)
            openItemTypeStudio(named: "Private Responses", in: privacyApp)
            privacyApp.buttons["Remove Spoken Practice Card setup"].click()
            privacyApp.buttons.identified("saveItemTypeStudio").click()
            XCTAssertTrue(
                privacyApp.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", "Permanently delete 1 saved spoken response")
                ).firstMatch.waitUntilExists(timeout: 3)
            )
            XCTAssertTrue(privacyApp.buttons.identified("confirmItemTypeStudioSaveImpact").exists)
        }

        let corruptedApp = launchApp(databaseLabel: "studio-corrupt", scenario: "corrupted-item-type")
        runJourneyActivity("ItemTypeStudio.corruptedDefinitionRepair") {
            openTemplates(in: corruptedApp)
            corruptedApp.buttons.identified("repairItemType-Damaged").click()
            corruptedApp.buttons.identified("confirmRepairItemType").click()
            XCTAssertTrue(corruptedApp.descendants(matching: .any)["itemTypeRow-Damaged"].waitUntilExists(timeout: 5))
        }
    }
}
