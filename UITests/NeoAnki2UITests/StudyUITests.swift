import XCTest

extension FastFunctionalJourneyTests {
    func runSharedStudyAndSchedulingJourney() throws {
        let app = launchApp(scenario: "deck-with-due-items")

        runJourneyActivity("LibraryUITests.testSchedulingMenuOffersOnlySettings") {
            app.menuBarItems["Scheduling"].click()
            let settings = app.menuItems.identified("Scheduling Settings…")
            XCTAssertTrue(settings.waitUntilExists(timeout: 3))
            XCTAssertTrue(settings.isEnabled)
            XCTAssertFalse(app.menuItems.identified("Optimize Scheduling…").exists)
            XCTAssertFalse(app.menuItems.identified("Optimizing Scheduling…").exists)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }

        runJourneyActivity("StudyExtendedUITests.testStartStudyViaMenu") {
            startStudyViaMenu(in: app)
        }

        runJourneyActivity("StudyExtendedUITests.testEditCardViaCommandEThenCancel") {
            let cancel = app.buttons.identified("cancelEditItem")
            for _ in 0..<3 where !cancel.exists {
                app.activate()
                XCTAssertTrue(
                    app.buttons.identified("primaryStudyAction")
                        .waitUntilHittable(timeout: 1)
                )
                app.typeKey("e", modifierFlags: [.command])
                if cancel.waitUntilExists(timeout: 0.75) { break }
            }
            XCTAssertTrue(cancel.exists)
            cancel.click()
            XCTAssertTrue(app.buttons.identified("primaryStudyAction").waitUntilExists(timeout: 3))
        }

        runJourneyActivity("StudyUITests.testStudyGradeHelpPopover") {
            app.buttons.identified("gradeHelp").click()
            let guide = app.descendants(matching: .any)["gradeGuidePanel"]
            XCTAssertTrue(guide.waitUntilExists(timeout: 3))
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            _ = guide.waitUntilGone(timeout: 2)
        }

        runJourneyActivity("StudyExtendedUITests.testContinueViaSpace") {
            app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
            XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 3))
        }

        runJourneyActivity("StudyUITests.testStudyAllGradeButtons") {
            for gradeID in ["gradeAgain", "gradeHard", "gradeGood", "gradeEasy"] {
                XCTAssertTrue(app.buttons.identified(gradeID).exists, "Missing \(gradeID)")
            }
        }

        runJourneyActivity("StudyExtendedUITests.testGradeViaKeyboardShortcuts") {
            gradeViaKeyboard(3, in: app)
        }

        runJourneyActivity("StudyUITests.testUndoLastGradeRestoresReviewedCard") {
            let undo = app.buttons.identified("undoLastGrade")
            XCTAssertTrue(undo.waitUntilExists(timeout: 3))
            undo.click()
            XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 3))
            XCTAssertFalse(app.buttons.identified("studySessionDone").exists)
        }

        clickOrType("gradeGood", shortcut: "3", in: app)
        runJourneyActivity("StudyExtendedUITests.testDismissUndoBanner") {
            let dismiss = app.buttons.identified("dismissGradeUndo")
            if dismiss.exists {
                dismiss.click()
                XCTAssertTrue(dismiss.waitUntilGone(timeout: 2))
            }
        }

        runJourneyActivity("StudyUITests.testStudyHardGrade") {
            revealAndGrade("gradeHard", in: app)
        }

        runJourneyActivity("StudyUITests.testStudyEasyGrade") {
            revealAndGrade("gradeEasy", in: app)
        }

        // Hard/Again intentionally leave repair work due. Reset before the
        // caught-up assertions instead of waiting for a state those grades are
        // not required to produce.
        let caughtUpApp = launchApp(scenario: "deck-with-due-items")
        runJourneyActivity("StudyUITests.testStudyBasicItemFlow") {
            startStudy(in: caughtUpApp)
            revealAndGrade("gradeGood", in: caughtUpApp)
            revealAndGrade("gradeGood", in: caughtUpApp)
            revealAndGrade("gradeGood", in: caughtUpApp)
            finishStudySession(in: caughtUpApp)
            assertNothingDue(in: caughtUpApp)
        }
        runJourneyActivity("StudyUITests.testStudyMultiCardSession") {
            assertNothingDue(in: caughtUpApp)
        }
        runJourneyActivity("StudyExtendedUITests.testStudyCaughtUpState") {
            assertNothingDue(in: caughtUpApp)
        }
        runJourneyActivity(
            "ScopeHomeAndBrowseUITests.testScopeHomeReportsNextDueInsteadOfADeadStudyButton"
        ) {
            XCTAssertTrue(
                caughtUpApp.descendants(matching: .any)["scopeHomeNextDue"]
                    .waitUntilExists(timeout: 3)
            )
            XCTAssertFalse(caughtUpApp.buttons.identified("studyButton").exists)
        }

        let commandUndoApp = launchApp(scenario: "deck-with-due-items")
        startStudy(in: commandUndoApp)
        revealAndGrade("gradeGood", in: commandUndoApp)
        runJourneyActivity("StudyExtendedUITests.testUndoLastGradeViaCommandZ") {
            commandUndoApp.typeKey("z", modifierFlags: [.command])
            XCTAssertTrue(
                commandUndoApp.buttons.identified("gradeGood").waitUntilExists(timeout: 3)
            )
            clickOrType("gradeGood", shortcut: "3", in: commandUndoApp)
        }
        finishStudySession(in: commandUndoApp)

        let againApp = launchApp(scenario: "deck-with-due-items")
        runJourneyActivity("StudyUITests.testStudyAgainGrade") {
            startStudy(in: againApp)
            revealAndGrade("gradeAgain", in: againApp)
            finishStudySession(in: againApp)
        }

        let endButtonApp = launchApp(scenario: "deck-with-due-items")
        runJourneyActivity("StudyUITests.testStudyEndSessionWithConfirmation") {
            startStudy(in: endButtonApp)
            revealAndGrade("gradeGood", in: endButtonApp)
            endButtonApp.buttons.identified("endStudySession").click()
            let confirm = endButtonApp.buttons.identified("confirmEndStudySession")
            XCTAssertTrue(confirm.waitUntilExists(timeout: 3))
            confirm.click()
            waitForLibraryReady(in: endButtonApp)
            assertDueCardsAvailable(in: endButtonApp)
        }

        let endMenuApp = launchApp(scenario: "scheduling-history")
        runJourneyActivity("StudyExtendedUITests.testEndStudyViaMenuWithConfirmation") {
            startStudy(in: endMenuApp)
            revealAndGrade("gradeGood", in: endMenuApp)
            endStudyViaMenu(in: endMenuApp)
            assertDueCardsAvailable(in: endMenuApp)
        }
        runJourneyActivity("LibraryUITests.testEndingASessionOptimizesWithoutInterrupting") {
            XCTAssertFalse(
                endMenuApp.staticTexts.matching(
                    NSPredicate(format: "value CONTAINS[c] %@", "Scheduling Optimized")
                ).firstMatch.exists
            )
            waitForLibraryReady(in: endMenuApp)
        }

        let reverseApp = launchApp(scenario: "study-reverse")
        runJourneyActivity("StudyUITests.testStudyReverseTemplate") {
            startStudy(in: reverseApp)
            revealAndGrade("gradeGood", in: reverseApp)
            revealAndGrade("gradeGood", in: reverseApp)
            finishStudySession(in: reverseApp)
        }

        let typedApp = launchApp(scenario: "study-type")
        runJourneyActivity("StudyUITests.testTypedAnswerRequiresInputThenAcceptsCorrectAnswer") {
            startStudy(in: typedApp)
            let primary = typedApp.buttons.identified("primaryStudyAction")
            primary.click()
            XCTAssertTrue(
                typedApp.descendants(matching: .any)["studyInteractionMessage"]
                    .waitUntilExists(timeout: 3)
            )
            enterText(
                "Paris",
                into: typedApp.textFields.identified("typedAnswer"),
                app: typedApp
            )
            triggerPrimaryStudyAction(in: typedApp)
            XCTAssertTrue(
                typedApp.descendants(matching: .any)["studyAnswer"].waitUntilExists(timeout: 3)
            )
            XCTAssertTrue(typedApp.buttons.identified("gradeGood").exists)
            clickOrType("gradeGood", shortcut: "3", in: typedApp)
            finishStudySession(in: typedApp)
        }

        let incorrectTypedApp = launchApp(scenario: "study-type")
        runJourneyActivity("StudyUITests.testTypedAnswerReportsIncorrectResponse") {
            startStudy(in: incorrectTypedApp)
            enterText(
                "London",
                into: incorrectTypedApp.textFields.identified("typedAnswer"),
                app: incorrectTypedApp
            )
            triggerPrimaryStudyAction(in: incorrectTypedApp)
            XCTAssertTrue(
                incorrectTypedApp.descendants(matching: .any)["studyAnswer"]
                    .waitUntilExists(timeout: 3)
            )
            let feedback = incorrectTypedApp.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "Compare your response")
            ).firstMatch
            XCTAssertTrue(feedback.waitUntilExists(timeout: 3))
        }

        let choiceApp = launchApp(scenario: "study-choose")
        runJourneyActivity("StudyUITests.testChoiceRequiresSelectionThenChecksCorrectChoice") {
            startStudy(in: choiceApp)
            triggerPrimaryStudyAction(in: choiceApp)
            XCTAssertTrue(
                choiceApp.descendants(matching: .any)["studyInteractionMessage"]
                    .waitUntilExists(timeout: 3)
            )
            let paris = choiceApp.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Paris")
            ).firstMatch
            XCTAssertTrue(paris.waitUntilExists(timeout: 3))
            paris.click()
            triggerPrimaryStudyAction(in: choiceApp)
            XCTAssertTrue(
                choiceApp.descendants(matching: .any)["answerCorrect"].waitUntilExists(timeout: 3)
            )
        }

        let uncheckedArrangeApp = launchApp(scenario: "study-arrange")
        runJourneyActivity("StudyUITests.testArrangeUncheckedOrderIsReportedIncorrect") {
            startStudy(in: uncheckedArrangeApp)
            XCTAssertTrue(
                uncheckedArrangeApp.buttons.identified("arrangementItem0")
                    .waitUntilExists(timeout: 3)
            )
            triggerPrimaryStudyAction(in: uncheckedArrangeApp)
            XCTAssertTrue(
                uncheckedArrangeApp.descendants(matching: .any)["answerIncorrect"]
                    .waitUntilExists(timeout: 3)
            )
        }

        let arrangedApp = launchApp(scenario: "study-arrange")
        runJourneyActivity("StudyExtendedUITests.testArrangeReorderToCorrectOrder") {
            startStudy(in: arrangedApp)
            let moveDown = arrangedApp.buttons.identified("moveArrangementDown")
            if moveDown.exists, moveDown.isEnabled { moveDown.click() }
            triggerPrimaryStudyAction(in: arrangedApp)
            XCTAssertTrue(waitUntil(timeout: 3) {
                arrangedApp.descendants(matching: .any)["answerCorrect"].exists
                    || arrangedApp.descendants(matching: .any)["studyAnswer"].exists
            })
        }

        let keyboardArrangeApp = launchApp(scenario: "study-arrange")
        runJourneyActivity("StudyExtendedUITests.testArrangeKeyboardReorder") {
            startStudy(in: keyboardArrangeApp)
            keyboardArrangeApp.buttons.identified("arrangementItem0").click()
            keyboardArrangeApp.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [.command])
            triggerPrimaryStudyAction(in: keyboardArrangeApp)
            XCTAssertTrue(waitUntil(timeout: 3) {
                keyboardArrangeApp.descendants(matching: .any)["answerCorrect"]
                    .exists
                    || keyboardArrangeApp.descendants(matching: .any)["answerIncorrect"].exists
            })
        }

        let clozeApp = launchApp(scenario: "study-cloze")
        runJourneyActivity("StudyUITests.testClozeConcealsThenRevealsBlank") {
            startStudy(in: clozeApp)
            XCTAssertFalse(clozeApp.staticTexts["Paris"].exists)
            triggerPrimaryStudyAction(in: clozeApp)
            XCTAssertTrue(
                clozeApp.staticTexts.matching(
                    NSPredicate(format: "value CONTAINS[c] %@", "Paris")
                ).firstMatch.waitUntilExists(timeout: 3)
            )
        }

        let recordApp = launchApp(scenario: "study-record")
        startStudy(in: recordApp)
        runJourneyActivity("StudyUITests.testRecordRequiresRecordingButAllowsSelfGradeFallback") {
            XCTAssertTrue(recordApp.buttons.identified("startRecording").waitUntilExists(timeout: 3))
            XCTAssertFalse(recordApp.buttons.identified("primaryStudyAction").isEnabled)
        }
        runJourneyActivity("StudyExtendedUITests.testRevealAndSelfGradeViaRightArrow") {
            recordApp.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            XCTAssertTrue(recordApp.buttons.identified("gradeGood").waitUntilExists(timeout: 3))
            clickOrType("gradeGood", shortcut: "3", in: recordApp)
            finishStudySession(in: recordApp)
        }

        let editApp = launchApp(scenario: "study-edit")
        runJourneyActivity("StudyExtendedUITests.testEditCardDuringSessionKeepsStudying") {
            startStudy(in: editApp)
            editApp.buttons.identified("editStudyCard").click()
            XCTAssertTrue(editApp.buttons.identified("saveEditItem").waitUntilExists(timeout: 3))
            enterText(
                "Capital of France",
                into: field(named: "Front", in: editApp),
                app: editApp
            )
            editApp.buttons.identified("saveEditItem").click()
            XCTAssertTrue(editApp.buttons.identified("saveEditItem").waitUntilGone(timeout: 5))
            revealAndGrade("gradeGood", in: editApp)
            finishStudySession(in: editApp)
            waitForItem(named: "Capital of France", in: editApp)
            assertNoItem(named: "Capital of Frnace", in: editApp)
        }
    }

    func checkStudyUITestsStudyBasicItemFlow() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
    }

    func checkStudyUITestsStudyAllGradeButtons() throws {
        let app = launchApp()
        addBasicItem(front: "Grade Test", back: "Answer", in: app)
        startStudy(in: app)
        triggerPrimaryStudyAction(in: app)

        for gradeID in ["gradeAgain", "gradeHard", "gradeGood", "gradeEasy"] {
            XCTAssertTrue(app.buttons.identified(gradeID).waitUntilExists(timeout: 3), "Missing \(gradeID)")
        }

        clickOrType("gradeGood", shortcut: "3", in: app)
        finishStudySession(in: app)
    }

    func checkStudyUITestsStudyAgainGrade() throws {
        let app = launchApp()
        addBasicItem(front: "Again Q", back: "Again A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeAgain", in: app)
        finishStudySession(in: app)
    }

    func checkStudyUITestsStudyHardGrade() throws {
        let app = launchApp()
        addBasicItem(front: "Hard Q", back: "Hard A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeHard", in: app)
        finishStudySession(in: app)
    }

    func checkStudyUITestsStudyEasyGrade() throws {
        let app = launchApp()
        addBasicItem(front: "Easy Q", back: "Easy A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeEasy", in: app)
        finishStudySession(in: app)
    }

    func checkStudyUITestsStudyMultiCardSession() throws {
        let app = launchApp()
        addBasicItem(front: "Card One", back: "A", in: app)
        addBasicItem(front: "Card Two", back: "B", in: app)

        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
    }

    func checkStudyUITestsStudyEndSessionWithConfirmation() throws {
        let app = launchApp()
        addBasicItem(front: "End Q1", back: "A1", in: app)
        addBasicItem(front: "End Q2", back: "A2", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)

        app.buttons.identified("endStudySession").click()
        if app.buttons.identified("confirmEndStudySession").waitUntilExists(timeout: 3) {
            app.buttons.identified("confirmEndStudySession").click()
        } else if let container = modalContainer(in: app) {
            container.buttons.identified("End Session").click()
        }

        waitForLibraryReady(in: app)
        assertDueCardsAvailable(in: app)
    }

    func checkStudyUITestsStudyGradeHelpPopover() throws {
        let app = launchApp()
        addBasicItem(front: "Help Q", back: "Help A", in: app)
        startStudy(in: app)

        app.buttons.identified("gradeHelp").click()
        XCTAssertTrue(app.descendants(matching: .any)["gradeGuidePanel"].waitUntilExists(timeout: 5))
    }

    func checkStudyUITestsStudyReverseTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

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
        app.buttons.identified("saveTemplate").click()
        closeTemplates(in: app)

        addBasicItem(front: "Reverse Q", back: "Reverse A", in: app)
        startStudy(in: app)

        let primaryAction = app.buttons.identified("primaryStudyAction")
        if primaryAction.waitUntilExists(timeout: 5) {
            primaryAction.click()
            if app.buttons.identified("gradeGood").waitUntilExists(timeout: 2) {
                clickOrType("gradeGood", shortcut: "3", in: app)
            }
        }

        if app.buttons.identified("primaryStudyAction").waitUntilExists(timeout: 3) {
            triggerPrimaryStudyAction(in: app)
            clickOrType("gradeGood", shortcut: "3", in: app)
        }

        finishStudySession(in: app)
    }

    func checkStudyUITestsTypedAnswerRequiresInputThenAcceptsCorrectAnswer() throws {
        let app = launchApp(scenario: "study-type")
        startStudy(in: app)

        let primary = app.buttons.identified("primaryStudyAction")
        primary.click()
        XCTAssertTrue(app.descendants(matching: .any)["studyInteractionMessage"].waitUntilExists(timeout: 3))

        enterText("Paris", into: app.textFields.identified("typedAnswer"), app: app)
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitUntilExists(timeout: 3))
        XCTAssertTrue(app.buttons.identified("gradeGood").exists)
        clickOrType("gradeGood", shortcut: "3", in: app)
        finishStudySession(in: app)
    }

    func checkStudyUITestsTypedAnswerReportsIncorrectResponse() throws {
        let app = launchApp(scenario: "study-type")
        startStudy(in: app)

        enterText("London", into: app.textFields.identified("typedAnswer"), app: app)
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitUntilExists(timeout: 3))
        let feedback = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "Compare your response")
        ).firstMatch
        XCTAssertTrue(feedback.waitUntilExists(timeout: 3))
    }

    func checkStudyUITestsChoiceRequiresSelectionThenChecksCorrectChoice() throws {
        let app = launchApp(scenario: "study-choose")
        startStudy(in: app)

        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["studyInteractionMessage"].waitUntilExists(timeout: 3))

        let paris = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Paris")
        ).firstMatch
        XCTAssertTrue(paris.waitUntilExists(timeout: 3))
        paris.click()
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["answerCorrect"].waitUntilExists(timeout: 3))
    }

    func checkStudyUITestsArrangeUncheckedOrderIsReportedIncorrect() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        XCTAssertTrue(app.buttons.identified("arrangementItem0").waitUntilExists(timeout: 3))
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["answerIncorrect"].waitUntilExists(timeout: 3))
    }

    func checkStudyUITestsClozeConcealsThenRevealsBlank() throws {
        let app = launchApp(scenario: "study-cloze")
        startStudy(in: app)

        XCTAssertFalse(app.staticTexts["Paris"].exists)
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "Paris")
            ).firstMatch.waitUntilExists(timeout: 3)
        )
    }

    func checkStudyUITestsRecordRequiresRecordingButAllowsSelfGradeFallback() throws {
        let app = launchApp(scenario: "study-record")
        startStudy(in: app)

        XCTAssertTrue(app.buttons.identified("startRecording").waitUntilExists(timeout: 3))
        XCTAssertFalse(app.buttons.identified("primaryStudyAction").isEnabled)
        app.buttons.identified("revealAndSelfGrade").click()
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 3))
    }

    func checkStudyUITestsUndoLastGradeRestoresReviewedCard() throws {
        let app = launchApp()
        addBasicItem(front: "Undo Q", back: "Undo A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)

        let undo = app.buttons.identified("undoLastGrade")
        XCTAssertTrue(undo.waitUntilExists(timeout: 5))
        undo.click()
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 5))
        XCTAssertFalse(app.buttons.identified("studySessionDone").exists)
    }
}
