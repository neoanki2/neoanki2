import XCTest

final class StudyUITests: NeoAnkiUITestCase {
    func testStudyBasicItemFlow() throws {
        let app = launchApp()
        addBasicItem(front: "France", back: "Paris", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)
        finishStudySession(in: app)

        let studyButton = app.buttons["studyButton"]
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertFalse(studyButton.isEnabled)
    }

    func testStudyAllGradeButtons() throws {
        let app = launchApp()
        addBasicItem(front: "Grade Test", back: "Answer", in: app)
        startStudy(in: app)
        app.buttons["primaryStudyAction"].click()

        for gradeID in ["gradeAgain", "gradeHard", "gradeGood", "gradeEasy"] {
            XCTAssertTrue(app.buttons[gradeID].waitForExistence(timeout: 3), "Missing \(gradeID)")
        }

        app.buttons["gradeGood"].click()
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

        let studyButton = app.buttons["studyButton"]
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        XCTAssertFalse(studyButton.isEnabled)
    }

    func testStudyEndSessionWithConfirmation() throws {
        let app = launchApp()
        addBasicItem(front: "End Q1", back: "A1", in: app)
        addBasicItem(front: "End Q2", back: "A2", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)

        app.buttons["endStudySession"].click()
        if app.buttons["confirmEndStudySession"].waitForExistence(timeout: 3) {
            app.buttons["confirmEndStudySession"].click()
        } else if let container = modalContainer(in: app) {
            container.buttons["End Session"].click()
        }

        waitForLibraryReady(in: app)
        XCTAssertTrue(app.buttons["studyButton"].waitForExistence(timeout: 5))
    }

    func testStudyGradeHelpPopover() throws {
        let app = launchApp()
        addBasicItem(front: "Help Q", back: "Help A", in: app)
        startStudy(in: app)

        app.buttons["gradeHelp"].click()
        XCTAssertTrue(app.descendants(matching: .any)["gradeGuidePanel"].waitForExistence(timeout: 5))
    }

    func testStudyReverseTemplate() throws {
        let app = launchApp()
        openTemplates(in: app)

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
        closeTemplates(in: app)

        addBasicItem(front: "Reverse Q", back: "Reverse A", in: app)
        startStudy(in: app)

        let primaryAction = app.buttons["primaryStudyAction"]
        if primaryAction.waitForExistence(timeout: 5) {
            primaryAction.click()
            if app.buttons["gradeGood"].waitForExistence(timeout: 2) {
                app.buttons["gradeGood"].click()
            }
        }

        if app.buttons["primaryStudyAction"].waitForExistence(timeout: 3) {
            app.buttons["primaryStudyAction"].click()
            app.buttons["gradeGood"].click()
        }

        finishStudySession(in: app)
    }

    func testTypedAnswerRequiresInputThenAcceptsCorrectAnswer() throws {
        let app = launchApp(scenario: "study-type")
        startStudy(in: app)

        let primary = app.buttons["primaryStudyAction"]
        primary.click()
        XCTAssertTrue(app.descendants(matching: .any)["studyInteractionMessage"].waitForExistence(timeout: 3))

        enterText("Paris", into: app.textFields["typedAnswer"], app: app)
        app.buttons["primaryStudyAction"].click()
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["gradeGood"].exists)
        app.buttons["gradeGood"].click()
        finishStudySession(in: app)
    }

    func testTypedAnswerReportsIncorrectResponse() throws {
        let app = launchApp(scenario: "study-type")
        startStudy(in: app)

        enterText("London", into: app.textFields["typedAnswer"], app: app)
        app.buttons["primaryStudyAction"].click()
        XCTAssertTrue(app.descendants(matching: .any)["studyAnswer"].waitForExistence(timeout: 3))
        let feedback = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "Compare your response")
        ).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 3))
    }

    func testChoiceRequiresSelectionThenChecksCorrectChoice() throws {
        let app = launchApp(scenario: "study-choose")
        startStudy(in: app)

        app.buttons["primaryStudyAction"].click()
        XCTAssertTrue(app.descendants(matching: .any)["studyInteractionMessage"].waitForExistence(timeout: 3))

        let paris = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Paris")
        ).firstMatch
        XCTAssertTrue(paris.waitForExistence(timeout: 3))
        paris.click()
        app.buttons["primaryStudyAction"].click()
        XCTAssertTrue(app.descendants(matching: .any)["answerCorrect"].waitForExistence(timeout: 3))
    }

    func testArrangeUncheckedOrderIsReportedIncorrect() throws {
        let app = launchApp(scenario: "study-arrange")
        startStudy(in: app)

        XCTAssertTrue(app.buttons["arrangementItem0"].waitForExistence(timeout: 3))
        app.buttons["primaryStudyAction"].click()
        XCTAssertTrue(app.descendants(matching: .any)["answerIncorrect"].waitForExistence(timeout: 3))
    }

    func testClozeConcealsThenRevealsBlank() throws {
        let app = launchApp(scenario: "study-cloze")
        startStudy(in: app)

        XCTAssertFalse(app.staticTexts["Paris"].exists)
        app.buttons["primaryStudyAction"].click()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "Paris")
            ).firstMatch.waitForExistence(timeout: 3)
        )
    }

    func testRecordRequiresRecordingButAllowsSelfGradeFallback() throws {
        let app = launchApp(scenario: "study-record")
        startStudy(in: app)

        XCTAssertTrue(app.buttons["startRecording"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["primaryStudyAction"].isEnabled)
        app.buttons["revealAndSelfGrade"].click()
        XCTAssertTrue(app.buttons["gradeGood"].waitForExistence(timeout: 3))
    }

    func testUndoLastGradeRestoresReviewedCard() throws {
        let app = launchApp()
        addBasicItem(front: "Undo Q", back: "Undo A", in: app)
        startStudy(in: app)
        revealAndGrade("gradeGood", in: app)

        let undo = app.buttons["undoLastGrade"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()
        XCTAssertTrue(app.buttons["gradeGood"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studySessionDone"].exists)
    }
}
