import Foundation
import XCTest

extension FastFunctionalJourneyTests {
    func runSharedVocabularyJourney() throws {
        let packURL = try makeVocabularyPackFixture()
        let app = launchApp()
        createDeck(named: "Ukrainian", in: app)
        selectScope("deckRow-Ukrainian", in: app)

        app.menuBarItems["Library"].click()
        app.menuItems.identified("Vocabulary Packs…").click()
        let importPack = app.buttons.identified("importVocabularyPackEmptyState")
        XCTAssertTrue(importPack.waitUntilHittable(timeout: 5))
        importPack.click()
        chooseFileInOpenPanel(packURL, in: app)
        XCTAssertTrue(app.staticTexts["Ukrainian UI Fixture"].waitUntilExists(timeout: 20))
        app.buttons.identified("vocabularyPacksDone").click()
        if let notice = firstExisting(of: [app.buttons["action-button-1"], app.buttons["OK"]], timeout: 1), notice.isHittable { notice.click() }

        selectScope("deckRow-Ukrainian", in: app)
        app.menuBarItems["File"].click()
        app.menuItems.identified("Add Word…").click()
        let query = app.textFields.identified("word-capture-query")
        XCTAssertTrue(query.waitUntilExists(timeout: 5))
        enterText("слово", into: query, app: app)
        app.buttons.identified("word-capture-setup").click()
        let typePicker = app.popUpButtons.identified("word-capture-setup-type")
        if typePicker.exists {
            typePicker.click()
            app.menuItems["Basic"].click()
        }
        app.buttons.identified("word-capture-save-setup").click()

        for addition in 1 ... 2 {
            if addition > 1 { enterText("слово", into: query, app: app) }
            let add = app.buttons.identified("word-capture-add")
            XCTAssertTrue(waitUntil(timeout: 10) { add.isEnabled && add.isHittable })
            add.click()
            let success = app.descendants(matching: .any)["word-capture-success"]
            XCTAssertTrue(success.waitUntilExists(timeout: 10))
            XCTAssertTrue((success.label + " " + (success.value as? String ?? "")).contains("Ukrainian"))
            XCTAssertTrue(query.exists, "The flow stays open for another word")
        }
        app.buttons.identified("word-capture-done").click()
        XCTAssertTrue(query.waitUntilGone(timeout: 5))
        app.menuBarItems["File"].click()
        app.menuItems.identified("Add Word…").click()
        XCTAssertTrue(waitUntil(timeout: 5) { (app.buttons.identified("word-capture-setup").value as? String) == "Basic" })
        app.buttons.identified("word-capture-done").click()
        showSidebar(in: app)
        enterBrowseMode(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["itemBrowserTable"].waitUntilExists(timeout: 10))
        let itemRange = app.descendants(matching: .any)["browsePageRange"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            (itemRange.label + " " + (itemRange.value as? String ?? "")).contains("Items 1–2 of 2")
        }, "Both captured vocabulary items must be saved")
        leaveBrowseMode(in: app)
        let deckRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deckRow-'"))
        XCTAssertEqual(deckRows.count, 1, "Word capture must not create child decks")

        checkKnownWordsFilter(in: app)
    }

    private func checkKnownWordsFilter(in app: XCUIApplication) {
        showSidebar(in: app)
        let knownWords = app.descendants(matching: .any).identified("knownWordsSidebar")
        XCTAssertTrue(knownWords.waitUntilHittable(timeout: 5))
        knownWords.click()
        let language = app.popUpButtons.identified("known-words-language")
        XCTAssertTrue(language.waitUntilHittable(timeout: 5))
        language.click()
        app.menuItems["Ukrainian"].click()

        let filter = app.popUpButtons.identified("known-words-filter")
        XCTAssertTrue(filter.waitUntilHittable(timeout: 5))
        let add = app.buttons.identified("known-words-add")
        XCTAssertTrue(add.waitUntilHittable(timeout: 5))
        add.click()
        let wordField = app.textFields.identified("vocabulary-set-word")
        XCTAssertTrue(wordField.waitUntilHittable(timeout: 5))
        let word = "книга"
        enterText(word, into: wordField, app: app)
        let save = app.buttons.identified("vocabulary-set-save")
        XCTAssertTrue(waitUntil(timeout: 5) { save.isHittable && save.isEnabled })
        save.click()

        let row = app.staticTexts[word]
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
        filter.click()
        app.menuItems["Ignored (0)"].click()
        XCTAssertTrue(app.staticTexts["No Ignored Words"].waitUntilExists(timeout: 5))
        filter.click()
        app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Known (")).firstMatch.click()
        XCTAssertTrue(row.waitUntilExists(timeout: 5))
    }

    private func makeVocabularyPackFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "neoanki2-ui-vocabulary-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let source = root.appendingPathComponent("entries.jsonl")
        let entry = """
        {"id":"uk:слово:ui","language":"uk","canonicalForm":{"text":{"value":"слово","language":"uk"},"kind":"lemma","grammaticalFeatures":[]},"forms":[],"pronunciations":[{"id":"stress","scheme":"orthographic-respelling","label":"Stress","representations":[{"text":{"_0":{"value":"сло́во","language":"uk"}}}]}],"senses":[{"id":"sense-1","definitions":[{"id":"definition-1","text":{"value":"Одиниця мови, що служить для називання понять.","language":"uk"}}],"examples":[{"id":"example-1","text":{"value":"Це важливе слово.","language":"uk"},"target":{"exactText":"слово"}}],"labels":[]}]}
        """
        try Data((entry + "\n").utf8).write(to: source, options: .atomic)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compiler = repositoryRoot.appendingPathComponent(".build/debug/neoanki-vocab")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: compiler.path),
            "Scripts/build-test-app.sh should build neoanki-vocab before UI tests"
        )

        let pack = root.appendingPathComponent("Ukrainian-UI.neovocab", isDirectory: true)
        let process = Process()
        process.executableURL = compiler
        process.arguments = [
            "compile",
            "--input", source.path,
            "--output", pack.path,
            "--id", "ui.fixture.uk",
            "--title", "Ukrainian UI Fixture",
            "--language", "uk",
            "--capability", "lexicon",
            "--capability", "pronunciation",
            "--capability", "corpus",
        ]
        let diagnostics = Pipe()
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        return pack
    }
}
