import Foundation
import XCTest

extension FastFunctionalJourneyTests {
    func runSharedVocabularyJourney() throws {
        let packURL = try makeVocabularyPackFixture()
        let app = launchApp()

        createDeck(named: "Ukrainian", in: app)
        selectScope("deckRow-Ukrainian", in: app)
        assertMenuDisabled("Add from Vocabulary…", in: app)

        app.menuBarItems["Library"].click()
        let packsMenuItem = app.menuItems.identified("Vocabulary Packs…")
        XCTAssertTrue(packsMenuItem.waitUntilExists(timeout: 3))
        XCTAssertTrue(packsMenuItem.isEnabled)
        packsMenuItem.click()

        let importPack = app.buttons.identified("importVocabularyPackEmptyState")
        XCTAssertTrue(importPack.waitUntilHittable(timeout: 5))
        importPack.click()
        chooseFileInOpenPanel(packURL, in: app)

        let installedPack = app.descendants(matching: .any)["vocabularyPack-ui.fixture.uk"]
        let installedPackTitle = app.staticTexts["Ukrainian UI Fixture"]
        XCTAssertTrue(
            waitUntil(timeout: 20) { installedPack.exists || installedPackTitle.exists },
            "The imported pack should appear in the managed pack library"
        )

        app.buttons.identified("vocabularyPacksDone").click()
        XCTAssertTrue(
            app.buttons.identified("vocabularyPacksDone").waitUntilGone(timeout: 5)
        )
        if let noticeButton = firstExisting(
            of: [app.buttons["action-button-1"], app.buttons["OK"]],
            timeout: 1
        ), noticeButton.isHittable {
            noticeButton.click()
        }

        selectScope("deckRow-Ukrainian", in: app)
        let addFromVocabulary = app.buttons.identified("addFromVocabularyToolbar")
        XCTAssertTrue(addFromVocabulary.waitUntilHittable(timeout: 5))
        addFromVocabulary.click()

        XCTAssertTrue(
            app.textFields.identified("vocabularyBuilderSearchField")
                .waitUntilExists(timeout: 5),
            "The vocabulary builder should open for the selected destination deck"
        )

        for addition in 1 ... 2 {
            let searchField = app.textFields.identified("vocabularyBuilderSearchField")
            enterText("слово", into: searchField, app: app)

            let search = app.buttons.identified("vocabularyBuilderSearch")
            XCTAssertTrue(search.waitUntilHittable(timeout: 5))
            search.click()

            let entry = app.buttons.identified("vocabularyBuilderEntry-uk:слово:ui")
            XCTAssertTrue(entry.waitUntilHittable(timeout: 10))
            entry.click()

            let identifiedAdd = app.buttons.identified("vocabularyBuilderAdd")
            let labeledAdd = app.buttons["Add Cards"]
            XCTAssertTrue(
                waitUntil(timeout: 10) {
                    (identifiedAdd.exists && identifiedAdd.isEnabled && identifiedAdd.isHittable)
                        || (labeledAdd.exists && labeledAdd.isEnabled && labeledAdd.isHittable)
                },
                "The selected entry should produce addable cards"
            )
            let add = identifiedAdd.exists ? identifiedAdd : labeledAdd
            add.click()

            let identifiedSuccess = app.descendants(matching: .any)["vocabularyBuilderSuccess"]
            let labeledSuccess = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "3 items added to Ukrainian")
            ).firstMatch
            XCTAssertTrue(
                waitUntil(timeout: 20) { identifiedSuccess.exists || labeledSuccess.exists },
                "Vocabulary addition \(addition) should finish without closing the flow"
            )
            let success = identifiedSuccess.exists ? identifiedSuccess : labeledSuccess
            XCTAssertTrue(
                (success.label + " " + (success.value as? String ?? ""))
                    .contains("3 items added to Ukrainian")
            )
            XCTAssertTrue(
                searchField.waitUntilExists(timeout: 3),
                "The vocabulary flow should remain open for another word"
            )
        }

        let identifiedCancel = app.buttons.identified("vocabularyBuilderCancel")
        let labeledCancel = app.buttons["Cancel"]
        let cancel = identifiedCancel.exists ? identifiedCancel : labeledCancel
        XCTAssertTrue(cancel.waitUntilHittable(timeout: 5))
        cancel.click()
        XCTAssertTrue(
            app.textFields.identified("vocabularyBuilderSearchField").waitUntilGone(timeout: 5)
        )

        showSidebar(in: app)
        let destination = app.descendants(matching: .any)["deckRow-Ukrainian"]
        let dueHeadline = app.descendants(matching: .any)["scopeHomeDueHeadline"]
        let browseLink = app.descendants(matching: .any)["scopeHomeBrowseLink"]
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                guard destination.exists, dueHeadline.exists, browseLink.exists else {
                    return false
                }
                let dueText = dueHeadline.label + " " + (dueHeadline.value as? String ?? "")
                let browseText = browseLink.label + " " + (browseLink.value as? String ?? "")
                return dueText.contains("8 cards due")
                    && browseText.contains("Browse 6 Items")
            },
            "Both additions should land in the one selected deck"
        )
        let deckRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'deckRow-'")
        )
        XCTAssertEqual(deckRows.count, 1, "Vocabulary additions must not create child decks")
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
