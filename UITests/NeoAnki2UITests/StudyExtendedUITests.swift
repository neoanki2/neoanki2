import XCTest

extension FastFunctionalJourneyTests {
    func checkStudyExtendedUITestsStartStudyViaMenu() throws {
        let app = launchApp()
        addBasicItem(front: "Menu Q", back: "Menu A", in: app)
        startStudyViaMenu(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsEndStudyViaMenuWithConfirmation() throws {
        let app = launchApp()
        addBasicItem(front: "End Menu Q1", back: "A1", in: app)
        addBasicItem(front: "End Menu Q2", back: "A2", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        endStudyViaMenu(in: app)
        assertDueCardsAvailable(in: app)
    }

    func checkStudyExtendedUITestsGradeViaKeyboardShortcuts() throws {
        let app = launchApp()
        addBasicItem(front: "Keyboard Q", back: "Keyboard A", in: app)
        startStudy(in: app)
        triggerPrimaryStudyAction(in: app)
        gradeViaKeyboard(3, in: app)
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsContinueViaSpace() throws {
        let app = launchApp()
        addBasicItem(front: "Space Q", back: "Space A", in: app)
        startStudy(in: app)
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 5))
        clickOrType("gradeGood", shortcut: "3", in: app)
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsUndoLastGradeViaCommandZ() throws {
        let app = launchApp()
        addBasicItem(front: "CmdZ Q", back: "CmdZ A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        app.typeKey("z", modifierFlags: [.command])
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 5))
        clickOrType("gradeGood", shortcut: "3", in: app)
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsArrangeReorderToCorrectOrder() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        let moveDown = app.buttons.identified("moveArrangementDown")
        if moveDown.waitUntilExists(timeout: 3), moveDown.isEnabled {
            moveDown.click()
        }
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["answerCorrect"].waitUntilExists(timeout: 5)
                || app.descendants(matching: .any)["studyAnswer"].waitUntilExists(timeout: 5)
        )
        if app.buttons.identified("gradeGood").exists {
            clickOrType("gradeGood", shortcut: "3", in: app)
        }
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsArrangeKeyboardReorder() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        app.buttons.identified("arrangementItem0").click()
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [.command])
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["answerCorrect"].waitUntilExists(timeout: 5)
                || app.descendants(matching: .any)["answerIncorrect"].waitUntilExists(timeout: 5)
        )
    }

    func checkStudyExtendedUITestsRevealAndSelfGradeViaRightArrow() throws {
        let app = launchApp(scenario: "study-record")
        startStudy(in: app)
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 5))
        clickOrType("gradeGood", shortcut: "3", in: app)
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsStudyCaughtUpState() throws {
        let app = launchApp()
        addBasicItem(front: "Caught Up Q", back: "Caught Up A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
    }

    func checkStudyExtendedUITestsEditCardDuringSessionKeepsStudying() throws {
        let app = launchApp()
        addBasicItem(front: "Capital of Frnace", back: "Paris", in: app)
        startStudy(in: app)

        app.buttons.identified("editStudyCard").click()
        XCTAssertTrue(app.buttons.identified("saveEditItem").waitUntilExists(timeout: 5))
        enterText("Capital of France", into: field(named: "Front", in: app), app: app)
        app.buttons.identified("saveEditItem").click()
        XCTAssertTrue(app.buttons.identified("saveEditItem").waitUntilGone(timeout: 10))

        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        waitForItem(named: "Capital of France", in: app)
        assertNoItem(named: "Capital of Frnace", in: app)
    }

    func checkStudyExtendedUITestsEditCardViaCommandEThenCancel() throws {
        let app = launchApp()
        addBasicItem(front: "Shortcut Q", back: "Shortcut A", in: app)
        startStudy(in: app)

        app.typeKey("e", modifierFlags: [.command])
        XCTAssertTrue(app.buttons.identified("cancelEditItem").waitUntilExists(timeout: 5))
        app.buttons.identified("cancelEditItem").click()

        XCTAssertTrue(app.buttons.identified("primaryStudyAction").waitUntilExists(timeout: 5))
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)
    }

    func checkStudyExtendedUITestsDismissUndoBanner() throws {
        let app = launchApp()
        addBasicItem(front: "Dismiss Undo Q", back: "Dismiss Undo A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)

        let dismiss = app.buttons.identified("dismissGradeUndo")
        if dismiss.waitUntilExists(timeout: 3) {
            dismiss.click()
            XCTAssertTrue(dismiss.waitUntilGone(timeout: 2))
        }
        finishStudySession(in: app)
    }
}
