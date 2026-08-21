import XCTest

@MainActor
class NeoAnki2MobileUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func launchApp(
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

    func openItemTypeStudioCatalog(in app: XCUIApplication) {
        open("Create", in: app)
        let destination = app.buttons["Item Types & Card Setups"]
        scrollToAndTap(destination, in: app)
        XCTAssertTrue(app.navigationBars["Item Types"].waitUntilExists(timeout: 10))
    }

    func scrollToAndTap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        preferredDirection: MobileScrollDirection? = nil,
        maximumSteps: Int = 8,
        acceptsPartialVisibility: Bool = false,
        bottomClearance: CGFloat = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        scrollTo(
            element,
            in: app,
            preferredDirection: preferredDirection,
            maximumSteps: maximumSteps,
            acceptsPartialVisibility: acceptsPartialVisibility,
            bottomClearance: bottomClearance,
            file: file,
            line: line
        )
        element.tap()
    }

    func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        preferredDirection: MobileScrollDirection? = nil,
        maximumSteps: Int = 8,
        acceptsPartialVisibility: Bool = false,
        bottomClearance: CGFloat = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let returnKey = keyboard.buttons["Return"]
            if returnKey.exists { returnKey.tap() }
            _ = keyboard.waitUntilGone(timeout: 2)
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
            let usableContent = CGRect(
                x: app.frame.minX,
                y: contentTop,
                width: app.frame.width,
                height: max(0, contentBottom - bottomClearance - contentTop)
            )
            if acceptsPartialVisibility {
                return frame.intersects(usableContent)
            }
            return usableContent.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        let scrollingSurface = scrollingSurface(for: element, in: app)
        let navigationBottom = app.navigationBars.allElementsBoundByIndex
            .map(\.frame.maxY)
            .max() ?? app.frame.minY
        let inferredDirection: MobileScrollDirection = if element.exists
            && element.frame.midY < navigationBottom { .towardTop } else { .towardBottom }
        let firstDirection = preferredDirection ?? inferredDirection
        let directions: [MobileScrollDirection] = [
            firstDirection,
            firstDirection == .towardBottom ? .towardTop : .towardBottom,
        ]
        for direction in directions {
            for _ in 0..<maximumSteps {
                if isReachable() { break }
                scrollOneStep(on: scrollingSurface, direction: direction)
            }
            if isReachable() { break }
        }
        XCTAssertTrue(element.waitUntilExists(timeout: 2), file: file, line: line)
        XCTAssertTrue(isReachable(), "Element is not reachable: \(element)", file: file, line: line)
    }

    enum MobileScrollDirection: Equatable {
        case towardTop
        case towardBottom
    }

    func scrollingSurface(for element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let itemTypeStudioSurface = app.descendants(matching: .any)["item-type-studio.scroll"]
        if itemTypeStudioSurface.exists,
           !itemTypeStudioSurface.frame.isEmpty,
           itemTypeStudioSurface.frame.intersects(app.frame) {
            return itemTypeStudioSurface
        }
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

    /// Use bounded short drags so tall rows are not skipped and native swipe
    /// momentum cannot continue while the next accessibility query begins.
    func scrollOneStep(on surface: XCUIElement, direction: MobileScrollDirection) {
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
        let (start, end) = switch direction {
        case .towardBottom: (lower, upper)
        case .towardTop: (upper, lower)
        }
        start.press(
            forDuration: 0.01,
            thenDragTo: end,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
    }

    func firstCardSetupButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "itemTypeStudio.cardSetup.")
        ).firstMatch
    }

    func clearText(in field: XCUIElement) {
        XCTAssertTrue(field.waitUntilExists(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        guard !current.isEmpty else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    func assertNoHorizontalOverflow(
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

    func assertAccessibilityTraversalOrder(
        _ orderedElements: [(XCUIElement, XCUIElement.ElementType)],
        in container: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let accessibilityElements = container.descendants(matching: .any)
            .allElementsBoundByAccessibilityElement
        var previousIndex = -1

        for (element, expectedType) in orderedElements {
            XCTAssertTrue(element.waitUntilExists(timeout: 5), file: file, line: line)
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

    func open(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars.firstMatch.waitUntilExists(timeout: 5), "App navigation unavailable")
        let navigationTitle = title == "Home" ? "NeoAnki2" : title
        let navigationBar = app.navigationBars[navigationTitle]
        let tabDestination = app.tabBars.buttons[title]
        let sidebarDestination = app.buttons["top-level-\(title.lowercased())"]
        XCTAssertTrue(
            waitUntil(timeout: 2, condition: {
                tabDestination.exists || sidebarDestination.exists
            }),
            "Top-level destination is unavailable: \(title)"
        )
        let destination = tabDestination.exists
            ? tabDestination
            : sidebarDestination

        for _ in 0..<3 {
            guard destination.waitUntilExists(timeout: 5) else { continue }
            if destination.isSelected { return }
            destination.tap()
            if waitUntil(timeout: 5, condition: {
                destination.isSelected && navigationBar.exists
            }) {
                return
            }
        }

        XCTFail("Failed to open \(title) destination")
    }

    @available(iOS 17.0, *)
    func launchItemTypeStudioAuditApp(section: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeRight
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }
        var arguments = [
            "-NeoAnkiUITestingAccessibility",
            "-NeoAnkiUITestingCardSetupAccessibilityEditor",
        ]
        if let section {
            arguments += [
                "-NeoAnkiUITestingCardSetupAccessibilitySection",
                section,
            ]
        }
        return launchApp(
            additionalArguments: arguments,
            environment: ["NEOANKI_TEST_SCENARIO": "item-type-studio"]
        )
    }

    @available(iOS 17.0, *)
    func assertItemTypeStudioAuditSection(
        _ section: String,
        realElementType: XCUIElement.ElementType,
        realElementLabel: String,
        description: String
    ) throws {
        let app = launchItemTypeStudioAuditApp(section: section)
        let editor = app.descendants(matching: .any)["cardSetupEditor"]
        XCTAssertTrue(editor.waitUntilExists(timeout: 15))
        let marker = app.descendants(matching: .any)[
            "cardSetupEditor.auditSection.\(section)"
        ]
        XCTAssertTrue(
            waitUntil(timeout: 5, condition: {
                // The gated host mounts this marker with the requested real
                // section before the complete, natively scrolling editor.
                // Landscape XCTest rotates frames even when rendering is
                // correct, so the real control is asserted separately.
                marker.exists
            }),
            "Audit navigation did not reveal \(description)"
        )
        XCTAssertTrue(
            app.descendants(matching: realElementType)[realElementLabel]
                .firstMatch.waitUntilExists(timeout: 5),
            "Audit section did not render its real \(description) control"
        )
        assertNoHorizontalOverflow(in: editor, viewport: app)
        // One combined audit traverses the accessibility tree once. Running
        // each audit kind separately triples this cost without adding coverage.
        try app.performAccessibilityAudit(
            for: [.contrast, .hitRegion, .sufficientElementDescription]
        )
    }
}

@MainActor
final class MobileNavigationUITests: NeoAnki2MobileUITestCase {
    func testTopLevelProductNavigation() throws {
        let app = launchApp()
        for title in ["Home", "Library", "Create", "Settings"] {
            open(title, in: app)
            let navigationTitle = title == "Home" ? "NeoAnki2" : title
            XCTAssertTrue(app.navigationBars[navigationTitle].waitUntilExists(timeout: 3))
        }
    }
}

@MainActor
final class MobileDeckUITests: NeoAnki2MobileUITestCase {
    func testDeckCreateRenameAndDeleteJourney() throws {
        let app = launchApp()
        open("Create", in: app)
        app.buttons["New Deck"].tap()
        let name = app.textFields["e.g. Spanish vocabulary"]
        XCTAssertTrue(name.waitUntilExists(timeout: 3))
        name.tap(); name.typeText("Reading")
        app.buttons["new-deck-create"].tap()

        open("Home", in: app)
        XCTAssertTrue(app.staticTexts["Reading"].waitUntilExists(timeout: 5))
        app.staticTexts["Reading"].tap()
        app.buttons["Deck Settings"].tap()
        let editor = app.textFields["Name"]
        XCTAssertTrue(editor.waitUntilExists(timeout: 3))
        editor.tap()
        editor.typeText(" Essays")
        app.buttons["Save"].tap()
        XCTAssertTrue(
            app.navigationBars["Reading Essays"].waitUntilExists(timeout: 10),
            "Renamed deck did not become visible after saving"
        )

        app.buttons["Deck Settings"].tap()
        app.buttons["Delete Deck"].tap()
        app.buttons["Delete and Unassign Items"].tap()
        XCTAssertTrue(
            app.staticTexts["Reading Essays"].waitUntilGone(timeout: 10),
            "Deleted deck remained visible"
        )
    }
}

@MainActor
final class MobileCardJourneyUITests: NeoAnki2MobileUITestCase {
    func testCreateBrowseAndStudyBasicCardJourney() throws {
        let app = launchApp()
        open("Create", in: app)
        app.buttons["New Item"].tap()

        let front = app.textFields["add-card-field-front"]
        let back = app.textFields["add-card-field-back"]
        XCTAssertTrue(front.waitUntilExists(timeout: 5))
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
        XCTAssertTrue(itemLink.waitUntilExists(timeout: 5))
        itemLink.tap()
        XCTAssertTrue(app.staticTexts["Paris"].waitUntilExists(timeout: 5))

        open("Home", in: app)
        let start = app.buttons["Start Studying"]
        XCTAssertTrue(start.waitUntilExists(timeout: 5))
        start.tap()
        let reveal = app.buttons["Show Answer"]
        XCTAssertTrue(reveal.waitUntilExists(timeout: 15))
        reveal.tap()
        XCTAssertTrue(app.staticTexts["Paris"].waitUntilExists(timeout: 5))
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Session Complete"].waitUntilExists(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["NeoAnki2"].waitUntilExists(timeout: 5))
    }
}

@MainActor
final class MobileAuthoringSurfaceUITests: NeoAnki2MobileUITestCase {
    func testAuthoringTransferVocabularyAndSyncConsentSurfaces() throws {
        let app = launchApp()
        open("Create", in: app)
        for title in ["Item Types & Card Setups", "Import or Export", "Deck Builders", "Vocabulary Packs"] {
            XCTAssertTrue(app.buttons[title].waitUntilExists(timeout: 3), "Missing \(title)")
        }
        app.buttons["Vocabulary Packs"].tap()
        XCTAssertTrue(app.navigationBars["Vocabulary Packs"].waitUntilExists(timeout: 3))
        XCTAssertTrue(
            waitUntil(timeout: 5, condition: {
                app.buttons["Install Pack…"].exists
                    || app.buttons["Install Pack"].exists
            }),
            "Vocabulary pack install action is unavailable"
        )

        open("Settings", in: app)
        let enableSync = app.buttons["Enable iCloud Sync…"]
        XCTAssertTrue(enableSync.waitUntilExists(timeout: 3))
        enableSync.tap()
        let cancel = app.buttons["Not Now"]
        XCTAssertTrue(cancel.waitUntilExists(timeout: 3))
        XCTAssertTrue(app.buttons["Create Backup & Enable"].waitUntilExists(timeout: 5))
        cancel.tap()
        XCTAssertTrue(enableSync.waitUntilExists(timeout: 3))
    }
}

@MainActor
final class MobileStudioAuthoringUITests: NeoAnki2MobileUITestCase {
    func testItemTypeStudioCreatesEditsAndAtomicallySavesCardSetups() throws {
        let app = launchApp()
        openItemTypeStudioCatalog(in: app)

        app.buttons["item-types.new"].tap()
        let typeName = app.textFields["item-type-studio.name"]
        XCTAssertTrue(typeName.waitUntilExists(timeout: 5))
        typeName.tap()
        typeName.typeText("Mobile Studio")
        let fieldNames = app.textFields.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "item-type-studio.field.",
                ".name"
            )
        )
        XCTAssertTrue(fieldNames.element(boundBy: 0).waitUntilExists(timeout: 5))
        XCTAssertTrue(fieldNames.element(boundBy: 1).waitUntilExists(timeout: 5))
        XCTAssertEqual(fieldNames.element(boundBy: 0).value as? String, "Front")
        XCTAssertEqual(fieldNames.element(boundBy: 1).value as? String, "Back")
        let moveUp = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "item-type-studio.field.",
                ".move-up"
            )
        ).element(boundBy: 1)
        XCTAssertTrue(moveUp.waitUntilExists(timeout: 5))
        XCTAssertGreaterThanOrEqual(moveUp.frame.height, 44)
        XCTAssertGreaterThanOrEqual(moveUp.frame.width, 44)
        moveUp.tap()

        let firstSetup = firstCardSetupButton(in: app)
        scrollToAndTap(firstSetup, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["cardSetupEditor"].waitUntilExists(timeout: 5)
        )

        let mediaAside = app.buttons["cardSetupEditor.layout.mediaAside"]
        scrollToAndTap(mediaAside, in: app)
        XCTAssertTrue(mediaAside.isSelected)

        let advanced = app.buttons["cardSetupEditor.advanced"]
        scrollToAndTap(advanced, in: app)
        let availability = app.switches["cardSetupEditor.availability"]
        scrollTo(availability, in: app, bottomClearance: 80)
        XCTAssertGreaterThanOrEqual(availability.frame.height, 44)
        // Use XCTest's semantic switch activation. Coordinate taps can land
        // on the row hit region after SwiftUI relayout and leave the value
        // unchanged even though the control is hittable.
        availability.tap()
        XCTAssertTrue(waitUntil(timeout: 3, condition: {
            switch availability.value {
            case let value as Bool:
                value
            case let value as NSNumber:
                value.boolValue
            case let value as String:
                value == "1" || value.caseInsensitiveCompare("on") == .orderedSame
            default:
                false
            }
        }))
        scrollToAndTap(app.buttons["Add another rule"], in: app)
        XCTAssertTrue(app.segmentedControls.buttons["All rules"].waitUntilExists(timeout: 3))
        app.segmentedControls.buttons["Any rule"].tap()

        let answerMethod = app.buttons["cardSetupEditor.answerMethod"]
        scrollToAndTap(answerMethod, in: app, preferredDirection: .towardTop)
        XCTAssertTrue(app.buttons["Audio Submission"].waitUntilExists(timeout: 3))
        app.buttons["Audio Submission"].tap()
        XCTAssertTrue(app.buttons["Remove Answer and Continue"].waitUntilExists(timeout: 3))
        app.buttons["Remove Answer and Continue"].tap()
        XCTAssertTrue(app.staticTexts["Spoken response"].waitUntilExists(timeout: 3))

        // Media Aside is truthful and therefore invalid without a Media
        // component. Return to a valid static layout before the atomic save.
        let focusLayout = app.buttons["cardSetupEditor.layout.focus"]
        scrollToAndTap(focusLayout, in: app)
        XCTAssertTrue(focusLayout.isSelected)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let moreRecipes = app.buttons["itemTypeStudio.addCardSetupMenu"]
        scrollToAndTap(moreRecipes, in: app)
        XCTAssertTrue(app.buttons["Type Answer"].waitUntilExists(timeout: 3))
        app.buttons["Type Answer"].tap()
        XCTAssertTrue(app.textFields["cardSetupEditor.name"].waitUntilExists(timeout: 5))
        XCTAssertEqual(app.textFields["cardSetupEditor.name"].value as? String, "Type Answer")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        scrollToAndTap(app.buttons["item-type-studio.save"], in: app)
        XCTAssertTrue(app.navigationBars["Item Types"].waitUntilExists(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mobile Studio"].waitUntilExists(timeout: 5))

        app.staticTexts["Mobile Studio"].tap()
        XCTAssertTrue(app.navigationBars["Mobile Studio"].waitUntilExists(timeout: 5))
        let savedTypeAnswer = app.staticTexts["Type Answer"]
        scrollTo(savedTypeAnswer, in: app)
    }
}

@MainActor
final class MobileStudioLegacyUITests: NeoAnki2MobileUITestCase {
    func testItemTypeStudioLegacyClozeReadOnlyAndDestructiveConfirmations() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "item-type-studio"])
        openItemTypeStudioCatalog(in: app)

        // Cloze is recipe-filtered: a text-only type cannot add it, then the
        // starter appears immediately after an explicit Cloze field is added.
        app.buttons["item-types.new"].tap()
        XCTAssertTrue(app.buttons["item-type-studio.save"].waitUntilExists(timeout: 5))
        XCTAssertFalse(app.staticTexts["Deck-provided · Read-only"].exists)
        scrollToAndTap(app.buttons["itemTypeStudio.addCardSetupMenu"], in: app)
        XCTAssertFalse(app.buttons["Cloze"].exists)
        XCTAssertTrue(app.buttons["Reverse"].waitUntilExists(timeout: 3))
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
        XCTAssertTrue(app.buttons["Cloze"].waitUntilExists(timeout: 3))
        app.buttons["Cloze"].tap()

        scrollToAndTap(app.buttons["itemTypeStudio.addCardSetupMenu"], in: app)
        XCTAssertTrue(app.buttons["Cloze"].waitUntilExists(timeout: 3))
        app.buttons["Cloze"].tap()
        XCTAssertTrue(app.textFields["cardSetupEditor.name"].waitUntilExists(timeout: 5))
        XCTAssertEqual(app.textFields["cardSetupEditor.name"].value as? String, "Cloze")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitUntilExists(timeout: 3))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitUntilExists(timeout: 5))

        let legacy = app.buttons["Studio Legacy Fixture"]
        scrollToAndTap(legacy, in: app)
        XCTAssertTrue(app.navigationBars["Studio Legacy Fixture"].waitUntilExists(timeout: 5))

        let legacySetup = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Legacy Additional")
        ).firstMatch
        scrollToAndTap(legacySetup, in: app)
        let additional = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "cardSetupEditor.additionalContent",
                "Additional content"
            )
        ).firstMatch
        scrollToAndTap(additional, in: app)
        XCTAssertTrue(app.staticTexts["Legacy Notes"].waitUntilExists(timeout: 3))
        XCTAssertTrue(app.buttons["Move into named hole"].waitUntilExists(timeout: 3))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let removeNotes = app.buttons["Remove Legacy Notes"]
        scrollToAndTap(removeNotes, in: app)
        let fieldRemoval = app.sheets["Remove this field?"]
        XCTAssertTrue(fieldRemoval.waitUntilExists(timeout: 3))
        XCTAssertTrue(fieldRemoval.buttons["Remove Field"].exists)
        XCTAssertTrue(fieldRemoval.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "clears mappings")
        ).firstMatch.exists)
        let keepField = fieldRemoval.buttons["Keep Field"]
        if keepField.exists {
            keepField.tap()
        } else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitUntilExists(timeout: 3))
            dismissRegion.tap()
        }
        XCTAssertTrue(fieldRemoval.waitUntilGone(timeout: 3))

        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitUntilExists(timeout: 3))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitUntilExists(timeout: 5))

        let readOnly = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Read-only Fixture, read-only")
        ).firstMatch
        XCTAssertTrue(readOnly.waitUntilExists(timeout: 10))
        readOnly.tap()
        XCTAssertTrue(app.staticTexts["Deck-provided · Read-only"].waitUntilExists(timeout: 5))
        XCTAssertFalse(app.buttons["item-type-studio.save"].exists)
        app.buttons["Unlock for Editing…"].tap()
        XCTAssertTrue(app.buttons["Unlock for Editing"].waitUntilExists(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Duplicate as Item Type…"].exists)

        // A stale included selection must not make a new draft read-only or
        // leave an Unlock action capable of replacing it.
        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitUntilExists(timeout: 5))
        app.buttons["item-types.new"].tap()
        XCTAssertTrue(app.buttons["item-type-studio.save"].waitUntilExists(timeout: 5))
        XCTAssertFalse(app.staticTexts["Deck-provided · Read-only"].exists)
        XCTAssertFalse(app.buttons["Unlock for Editing…"].exists)

        // Even an untouched creation owns a new identity and prefilled setup,
        // so Cancel must never discard it without explicit confirmation.
        app.buttons["item-type-studio.cancel"].tap()
        XCTAssertTrue(app.buttons["Discard"].waitUntilExists(timeout: 3))
        app.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Item Types"].waitUntilExists(timeout: 5))
    }
}

