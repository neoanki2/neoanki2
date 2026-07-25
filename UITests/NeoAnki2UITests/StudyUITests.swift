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
        app.buttons["showAnswer"].click()

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

        let showAnswer = app.buttons["showAnswer"]
        if showAnswer.waitForExistence(timeout: 5) {
            showAnswer.click()
            if app.buttons["gradeGood"].waitForExistence(timeout: 2) {
                app.buttons["gradeGood"].click()
            }
        }

        if app.buttons["showAnswer"].waitForExistence(timeout: 3) {
            showAnswer.click()
            app.buttons["gradeGood"].click()
        }

        finishStudySession(in: app)
    }
}
