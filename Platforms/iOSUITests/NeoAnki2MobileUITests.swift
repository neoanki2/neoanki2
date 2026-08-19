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

    private func launchApp(
        additionalArguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NeoAnkiUITestingReset",
        ] + additionalArguments
        app.launchEnvironment.merge(environment) { _, requested in requested }
        app.launch()
        return app
    }

    private func openItemTypeStudioCatalog(in app: XCUIApplication) {
        open("Create", in: app)
        let destination = app.buttons["Item Types & Card Setups"]
        scrollToAndTap(destination, in: app)
        XCTAssertTrue(app.navigationBars["Item Types"].waitForExistence(timeout: 10))
    }

    private func scrollToAndTap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        scrollTo(element, in: app, file: file, line: line)
        element.tap()
    }

    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let returnKey = keyboard.buttons["Return"]
            if returnKey.exists { returnKey.tap() }
            _ = keyboard.waitForNonExistence(timeout: 2)
        }
        func isReachable() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            let navigationBars = app.navigationBars.allElementsBoundByIndex
            if navigationBars.contains(where: { $0.frame.contains(frame) }) {
                return true
            }
            let contentTop = navigationBars.map(\.frame.maxY).max() ?? app.frame.minY
            let contentBottom = app.tabBars.allElementsBoundByIndex
                .map(\.frame.minY)
                .min() ?? app.frame.maxY
            return frame.midY >= contentTop
                && frame.midY <= contentBottom
                && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        let scrollingSurface = scrollingSurface(for: element, in: app)
        let navigationBottom = app.navigationBars.allElementsBoundByIndex
            .map(\.frame.maxY)
            .max() ?? app.frame.minY
        let directions: [MobileScrollDirection] = if element.exists
            && element.frame.midY < navigationBottom {
            [.towardTop, .towardBottom]
        } else {
            [.towardBottom, .towardTop]
        }
        for direction in directions {
            for _ in 0..<8 where !isReachable() {
                scrollOneStep(on: scrollingSurface, direction: direction)
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertTrue(isReachable(), "Element is not reachable: \(element)", file: file, line: line)
    }

    private enum MobileScrollDirection {
        case towardTop
        case towardBottom
    }

    private func scrollingSurface(for element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let candidates = (
            app.scrollViews.allElementsBoundByIndex
                + app.collectionViews.allElementsBoundByIndex
        ).filter { candidate in
            candidate.label != "Sidebar"
                && !candidate.frame.isEmpty
                && candidate.frame.intersects(app.frame)
        }
        guard !candidates.isEmpty else { return app }

        if element.exists {
            let targetX = element.frame.midX
            let horizontallyContaining = candidates.filter {
                $0.frame.minX <= targetX && targetX <= $0.frame.maxX
            }
            if let mostSpecific = horizontallyContaining.min(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) {
                return mostSpecific
            }
        }

        // Before a lazy Form row exists there is no target x-position to use.
        // Prefer the rightmost surface so iPad's navigation sidebar cannot win
        // merely because it is tall or has no accessibility label.
        return candidates.max(by: { lhs, rhs in
            if lhs.frame.maxX != rhs.frame.maxX {
                return lhs.frame.maxX < rhs.frame.maxX
            }
            return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) ?? app
    }

    /// Use slower native gestures on compact surfaces so tall rows are not
    /// skipped. Wider iPad surfaces use the system default gesture, which
    /// settles reliably before the next accessibility snapshot.
    private func scrollOneStep(on surface: XCUIElement, direction: MobileScrollDirection) {
        let usesCompactGesture = surface.frame.width < 600
        switch direction {
        case .towardBottom:
            if usesCompactGesture {
                surface.swipeUp(velocity: .slow)
            } else {
                surface.swipeUp()
            }
        case .towardTop:
            if usesCompactGesture {
                surface.swipeDown(velocity: .slow)
            } else {
                surface.swipeDown()
            }
        }
    }

    private func firstCardSetupButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "itemTypeStudio.cardSetup.")
        ).firstMatch
    }

    private func clearText(in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        guard !current.isEmpty else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    private func assertNoHorizontalOverflow(
        in container: XCUIElement,
        viewport: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let containerFrame = container.frame
        let viewportFrame = viewport.frame
        let visibleDescendants = container.descendants(matching: .any).allElementsBoundByIndex.filter {
            !$0.frame.isEmpty
                && $0.frame.intersects(containerFrame)
                && $0.identifier != "AdditionalDimmingOverlay"
                && $0.label != "AdditionalDimmingOverlay"
        }
        XCTAssertFalse(visibleDescendants.isEmpty, "No visible editor content to measure", file: file, line: line)
        for element in visibleDescendants {
            XCTAssertGreaterThanOrEqual(
                element.frame.minX,
                max(containerFrame.minX, viewportFrame.minX) - 1,
                "Editor descendant overflows the leading edge: \(element)",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                element.frame.maxX,
                min(containerFrame.maxX, viewportFrame.maxX) + 1,
                "Editor descendant overflows the trailing edge: \(element)",
                file: file,
                line: line
            )
        }
    }

    private func assertAccessibilityTraversalOrder(
        _ orderedElements: [(XCUIElement, XCUIElement.ElementType)],
        in container: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let accessibilityElements = container.descendants(matching: .any)
            .allElementsBoundByAccessibilityElement
        var previousIndex = -1

        for (element, expectedType) in orderedElements {
            XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertEqual(element.elementType, expectedType, file: file, line: line)
            XCTAssertFalse(
                element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "VoiceOver element has no spoken label: \(element)",
                file: file,
                line: line
            )
            let index = accessibilityElements.firstIndex { candidate in
                candidate.identifier == element.identifier
            }
            XCTAssertNotNil(
                index,
                "Element is missing from the accessibility traversal: \(element.identifier)",
                file: file,
                line: line
            )
            if let index {
                XCTAssertGreaterThan(
                    index,
                    previousIndex,
                    "Accessibility traversal does not follow the editor's logical order",
                    file: file,
                    line: line
                )
                previousIndex = index
            }
        }

        for pair in zip(orderedElements, orderedElements.dropFirst()) {
            let upper = pair.0.0.frame
            let lower = pair.1.0.frame
            XCTAssertLessThanOrEqual(
                upper.minY,
                lower.minY,
                "Accessibility traversal order disagrees with the visual top-to-bottom order",
                file: file,
                line: line
            )
        }
    }

    private func open(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "App navigation unavailable")
        let navigationTitle = title == "Home" ? "NeoAnki2" : title
        let navigationBar = app.navigationBars[navigationTitle]
        let tabDestination = app.tabBars.buttons[title]
        let sidebarDestination = app.buttons["top-level-\(title.lowercased())"]
        let destination = tabDestination.waitForExistence(timeout: 2)
            ? tabDestination
            : sidebarDestination

        for _ in 0..<3 {
            guard destination.waitForExistence(timeout: 5) else { continue }
            if destination.isSelected { return }
            destination.tap()
            let selected = NSPredicate(format: "isSelected == true")
            if XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: selected, object: destination)],
                timeout: 5
            ) == .completed,
               navigationBar.waitForExistence(timeout: 5) {
                return
            }
        }

        XCTFail("Failed to open \(title) destination")
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
        XCTAssertTrue(
            app.navigationBars["Reading Essays"].waitForExistence(timeout: 10),
            "Renamed deck did not become visible after saving"
        )

        app.buttons["Deck Settings"].tap()
        app.buttons["Delete Deck"].tap()
        app.buttons["Delete and Unassign Items"].tap()
        XCTAssertTrue(
            app.staticTexts["Reading Essays"].waitForNonExistence(timeout: 10),
            "Deleted deck remained visible"
        )
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
        let itemLink = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Capital of France?")
        ).firstMatch
        XCTAssertTrue(itemLink.waitForExistence(timeout: 5))
        itemLink.tap()
        XCTAssertTrue(app.staticTexts["Paris"].waitForExistence(timeout: 5))

        open("Home", in: app)
        let start = app.buttons["Start Studying"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let reveal = app.buttons["Show Answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 15))
        reveal.tap()
        XCTAssertTrue(app.staticTexts["Paris"].waitForExistence(timeout: 5))
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Session Complete"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["NeoAnki2"].waitForExistence(timeout: 5))
    }

    func testAuthoringTransferVocabularyAndSyncConsentSurfaces() throws {
        let app = launchApp()
        open("Create", in: app)
        for title in ["Item Types & Card Setups", "Import or Export", "Deck Builders", "Vocabulary Packs"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "Missing \(title)")
        }
        app.buttons["Vocabulary Packs"].tap()
        XCTAssertTrue(app.navigationBars["Vocabulary Packs"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["Install Pack…"].waitForExistence(timeout: 5)
                || app.buttons["Install Pack"].waitForExistence(timeout: 5),
            "Vocabulary pack install action is unavailable"
        )

        open("Settings", in: app)
        let enableSync = app.buttons["Enable iCloud Sync…"]
        XCTAssertTrue(enableSync.waitForExistence(timeout: 3))
        enableSync.tap()
        let cancel = app.buttons["Not Now"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Create Backup & Enable"].waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(enableSync.waitForExistence(timeout: 3))
    }

    func testItemTypeStudioCreatesEditsAndAtomicallySavesCardSetups() throws {
        let app = launchApp()
        openItemTypeStudioCatalog(in: app)

        app.buttons["item-types.new"].tap()
        let typeName = app.textFields["item-type-studio.name"]
        XCTAssertTrue(typeName.waitForExistence(timeout: 5))
        typeName.tap()
        typeName.typeText("Mobile Studio")
        let fieldNames = app.textFields.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "item-type-studio.field.",
                ".name"
            )
        )
        XCTAssertTrue(fieldNames.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(fieldNames.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(fieldNames.element(boundBy: 0).value as? String, "Front")
        XCTAssertEqual(fieldNames.element(boundBy: 1).value as? String, "Back")
        let moveUp = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "item-type-studio.field.",
                ".move-up"
            )
        ).element(boundBy: 1)
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(moveUp.frame.height, 44)
        XCTAssertGreaterThanOrEqual(moveUp.frame.width, 44)
        moveUp.tap()

        let firstSetup = firstCardSetupButton(in: app)
        scrollToAndTap(firstSetup, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["cardSetupEditor"].waitForExistence(timeout: 5)
        )

        let mediaAside = app.buttons["cardSetupEditor.layout.mediaAside"]
        scrollToAndTap(mediaAside, in: app)
        XCTAssertTrue(mediaAside.isSelected)

        let advanced = app.buttons["cardSetupEditor.advanced"]
        scrollToAndTap(advanced, in: app)
        let availability = app.switches["cardSetupEditor.availability"]
        scrollTo(availability, in: app)
        availability.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: availability
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        scrollToAndTap(app.buttons["Add another rule"], in: app)
        XCTAssertTrue(app.segmentedControls.buttons["All rules"].waitForExistence(timeout: 3))
        app.segmentedControls.buttons["Any rule"].tap()

        let answerMethod = app.buttons["cardSetupEditor.answerMethod"]
        scrollToAndTap(answerMethod, in: app)
        XCTAssertTrue(app.buttons["Audio Submission"].waitForExistence(timeout: 3))
        app.buttons["Audio Submission"].tap()
        XCTAssertTrue(app.buttons["Remove Answer and Continue"].waitForExistence(timeout: 3))
        app.buttons["Remove Answer and Continue"].tap()
        XCTAssertTrue(app.staticTexts["Spoken response"].waitForExistence(timeout: 3))

        // Media Aside is truthful and therefore invalid without a Media
        // component. Return to a valid static layout before the atomic save.
        let focusLayout = app.buttons["cardSetupEditor.layout.focus"]
        scrollToAndTap(focusLayout, in: app)
        XCTAssertTrue(focusLayout.isSelected)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let moreRecipes = app.buttons["itemTypeStudio.addCardSetupMenu"]
        scrollToAndTap(moreRecipes, in: app)
        XCTAssertTrue(app.buttons["Type Answer"].waitForExistence(timeout: 3))
        app.buttons["Type Answer"].tap()
        XCTAssertTrue(app.textFields["cardSetupEditor.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["cardSetupEditor.name"].value as? String, "Type Answer")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        scrollToAndTap(app.buttons["item-type-studio.save"], in: app)
        XCTAssertTrue(app.navigationBars["Item Types"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mobile Studio"].waitForExistence(timeout: 5))

        app.staticTexts["Mobile Studio"].tap()
        XCTAssertTrue(app.navigationBars["Mobile Studio"].waitForExistence(timeout: 5))
        let savedTypeAnswer = app.staticTexts["Type Answer"]
        scrollTo(savedTypeAnswer, in: app)
    }

    func testItemTypeStudioLegacyClozeReadOnlyAndDestructiveConfirmations() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "item-type-studio"])
        openItemTypeStudioCatalog(in: app)

        // Cloze is recipe-filtered: a text-only type cannot add it, then the
        // starter appears immediately after an explicit Cloze field is added.
        app.buttons["item-types.new"].tap()
        XCTAssertTrue(app.buttons["item-type-studio.save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Deck-provided · Read-only"].exists)
        scrollToAndTap(app.buttons["itemTypeStudio.addCardSetupMenu"], in: app)
        XCTAssertFalse(app.buttons["Cloze"].exists)
        XCTAssertTrue(app.buttons["Reverse"].waitForExistence(timeout: 3))
        app.buttons["Reverse"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        scrollToAndTap(app.buttons["item-type-studio.add-field"], in: app)
        let fieldTypes = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "item-type-studio.field.",
                ".type"
            )
        )
        XCTAssertGreaterThan(fieldTypes.count, 0)
        let fieldType = fieldTypes.element(boundBy: fieldTypes.count - 1)
        scrollToAndTap(fieldType, in: app)
        XCTAssertTrue(app.buttons["Cloze"].waitForExistence(timeout: 3))
        app.buttons["Cloze"].tap()

        scrollToAndTap(app.buttons["itemTypeStudio.addCardSetupMenu"], in: app)
        XCTAssertTrue(app.buttons["Cloze"].waitForExistence(timeout: 3))
        app.buttons["Cloze"].tap()
        XCTAssertTrue(app.textFields["cardSetupEditor.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["cardSetupEditor.name"].value as? String, "Cloze")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 3))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitForExistence(timeout: 5))

        let legacy = app.buttons["Studio Legacy Fixture"]
        scrollToAndTap(legacy, in: app)
        XCTAssertTrue(app.navigationBars["Studio Legacy Fixture"].waitForExistence(timeout: 5))

        let legacySetup = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Legacy Additional")
        ).firstMatch
        scrollToAndTap(legacySetup, in: app)
        let additional = app.buttons["Additional content"]
        scrollToAndTap(additional, in: app)
        XCTAssertTrue(app.staticTexts["Legacy Notes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Move into named hole"].waitForExistence(timeout: 3))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let removeNotes = app.buttons["Remove Legacy Notes"]
        scrollToAndTap(removeNotes, in: app)
        let fieldRemoval = app.sheets["Remove this field?"]
        XCTAssertTrue(fieldRemoval.waitForExistence(timeout: 3))
        XCTAssertTrue(fieldRemoval.buttons["Remove Field"].exists)
        XCTAssertTrue(fieldRemoval.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "clears mappings")
        ).firstMatch.exists)
        let keepField = fieldRemoval.buttons["Keep Field"]
        if keepField.exists {
            keepField.tap()
        } else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitForExistence(timeout: 3))
            dismissRegion.tap()
        }
        XCTAssertTrue(fieldRemoval.waitForNonExistence(timeout: 3))

        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 3))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitForExistence(timeout: 5))

        let readOnly = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Read-only Fixture, read-only")
        ).firstMatch
        XCTAssertTrue(readOnly.waitForExistence(timeout: 10))
        readOnly.tap()
        XCTAssertTrue(app.staticTexts["Deck-provided · Read-only"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["item-type-studio.save"].exists)
        app.buttons["Unlock for Editing…"].tap()
        XCTAssertTrue(app.buttons["Unlock for Editing"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Duplicate as Item Type…"].exists)

        // A stale included selection must not make a new draft read-only or
        // leave an Unlock action capable of replacing it.
        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitForExistence(timeout: 5))
        app.buttons["item-types.new"].tap()
        XCTAssertTrue(app.buttons["item-type-studio.save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Deck-provided · Read-only"].exists)
        XCTAssertFalse(app.buttons["Unlock for Editing…"].exists)

        // Even an untouched creation owns a new identity and prefilled setup,
        // so Cancel must never discard it without explicit confirmation.
        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 3))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitForExistence(timeout: 5))
    }

    func testItemTypeStudioValidationRoutesToInvalidCardSetupAndFocusesIt() throws {
        let app = launchApp()
        openItemTypeStudioCatalog(in: app)
        app.buttons["item-types.new"].tap()
        let typeName = app.textFields["item-type-studio.name"]
        XCTAssertTrue(typeName.waitForExistence(timeout: 5))
        typeName.tap()
        typeName.typeText("Focus Route")

        scrollToAndTap(app.buttons["itemTypeStudio.addCardSetupMenu"], in: app)
        XCTAssertTrue(app.buttons["Reverse"].waitForExistence(timeout: 3))
        app.buttons["Reverse"].tap()
        let setupName = app.textFields["cardSetupEditor.name"]
        clearText(in: setupName)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["item-type-studio.save"].tap()
        XCTAssertTrue(app.alerts["Finish This Item Type"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Card setup name is required."].exists)
        app.alerts["Finish This Item Type"].buttons["OK"].tap()

        let focusedSetupName = app.textFields["cardSetupEditor.name"]
        XCTAssertTrue(focusedSetupName.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 3),
            "Validation routed to the Card setup but did not focus its invalid name"
        )
    }

    @available(iOS 17.0, *)
    func testItemTypeStudioAccessibilityMatrixHasNoHorizontalOverflow() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchApp(
            additionalArguments: [
                "-NeoAnkiUITestingAccessibility",
                "-NeoAnkiUITestingCardSetupAccessibilityEditor",
            ],
            environment: ["NEOANKI_TEST_SCENARIO": "item-type-studio"]
        )

        let editor = app.descendants(matching: .any)["cardSetupEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertGreaterThanOrEqual(editor.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(editor.frame.maxX, app.frame.maxX + 1)
        assertAccessibilityTraversalOrder(
            [
                (app.textFields["cardSetupEditor.name"], .textField),
                (app.buttons["cardSetupEditor.answerMethod"], .button),
            ],
            in: editor
        )
        assertNoHorizontalOverflow(in: editor, viewport: app)
        for _ in 0..<5 {
            editor.swipeUp()
            assertNoHorizontalOverflow(in: editor, viewport: app)
        }
        for audit: XCUIAccessibilityAuditType in [
            .contrast,
            .hitRegion,
            .sufficientElementDescription,
        ] {
            try app.performAccessibilityAudit(for: audit)
        }
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
        let emptyStateScroll = app.scrollViews["emptyLibraryScroll"]
        XCTAssertTrue(emptyStateScroll.waitForExistence(timeout: 3))
        for _ in 0..<3 where !addFirstCard.isHittable {
            emptyStateScroll.swipeUp()
        }
        XCTAssertTrue(addFirstCard.isHittable)
        try app.performAccessibilityAudit(
            for: [.contrast, .hitRegion, .sufficientElementDescription]
        ) { issue in
            // SwiftUI owns the TabView/sidebar labels and reports them as contrast
            // failures in this simulated configuration. Keep all app-rendered content
            // audited.
            guard issue.auditType == .contrast,
                  let element = issue.element
            else { return false }

            let isSystemNavigationLabel = element.elementType == .staticText
                && ["Home", "Library", "Create", "Settings"].contains(element.label)
            return isSystemNavigationLabel
        }
    }
}
