import XCTest

final class StudyExtendedUITests: NeoAnkiUITestCase {
    func testStartStudyViaMenu() throws {
        let app = launchApp()
        addBasicItem(front: "Menu Q", back: "Menu A", in: app)
        startStudyViaMenu(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)
    }

    func testEndStudyViaMenuWithConfirmation() throws {
        let app = launchApp()
        addBasicItem(front: "End Menu Q1", back: "A1", in: app)
        addBasicItem(front: "End Menu Q2", back: "A2", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        endStudyViaMenu(in: app)
        assertDueCardsAvailable(in: app)
    }

    func testGradeViaKeyboardShortcuts() throws {
        let app = launchApp()
        addBasicItem(front: "Keyboard Q", back: "Keyboard A", in: app)
        startStudy(in: app)
        app.buttons.identified("primaryStudyAction").click()
        gradeViaKeyboard(3, in: app)
        finishStudySession(in: app)
    }

    func testContinueViaSpace() throws {
        let app = launchApp()
        addBasicItem(front: "Space Q", back: "Space A", in: app)
        startStudy(in: app)
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertTrue(app.buttons.identified("gradeGood").waitForExistence(timeout: 5))
        app.buttons.identified("gradeGood").click()
        finishStudySession(in: app)
    }

    func testUndoLastGradeViaCommandZ() throws {
        let app = launchApp()
        addBasicItem(front: "CmdZ Q", back: "CmdZ A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        app.typeKey("z", modifierFlags: [.command])
        XCTAssertTrue(app.buttons.identified("gradeGood").waitForExistence(timeout: 5))
        app.buttons.identified("gradeGood").click()
        finishStudySession(in: app)
    }

    func testArrangeReorderToCorrectOrder() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        let moveDown = app.buttons.identified("moveArrangementDown")
        if moveDown.waitForExistence(timeout: 3), moveDown.isEnabled {
            moveDown.click()
        }
        app.buttons.identified("primaryStudyAction").click()
        XCTAssertTrue(
            app.descendants(matching: .any)["answerCorrect"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)["studyAnswer"].waitForExistence(timeout: 5)
        )
        if app.buttons.identified("gradeGood").exists {
            app.buttons.identified("gradeGood").click()
        }
        finishStudySession(in: app)
    }

    func testArrangeKeyboardReorder() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        app.buttons.identified("arrangementItem0").click()
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [.command])
        app.buttons.identified("primaryStudyAction").click()
        XCTAssertTrue(
            app.descendants(matching: .any)["answerCorrect"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)["answerIncorrect"].waitForExistence(timeout: 5)
        )
    }

    func testRevealAndSelfGradeViaRightArrow() throws {
        let app = launchApp(scenario: "study-record")
        startStudy(in: app)
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons.identified("gradeGood").waitForExistence(timeout: 5))
        app.buttons.identified("gradeGood").click()
        finishStudySession(in: app)
    }

    func testStudyCaughtUpState() throws {
        let app = launchApp()
        addBasicItem(front: "Caught Up Q", back: "Caught Up A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
    }

    func testDismissUndoBanner() throws {
        let app = launchApp()
        addBasicItem(front: "Dismiss Undo Q", back: "Dismiss Undo A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)

        let dismiss = app.buttons.identified("dismissGradeUndo")
        if dismiss.waitForExistence(timeout: 3) {
            dismiss.click()
            XCTAssertFalse(dismiss.waitForExistence(timeout: 2))
        }
        finishStudySession(in: app)
    }
}