@MainActor
final class MobileStudioValidationUITests: NeoAnki2MobileUITestCase {
    func testItemTypeStudioValidationRoutesToInvalidCardSetupAndFocusesIt() throws {
        let app = launchApp()
        openItemTypeStudioCatalog(in: app)
        app.buttons["item-types.new"].tap()
        let typeName = app.textFields["item-type-studio.name"]
        XCTAssertTrue(typeName.waitUntilExists(timeout: 5))
        typeName.tap()
        typeName.typeText("Focus Route")

        scrollToAndTap(app.buttons["itemTypeStudio.addCardSetupMenu"], in: app)
        XCTAssertTrue(app.buttons["Reverse"].waitUntilExists(timeout: 3))
        app.buttons["Reverse"].tap()
        let setupName = app.textFields["cardSetupEditor.name"]
        clearText(in: setupName)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["item-type-studio.save"].tap()
        XCTAssertTrue(app.alerts["Finish This Item Type"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["Card setup name is required."].exists)
        app.alerts["Finish This Item Type"].buttons["OK"].tap()

        let focusedSetupName = app.textFields["cardSetupEditor.name"]
        XCTAssertTrue(focusedSetupName.waitUntilExists(timeout: 5))
        XCTAssertTrue(
            app.keyboards.firstMatch.waitUntilExists(timeout: 3),
            "Validation routed to the Card setup but did not focus its invalid name"
        )
    }
}

@MainActor
final class MobileStudioCanvasAccessibilityUITests: NeoAnki2MobileUITestCase {
    @available(iOS 17.0, *)
    func testItemTypeStudioAccessibilityMatrixHasNoHorizontalOverflow() throws {
        let app = launchItemTypeStudioAuditApp()
        let editor = app.descendants(matching: .any)["cardSetupEditor"]
        XCTAssertTrue(editor.waitUntilExists(timeout: 15))
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
    }

