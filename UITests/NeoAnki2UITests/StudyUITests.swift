import XCTest

final class StudyUITests: NeoAnkiUITestCase {
    func testStudyBasicItemFlow() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
    }

    func testStudyAllGradeButtons() throws {
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

    func testStudyAgainGrade() throws {
        let app = launchApp()
        addBasicItem(front: "Again Q", back: "Again A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeAgain", in: app)
        finishStudySession(in: app)
    }

    func testStudyHardGrade() throws {
        let app = launchApp()
        addBasicItem(front: "Hard Q", back: "Hard A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeHard", in: app)
        finishStudySession(in: app)
    }

    func testStudyEasyGrade() throws {
        let app = launchApp()
        addBasicItem(front: "Easy Q", back: "Easy A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeEasy", in: app)
        finishStudySession(in: app)
    }

    func testStudyMultiCardSession() throws {
        let app = launchApp()
        addBasicItem(front: "Card One", back: "A", in: app)
        addBasicItem(front: "Card Two", back: "B", in: app)

        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        assertNothingDue(in: app)
    }

    func testStudyEndSessionWithConfirmation() throws {
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

    func testStudyGradeHelpPopover() throws {
        let app = launchApp()
        addBasicItem(front: "Help Q", back: "Help A", in: app)
        startStudy(in: app)

        app.buttons.identified("gradeHelp").click()
        XCTAssertTrue(app.descendants(matching: .any)["gradeGuidePanel"].waitUntilExists(timeout: 5))
    }

    func testStudyReverseTemplate() throws {
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

    func testTypedAnswerRequiresInputThenAcceptsCorrectAnswer() throws {
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

    func testTypedAnswerReportsIncorrectResponse() throws {
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

    func testChoiceRequiresSelectionThenChecksCorrectChoice() throws {
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

    func testArrangeUncheckedOrderIsReportedIncorrect() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        XCTAssertTrue(app.buttons.identified("arrangementItem0").waitUntilExists(timeout: 3))
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["answerIncorrect"].waitUntilExists(timeout: 3))
    }

    func testClozeConcealsThenRevealsBlank() throws {
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

    func testRecordRequiresRecordingButAllowsSelfGradeFallback() throws {
        let app = launchApp(scenario: "study-record")
        startStudy(in: app)

        XCTAssertTrue(app.buttons.identified("startRecording").waitUntilExists(timeout: 3))
        XCTAssertFalse(app.buttons.identified("primaryStudyAction").isEnabled)
        app.buttons.identified("revealAndSelfGrade").click()
        XCTAssertTrue(app.buttons.identified("gradeGood").waitUntilExists(timeout: 3))
    }

    func testUndoLastGradeRestoresReviewedCard() throws {
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
