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
        app.buttons.identified("addFromVocabularyToolbar").click()
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
        app.buttons.identified("addFromVocabularyToolbar").click()
        XCTAssertTrue(waitUntil(timeout: 5) { (app.buttons.identified("word-capture-setup").value as? String) == "Basic" })
        app.buttons.identified("word-capture-done").click()
        showSidebar(in: app)
        let browse = app.descendants(matching: .any)["scopeHomeBrowseLink"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            (browse.label + " " + (browse.value as? String ?? "")).contains("Browse 2 Items")
        })
        let deckRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deckRow-'"))
        XCTAssertEqual(deckRows.count, 1, "Word capture must not create child decks")
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