    @available(iOS 17.0, *)
    func testItemTypeStudioPreviewAccessibility() throws {
        try assertItemTypeStudioAuditSection(
            "preview",
            realElementType: .staticText,
            realElementLabel: "Preview",
            description: "Preview"
        )
    }
}

@MainActor
final class MobileStudioInspectorAccessibilityUITests: NeoAnki2MobileUITestCase {
    @available(iOS 17.0, *)
    func testItemTypeStudioAdditionalContentAccessibility() throws {
        try assertItemTypeStudioAuditSection(
            "additional",
            realElementType: .button,
            realElementLabel: "Edit source, Legacy Notes",
            description: "legacy Additional content"
        )
    }

    @available(iOS 17.0, *)
    func testItemTypeStudioAdvancedAccessibility() throws {
        try assertItemTypeStudioAuditSection(
            "advanced",
            realElementType: .button,
            realElementLabel: "Advanced",
            description: "Advanced"
        )
    }
}

@MainActor
final class MobileStudioAdvancedAccessibilityUITests: NeoAnki2MobileUITestCase {
    @available(iOS 17.0, *)
    func testItemTypeStudioAvailabilityAccessibility() throws {
        try assertItemTypeStudioAuditSection(
            "availability",
            realElementType: .switch,
            realElementLabel: "Availability rule",
            description: "Availability"
        )
    }

