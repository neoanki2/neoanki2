import XCTest

@MainActor
final class NeoAnki2MobileUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func launchApp(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NeoAnkiUITestingReset",
        ] + additionalArguments
        app.launch()
        return app
    }

    private func open(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        if tab.waitForExistence(timeout: 2) {
            tab.tap()
        } else {
            let sidebar = app.buttons["top-level-\(title.lowercased())"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Missing \(title) destination")
            sidebar.tap()
        }

        let navigationTitle = title == "Home" ? "NeoAnki2" : title
        XCTAssertTrue(
            app.navigationBars[navigationTitle].waitForExistence(timeout: 5),
            "Failed to open \(title) destination"
        )
    }

    func testTopLevelProductNavigation() throws {
        let app = launchApp()
        for title in ["Home", "Library", "Create", "Settings"] {
            open(title, in: app)
            let navigationTitle = title == "Home" ? "NeoAnki2" : title
            XCTAssertTrue(app.navigationBars[navigationTitle].waitForExistence(timeout: 3))
        }
    }

    func testDeckCreateRenameAndDeleteJourney() throws {
        let app = launchApp()
        open("Create", in: app)
        app.buttons["New Deck"].tap()
        let name = app.textFields["e.g. Spanish vocabulary"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("Reading")
        app.buttons["new-deck-create"].tap()

        open("Home", in: app)
        XCTAssertTrue(app.staticTexts["Reading"].waitForExistence(timeout: 5))
        app.staticTexts["Reading"].tap()
        app.buttons["Deck Settings"].tap()
        let editor = app.textFields["Name"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" Essays")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Reading Essays"].waitForExistence(timeout: 4))

        app.buttons["Deck Settings"].tap()
        app.buttons["Delete Deck"].tap()
        app.buttons["Delete and Unassign Items"].tap()
        XCTAssertFalse(app.staticTexts["Reading Essays"].waitForExistence(timeout: 2))
    }

    func testCreateBrowseAndStudyBasicCardJourney() throws {
        let app = launchApp()
        open("Create", in: app)
        app.buttons["New Item"].tap()

        let front = app.textFields["add-card-field-front"]
        let back = app.textFields["add-card-field-back"]
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        front.tap()
        front.typeText("Capital of France?")
        back.tap()
        back.typeText("Paris")
        let save = app.buttons["add-card-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        open("Library", in: app)
        XCTAssertTrue(app.staticTexts["Capital of France?"].waitForExistence(timeout: 5))
        app.staticTexts["Capital of France?"].tap()
        XCTAssertTrue(app.staticTexts["Paris"].waitForExistence(timeout: 5))

        open("Home", in: app)
        let start = app.buttons["Start Studying"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let reveal = app.buttons["Show Answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        reveal.tap()
        XCTAssertTrue(app.staticTexts["Paris"].waitForExistence(timeout: 5))
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Session Complete"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["NeoAnki2"].waitForExistence(timeout: 5))
    }

    func testAuthoringTransferVocabularyAndSyncConsentSurfaces() throws {
        let app = launchApp()
        open("Create", in: app)
        for title in ["Item Types & Templates", "Import or Export", "Deck Builders", "Vocabulary Packs"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "Missing \(title)")
        }
        app.buttons["Vocabulary Packs"].tap()
        XCTAssertTrue(app.navigationBars["Vocabulary Packs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Install Pack…"].exists || app.buttons["Install Pack"].exists)

        open("Settings", in: app)
        let enableSync = app.buttons["Enable iCloud Sync…"]
        XCTAssertTrue(enableSync.waitForExistence(timeout: 3))
        enableSync.tap()
        let cancel = app.buttons["Not Now"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Create Backup & Enable"].exists)
        cancel.tap()
        XCTAssertTrue(enableSync.waitForExistence(timeout: 3))
    }

    @available(iOS 17.0, *)
    func testFirstScreenAccessibilityAudit() throws {
        let app = launchApp()
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 5)
                || app.buttons["Home"].firstMatch.waitForExistence(timeout: 5)
        )
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription])
    }

    @available(iOS 17.0, *)
    func testLargestTypeDarkHighContrastReducedMotionInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchApp(additionalArguments: [
            "-NeoAnkiUITestingAccessibility",
        ])
        open("Library", in: app)
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        let addFirstCard = app.buttons["Add First Card"]
        XCTAssertTrue(addFirstCard.waitForExistence(timeout: 5))
        if !addFirstCard.isHittable {
            let emptyStateTitle = app.staticTexts["Build Your Library"]
            XCTAssertTrue(emptyStateTitle.waitForExistence(timeout: 3))
            emptyStateTitle.swipeUp()
        }
        XCTAssertTrue(addFirstCard.isHittable)
        try app.performAccessibilityAudit(
            for: [.contrast, .hitRegion, .sufficientElementDescription]
        ) { issue in
            // SwiftUI owns the TabView/sidebar labels and searchable placeholder, and
            // reports them as contrast failures in this simulated configuration. Keep
            // all app-rendered content audited.
            guard issue.auditType == .contrast,
                  let element = issue.element
            else { return false }

            let isSystemNavigationLabel = element.elementType == .staticText
                && ["Home", "Library", "Create", "Settings"].contains(element.label)
            let isSystemSearchPlaceholder = element.label == "Search cards"
            return isSystemNavigationLabel || isSystemSearchPlaceholder
        }
    }
}
