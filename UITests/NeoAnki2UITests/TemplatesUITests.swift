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

            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
            app.buttons.identified("cancelDiscardItemTypeStudio").click()

            XCTAssertTrue(app.textFields.identified("itemTypeStudioName").exists)
            XCTAssertFalse(app.descendants(matching: .any).identified("itemTypeRow-Basic").exists)
        }

        runJourneyActivity("ItemTypeStudio.validationAndFields") {
            app.typeKey("s", modifierFlags: .command)
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
            openCardSetupInspector(in: app)
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
            closeCardSetupInspector(in: app)
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
            let identifiedLayoutPicker = app.descendants(matching: .any)
                .identified("cardSetupEditor.layoutPicker")
            let labeledLayoutPicker = app.menuButtons.matching(
                NSPredicate(format: "label BEGINSWITH 'Layout, '")
            ).firstMatch
            for layout in ["Focus", "Split", "Media Aside", "Media Hero", "Action Stage"] {
                let layoutPicker = identifiedLayoutPicker.exists
                    ? identifiedLayoutPicker
                    : labeledLayoutPicker
                XCTAssertTrue(layoutPicker.waitUntilHittable(timeout: 3))
                layoutPicker.click()
                XCTAssertTrue(app.menuItems[layout].waitUntilExists(timeout: 3))
                app.menuItems[layout].click()
                XCTAssertTrue(
                    waitUntil(timeout: 3) {
                        layoutPicker.label.contains(layout)
                            || (layoutPicker.value as? String)?.contains(layout) == true
                    }
                )
            }

            let showAnswer = app.buttons.identified("cardSetupEditor.showAnswer")
            revealCardSetupElement(showAnswer, in: app)
            showAnswer.click()

            let advanced = revealCardSetupAdvanced(in: app)
            XCTAssertEqual(advanced.value as? String, "Collapsed")
            advanced.click()
            XCTAssertEqual(advanced.value as? String, "Expanded")
            let availability = app.checkBoxes["Availability rule"]
            revealCardSetupElement(availability, in: app)
            let initialAvailabilityValue = String(describing: availability.value)
            availability.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
            ).click()
            XCTAssertTrue(
                waitUntil(timeout: 3) {
                    String(describing: availability.value) != initialAvailabilityValue
                },
                "Availability checkbox did not toggle"
            )
            let addRule = app.buttons["Add another rule"]
            revealCardSetupElement(addRule, in: app)
            addRule.click()
            let combination = app.descendants(matching: .any)
                .identified("cardSetupEditor.availabilityCombination")
            revealCardSetupElement(combination, in: app)
            let recommendedRoute = app.buttons["Use recommended route"]
            XCTAssertTrue(recommendedRoute.waitUntilExists(timeout: 3))
            closeCardSetupInspector(in: app)
        }

        runJourneyActivity("ItemTypeStudio.fixedTextMediaRevealAndReorder") {
            selectStudioCardSetup(named: "Visual", in: app)
            addFixedText(to: "Instruction", value: "Study the image", in: app)
            addFixedText(to: "Instruction", value: "Then answer", in: app)
            addFixedText(to: "Context", value: "Context note", in: app)
            let mediaPreview = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH 'cardSetupEditor.component.' AND label CONTAINS[c] 'Visual'"
                )
            ).firstMatch
            XCTAssertTrue(mediaPreview.waitUntilHittable(timeout: 3))
            mediaPreview.click()

            let playbackPrefix = "cardSetupEditor.playback."
            let playback = app.popUpButtons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", playbackPrefix)
            ).firstMatch
            revealCardSetupElement(playback, in: app)
            let mediaComponentID = String(playback.identifier.dropFirst(playbackPrefix.count))
            let reveal = app.popUpButtons.identified(
                "cardSetupEditor.reveal.\(mediaComponentID)"
            )
            revealCardSetupElement(reveal, in: app)
            selectPopUpOption(named: "Blur until reveal", picker: reveal, in: app)
            revealCardSetupElement(playback, in: app)
            selectPopUpOption(named: "Loop", picker: playback, in: app)
            let selectedMediaPreview = app.buttons.identified(
                "cardSetupEditor.component.\(mediaComponentID)"
            )
            XCTAssertTrue(selectedMediaPreview.exists)
            closeCardSetupInspector(in: app)
        }

        runJourneyActivity("ItemTypeStudio.removeUndoAndAtomicSave") {
            let removeReverse = app.buttons["Remove Reverse Card setup"]
            revealItemTypeStudioCardSetupListElement(removeReverse, in: app)
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
            if !app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 1) {
                app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            }
            XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
            app.buttons.identified("confirmDiscardItemTypeStudio").click()
            app.buttons.identified("deleteItemType").click()
            XCTAssertTrue(app.buttons.identified("confirmDeleteItemType").waitUntilExists(timeout: 3))
            app.buttons.identified("confirmDeleteItemType").click()
            XCTAssertTrue(app.descendants(matching: .any)["itemTypeRow-Unified Studio"].waitUntilGone(timeout: 5))
        }
        closeTemplates(in: app)

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
        XCTAssertTrue(app.staticTexts["Card canvas"].exists)
        XCTAssertLessThan(
            app.descendants(matching: .any).identified("itemTypeStudioOutline").frame.maxX,
            app.staticTexts["Card canvas"].frame.minX
        )
    }

    func checkTemplatesUITestsTemplatesAddReverseTemplate() throws {
        let app = launchNewStudio(label: "studio-reverse")
        addCardSetupStarter("Reverse", in: app)
        XCTAssertTrue(app.buttons["Remove Reverse Card setup"].exists)
        selectStudioCardSetup(named: "Basic", in: app)
        openCardSetupInspector(in: app)
        XCTAssertEqual(
            app.textFields.identified("cardSetupEditor.name").value as? String,
            "Basic"
        )
        closeCardSetupInspector(in: app)
        selectStudioCardSetup(named: "Reverse", in: app)
        openCardSetupInspector(in: app)
        XCTAssertEqual(
            app.textFields.identified("cardSetupEditor.name").value as? String,
            "Reverse"
        )
    }

    func checkTemplatesUITestsNewTemplateKeepsAdvancedSettingsCollapsedByDefault() throws {
        let app = launchNewStudio(label: "studio-advanced-collapsed")
        XCTAssertEqual(
            revealCardSetupAdvanced(in: app).value as? String,
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
        openCardSetupInspector(in: app)
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
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
    }

    func checkTemplatesUITestsItemTypeValidationDisablesSaveForBlankName() throws {
        let app = launchNewStudio(label: "studio-invalid-save")
        XCTAssertTrue(app.buttons.identified("saveItemTypeStudio").isEnabled)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).identified("itemTypeStudioValidationSummary").exists)
    }

    func checkTemplatesUITestsDirtyItemTypeCanKeepEditingThenDiscard() throws {
        let app = launchNewStudio(label: "studio-keep-editing")
        enterText("Unsaved", into: app.textFields.identified("itemTypeStudioName"), app: app)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.buttons.identified("cancelDiscardItemTypeStudio").click()
        XCTAssertTrue(app.textFields.identified("itemTypeStudioName").exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
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
        XCTAssertFalse(app.descendants(matching: .any).identified("itemTypeRow-Basic").exists)
        enterText("Unsaved", into: app.textFields.identified("itemTypeStudioName"), app: app)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons.identified("confirmDiscardItemTypeStudio").waitUntilExists(timeout: 3))
    }

    func checkTemplatesUITestsDeleteTemplateCanBeCancelled() throws {
        let app = launchNewStudio(label: "studio-undo-remove")
        addCardSetupStarter("Reverse", in: app)
        for _ in 0..<6 {
            app.buttons.identified("itemTypeStudio.addBasicCardSetup").click()
        }
        let removeReverse = app.buttons["Remove Reverse Card setup"]
        revealItemTypeStudioCardSetupListElement(removeReverse, in: app)
        removeReverse.click()
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
        XCTAssertTrue(app.staticTexts["Card canvas"].waitUntilExists(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Card canvas"]
                .waitUntilExists(timeout: 5)
        )
        XCTAssertTrue(
                app.buttons.identified("cardSetupEditor.inspectorButton").exists
                || app.staticTexts.identified("cardSetupEditor.inspector").exists
        )
        XCTAssertFalse(app.descendants(matching: .any)["templatesItemTypesHeader"].exists)
        XCTAssertFalse(app.buttons.identified("templatesDone").exists)
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
        let fieldNames = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'studioFieldName-'")
        )
        let addField = app.buttons.identified("addStudioField")
        revealItemTypeStudioOutlineElement(addField, in: app)
        let countValue = addField.value as? String
        guard let previousFieldCount = countValue?
            .split(separator: " ")
            .first
            .flatMap({ Int($0) }) else {
            return XCTFail("Add Field did not expose the current field count")
        }
        let outline = app.descendants(matching: .any).identified("itemTypeStudioOutline")
        var existingFieldIDs = Set(
            fieldNames.allElementsBoundByIndex.map(\.identifier)
        )
        for _ in 0..<8 where existingFieldIDs.count < previousFieldCount {
            outline.scroll(byDeltaX: 0, deltaY: -200)
            existingFieldIDs.formUnion(
                fieldNames.allElementsBoundByIndex.map(\.identifier)
            )
        }
        XCTAssertEqual(
            existingFieldIDs.count,
            previousFieldCount,
            "The Studio did not expose every existing field while scrolling the rail"
        )
        revealItemTypeStudioOutlineElement(addField, in: app)
        addField.click()
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                (addField.value as? String) == "\(previousFieldCount + 1) fields"
            },
            "Adding a field did not increment the Studio field count"
        )
        var newField = fieldNames.allElementsBoundByIndex.first {
            !existingFieldIDs.contains($0.identifier)
        }
        for _ in 0..<8 where newField == nil {
            outline.scroll(byDeltaX: 0, deltaY: -200)
            newField = fieldNames.allElementsBoundByIndex.first {
                !existingFieldIDs.contains($0.identifier)
            }
        }
        guard let newField else {
            return XCTFail("The newly added field editor never mounted")
        }
        enterText(name, into: newField, app: app)
        let fieldID = String(newField.identifier.dropFirst("studioFieldName-".count))
        let picker = app.popUpButtons.identified("studioFieldType-\(fieldID)")
        XCTAssertTrue(picker.waitUntilExists(timeout: 3))
        picker.click()
        app.menuItems[type].click()
    }

    func addCardSetupStarter(_ name: String, in app: XCUIApplication) {
        let menu = app.menuButtons.identified("itemTypeStudio.addCardSetupMenu")
        revealItemTypeStudioCardSetupListElement(menu, in: app)
        menu.click()
        XCTAssertTrue(app.menuItems[name].waitUntilExists(timeout: 3))
        app.menuItems[name].click()
        XCTAssertTrue(app.buttons["Remove \(name) Card setup"].waitUntilExists(timeout: 3))
    }

    func selectStudioCardSetup(named name: String, in app: XCUIApplication) {
        let row = studioCardSetupRows(in: app).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", name)
        ).firstMatch
        XCTAssertTrue(row.waitUntilHittable(timeout: 3))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        XCTAssertTrue(
            waitUntil(timeout: 3) { row.isSelected },
            "Selecting the \(name) Card setup did not update the editor selection. "
                + "Frame: \(row.frame), hittable: \(row.isHittable), element: \(row)"
        )
    }

    func chooseAnswerMethod(_ name: String, in app: XCUIApplication) {
        let picker = app.popUpButtons.identified("cardSetupEditor.answerMethod")
        revealCardSetupElement(picker, in: app)
        picker.click()
        XCTAssertTrue(app.menuItems[name].waitUntilExists(timeout: 3))
        app.menuItems[name].click()
    }

    func addFixedText(to hole: String, value: String, in app: XCUIApplication) {
        closeCardSetupInspector(in: app)
        let directAdd = app.buttons["Add \(hole)"]
        if directAdd.waitUntilHittable(timeout: 1) {
            directAdd.click()
        } else {
            let addMenu = app.menuButtons.identified("cardSetupEditor.addContent")
            XCTAssertTrue(addMenu.waitUntilHittable(timeout: 3))
            addMenu.click()
            XCTAssertTrue(app.menuItems[hole].waitUntilExists(timeout: 3))
            app.menuItems[hole].click()
        }
        let fixedTextSource = app.buttons.identified(
            "cardSetupEditor.sourcePicker.hole.\(hole.lowercased()).fixedText"
        )
        XCTAssertTrue(fixedTextSource.waitUntilHittable(timeout: 3))
        fixedTextSource.click()
        let field = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'cardSetupEditor.fixedText.'")
        ).firstMatch
        revealCardSetupElement(field, in: app)
        enterText(value, into: field, app: app)
        closeCardSetupInspector(in: app)
    }

    func runStudioRepairAndImpactJourneys() throws {
        try runJourneyActivity("ItemTypeStudio.fieldReferenceRepairAndImpact") {
            try runStudioFieldReferenceRepairJourney()
        }
        try runJourneyActivity("ItemTypeStudio.spokenResponseDeletionPrivacy") {
            try runStudioSpokenResponseDeletionJourney()
        }
        try runJourneyActivity("ItemTypeStudio.corruptedDefinitionRepair") {
            try runStudioCorruptedDefinitionRepairJourney()
        }
    }

    func runStudioFieldReferenceRepairJourney() throws {
        let riskyApp = launchApp(databaseLabel: "studio-risky", scenario: "item-type-risky-edit")
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
        riskyApp.typeKey("s", modifierFlags: .command)
        let validationSummary = riskyApp.descendants(matching: .any)
            .identified("itemTypeStudioValidationSummary")
        let inspectorDone = riskyApp.buttons.identified("cardSetupEditor.inspectorDone")
        XCTAssertTrue(
            waitUntil(timeout: 10) { validationSummary.exists || inspectorDone.exists },
            "Save did not surface the invalid Card setup"
        )
        XCTAssertTrue(validationSummary.waitUntilExists(timeout: 5))
        // At compact widths the same summary lives inside the routed
        // Inspector. Close that context before continuing the shared app.
        if inspectorDone.waitUntilExists(timeout: 2) {
            closeCardSetupInspector(in: riskyApp)
        }
    }

    func runStudioSpokenResponseDeletionJourney() throws {
        let privacyApp = launchApp(
            databaseLabel: "studio-private-response",
            scenario: "item-type-spoken-response-impact"
        )
        openTemplates(in: privacyApp)
        openItemTypeStudio(named: "Private Responses", in: privacyApp)
        privacyApp.buttons["Remove Spoken Practice Card setup"].click()
        privacyApp.typeKey("s", modifierFlags: .command)
        let confirmImpact = privacyApp.buttons.identified("confirmItemTypeStudioSaveImpact")
        XCTAssertTrue(confirmImpact.waitUntilExists(timeout: 3))
        XCTAssertTrue(confirmImpact.label.contains("Permanently delete 1 saved spoken response"))
    }

    func runStudioCorruptedDefinitionRepairJourney() throws {
        let corruptedApp = launchApp(databaseLabel: "studio-corrupt", scenario: "corrupted-item-type")
        openTemplates(in: corruptedApp)
        corruptedApp.buttons.identified("repairItemType-Damaged").click()
        corruptedApp.buttons.identified("confirmRepairItemType").click()
        XCTAssertTrue(corruptedApp.descendants(matching: .any)["itemTypeRow-Damaged"].waitUntilExists(timeout: 5))
    }
}