    @available(iOS 17.0, *)
    func testItemTypeStudioLearningRouteAccessibility() throws {
        try assertItemTypeStudioAuditSection(
            "learningRoute",
            realElementType: .staticText,
            realElementLabel: "Learning route",
            description: "Learning route"
        )
    }
}

@MainActor
final class MobileFirstScreenAccessibilityUITests: NeoAnki2MobileUITestCase {
    @available(iOS 17.0, *)
    func testFirstScreenAccessibilityAudit() throws {
        let app = launchApp()
        XCTAssertTrue(
            waitUntil(timeout: 5, condition: {
                app.tabBars.firstMatch.exists
                    || app.buttons["Home"].firstMatch.exists
            })
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
        XCTAssertTrue(app.navigationBars["Library"].waitUntilExists(timeout: 5))
        let addFirstCard = app.buttons["Add First Card"]
        XCTAssertTrue(addFirstCard.waitUntilExists(timeout: 5))
        let emptyStateScroll = app.scrollViews["emptyLibraryScroll"]
        XCTAssertTrue(emptyStateScroll.waitUntilExists(timeout: 3))
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

/// XCTest's native existence waits poll on a coarse cadence. UI journeys make
/// many already-satisfied synchronization checks, so evaluate immediately and
/// then use a short run-loop cadence while preserving the original timeout as
/// the failure budget.
private let mobilePollInterval: TimeInterval = 0.03

extension XCUIElement {
    @discardableResult
    func waitUntilExists(timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { $0.exists }
    }

    @discardableResult
    func waitUntilGone(timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !$0.exists }
    }

    func waitUntil(timeout: TimeInterval, condition: (XCUIElement) -> Bool) -> Bool {
        if condition(self) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(mobilePollInterval))
            if condition(self) { return true }
        }
        return condition(self)
    }
}

extension NeoAnki2MobileUITestCase {
    @discardableResult
    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(mobilePollInterval))
            if condition() { return true }
        }
        return condition()
    }
}
