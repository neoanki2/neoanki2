import XCTest
import NeoAnkiCore
@testable import NeoAnkiMobile

@MainActor
class NeoAnki2MobileUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "App icon badge permission") { alert in
            MainActor.assumeIsolated {
                guard Self.isBadgePermissionAlert(alert) else { return false }
                alert.buttons["Allow"].tap()
                return true
            }
        }
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() {
        let description = MainActor.assumeIsolated { XCUIApplication().debugDescription }
        let tree = XCTAttachment(string: description)
        tree.name = "End accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
        super.tearDown()
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
        // Populated fixtures can request badges during bootstrap, before the
        // first app gesture can trigger an interruption monitor.
        if environment["NEOANKI_TEST_SCENARIO"] == "mobile-redesign" {
            allowBadgePermissionIfPresented(timeout: 10)
        }
        return app
    }

    private static func isBadgePermissionAlert(_ alert: XCUIElement) -> Bool {
        alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "NeoAnki2", "Notifications"
        )).firstMatch.exists && alert.buttons["Allow"].exists
    }

    func allowBadgePermissionIfPresented(timeout: TimeInterval = 5) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitUntilExists(timeout: timeout), Self.isBadgePermissionAlert(alert) {
            alert.buttons["Allow"].tap()
        }
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
        func isReachable() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            let navigationBars = app.navigationBars.allElementsBoundByIndex
            if navigationBars.contains(where: { $0.frame.contains(frame) }) {
                return true
            }
            let contentTop = navigationBars.map(\.frame.maxY).max() ?? app.frame.minY
            let tabBar = app.tabBars.firstMatch
            let contentBottom = tabBar.exists && tabBar.isHittable && tabBar.frame.minY > app.frame.midY
                ? tabBar.frame.minY : app.frame.maxY
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

    func auditVisibleContent(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription]) { issue in
            let diagnostic = XCTAttachment(string: "\(issue.auditType): \(issue.element?.debugDescription ?? "No element")")
            diagnostic.name = "Audit failure element"
            diagnostic.lifetime = .keepAlways
            self.add(diagnostic)
            guard issue.auditType == .contrast, let element = issue.element,
                  element.elementType == .staticText,
                  ["Front", "Back", "Legacy Notes", "Preview", "Practice type: what do you remember?", "Paris", "Correct"].contains(element.label),
                  let scroll = app.scrollViews.allElementsBoundByIndex.first(where: { scroll in
                      scroll.staticTexts.matching(NSPredicate(format: "label == %@", element.label))
                          .allElementsBoundByIndex.contains { $0.frame == element.frame }
                  })
            else { return false }
            // XCTest samples identified fixture text outside its scrolling
            // viewport. Pixel contrast there is undefined. Re-audit the real
            // question after scrolling it into view; never exclude controls,
            // horizontal overflow, or fully visible text.
            var visible = app.windows.firstMatch.frame.intersection(scroll.frame)
            let bottom = visible.maxY
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable)
                .map(\.frame.maxY).max() ?? visible.minY
            visible.origin.y = max(visible.minY, top)
            visible.size.height = max(0, bottom - visible.minY)
            let frame = element.frame
            let horizontallyContained = frame.minX >= visible.minX && frame.maxX <= visible.maxX
            let verticallyClipped = frame.minY < visible.minY || frame.maxY > visible.maxY
            return !frame.isEmpty && horizontallyContained && verticallyClipped

        }
    }

    enum MobileScrollDirection: Equatable {
        case towardTop
        case towardBottom
    }

    func scrollingSurface(for element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        // Navigation can remove a surface between query evaluation and filtering.
        // Bind to its accessibility identity so a shifting index cannot resolve
        // to a different surface, and ignore identities that already disappeared.
        let candidates = (
            app.scrollViews.allElementsBoundByAccessibilityElement
                + app.collectionViews.allElementsBoundByAccessibilityElement
        ).filter { candidate in
            candidate.exists
                && candidate.label != "Sidebar"
                && candidate.isHittable
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
                // Native Form background containers bleed beyond the scroll
                // viewport. Measure controls, text, images, and named groups.
                && !($0.elementType == .other && $0.identifier.isEmpty && $0.label.isEmpty)
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
        let tabDestination = app.tabBars.buttons[title]
        let sidebarDestination = app.buttons["top-level-\(title.lowercased())"]
        XCTAssertTrue(
            waitUntil(timeout: 2, condition: {
                tabDestination.exists || sidebarDestination.exists
            }),
            "Top-level destination is unavailable: \(title)"
        )
        if sidebarDestination.exists {
            XCTAssertFalse(app.tabBars.firstMatch.exists, "iPad must have one top-level navigation surface")
        }
        let destination = sidebarDestination.exists
            ? sidebarDestination
            : tabDestination

        for _ in 0..<3 {
            guard destination.waitUntilExists(timeout: 5) else { continue }
            if destination.isSelected { return }
            destination.tap()
            if waitUntil(timeout: 5, condition: {
                destination.isSelected && app.navigationBars.firstMatch.exists
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
        XCTAssertTrue(waitUntil(timeout: 5) {
            let frame = app.windows.firstMatch.frame
            guard frame.width > frame.height, abs(frame.minX) < 1, abs(frame.minY) < 1 else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            return app.windows.firstMatch.frame == frame
        })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
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
        try auditVisibleContent(in: app)
        if section == "preview" {
            let question = app.buttons["Front"].firstMatch
            let scroll = app.scrollViews["cardSetupEditor"]
            for _ in 0..<12 {
                let viewport = app.windows.firstMatch.frame
                let top = app.navigationBars.firstMatch.frame.maxY
                let frame = question.frame
                if question.isHittable && frame.minY >= top && frame.maxY <= viewport.maxY { break }
                let upper = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                let lower = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                let movesTowardTop = frame.minY < top
                (movesTowardTop ? upper : lower).press(forDuration: 0.01,
                    thenDragTo: movesTowardTop ? lower : upper,
                    withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            let diagnostic = XCTAttachment(string: app.debugDescription)
            diagnostic.name = "Scrolled preview accessibility tree"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            XCTAssertTrue(question.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(question.frame))
            try auditVisibleContent(in: app)
        }
    }
}

@MainActor
final class MobileNavigationUITests: NeoAnki2MobileUITestCase {
    func testTopLevelProductNavigation() throws {
        let app = launchApp()
        for title in ["Home", "Library", "Create", "Settings"] {
            open(title, in: app)
            let navigationTitle = title
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
        XCTAssertFalse(app.staticTexts["Paris"].exists, "Concealed answer leaked into Library")
        itemLink.tap()
        XCTAssertTrue(app.navigationBars["Basic"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].exists)
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
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 5))
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
        let fieldSummaries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "item-type-studio.field.", ".summary"))
        XCTAssertEqual(fieldSummaries.count, 2)
        scrollToAndTap(fieldSummaries.element(boundBy: 1), in: app)
        XCTAssertTrue(app.navigationBars["Edit Field"].waitUntilExists(timeout: 5))
        let fieldName = app.textFields.matching(NSPredicate(format: "identifier ENDSWITH %@", ".name")).firstMatch
        XCTAssertEqual(fieldName.value as? String, "Back")
        let moveUp = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".move-up")).firstMatch
        XCTAssertGreaterThanOrEqual(moveUp.frame.height, 44)
        moveUp.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let firstSetup = firstCardSetupButton(in: app)
        scrollToAndTap(firstSetup, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["cardSetupEditor"].waitUntilExists(timeout: 5)
        )

        scrollToAndTap(app.buttons["Layout, Focus"], in: app)
        let mediaAside = app.buttons["cardSetupEditor.layout.mediaAside"]
        scrollToAndTap(mediaAside, in: app)
        XCTAssertTrue(mediaAside.isSelected)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        scrollToAndTap(app.buttons["Availability"], in: app)
        XCTAssertTrue(app.navigationBars["Availability"].waitUntilExists(timeout: 5))
        let availability = app.switches["cardSetupEditor.availability"]
        scrollTo(availability, in: app, bottomClearance: 80)
        XCTAssertGreaterThanOrEqual(availability.frame.height, 44)
        // Activate the native switch itself within its labeled row.
        availability.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
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

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let answerMethod = app.buttons["cardSetupEditor.answerMethod"]
        scrollToAndTap(answerMethod, in: app, preferredDirection: .towardTop)
        XCTAssertTrue(app.buttons["Audio Submission"].waitUntilExists(timeout: 3))
        app.buttons["Audio Submission"].tap()
        XCTAssertTrue(app.buttons["Remove Answer and Continue"].waitUntilExists(timeout: 3))
        app.buttons["Remove Answer and Continue"].tap()
        XCTAssertTrue(app.buttons["cardSetupEditor.answerMethod"].label.contains("Audio Submission"))

        // Media Aside is truthful and therefore invalid without a Media
        // component. Return to a valid static layout before the atomic save.
        scrollToAndTap(app.buttons["Layout, Media Aside"], in: app)
        let focusLayout = app.buttons["cardSetupEditor.layout.focus"]
        scrollToAndTap(focusLayout, in: app)
        XCTAssertTrue(focusLayout.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()

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
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".summary")).count == 3 })
        let newField = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".summary")).allElementsBoundByIndex.last!
        scrollToAndTap(newField, in: app)
        XCTAssertTrue(app.navigationBars["Edit Field"].waitUntilExists(timeout: 5))
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
        app.navigationBars.buttons.element(boundBy: 0).tap()

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
        scrollToAndTap(app.buttons["Edit Content"], in: app)
        let additional = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "cardSetupEditor.additionalContent",
                "Additional content"
            )
        ).firstMatch
        scrollToAndTap(additional, in: app)
        let legacySource = app.buttons["Edit source, Legacy Notes"]
        scrollTo(legacySource, in: app)
        XCTAssertTrue(legacySource.waitUntilExists(timeout: 3))
        scrollTo(app.buttons["Move into named hole"], in: app)
        XCTAssertTrue(app.buttons["Move into named hole"].isHittable)
        let legacyScreenshot = XCTAttachment(screenshot: app.screenshot())
        legacyScreenshot.name = "57-focused-legacy-content"
        legacyScreenshot.lifetime = .keepAlways
        add(legacyScreenshot)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let notesSummary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Legacy Notes")).firstMatch
        scrollToAndTap(notesSummary, in: app)
        let removeNotes = app.buttons["Remove Field"]
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
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Inspecting content and canceling field removal leaves this definition
        // unchanged, so Cancel returns directly to the catalog.
        app.buttons["item-type-studio.cancel"].tap()
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
        // The shipping mobile Form lazily mounts its sections. Bring the
        // focused controls into view before inspecting their traversal order.
        let name = app.textFields["cardSetupEditor.name"]
        let method = app.buttons["cardSetupEditor.answerMethod"]
        scrollTo(name, in: app)
        assertAccessibilityTraversalOrder([(name, .textField)], in: editor)
        assertNoHorizontalOverflow(in: editor, viewport: app)
        scrollTo(method, in: app)
        // At the largest size on a compact phone, the earlier name row may
        // unmount. Its visible traversal was checked before scrolling. Keep
        // the relative-order assertion whenever both rows remain mounted.
        assertAccessibilityTraversalOrder(
            name.exists ? [(name, .textField), (method, .button)] : [(method, .button)],
            in: editor
        )
        assertNoHorizontalOverflow(in: editor, viewport: app)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "74-largest-card-setup-controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "74-largest-card-setup-controls-tree"
        tree.lifetime = .keepAlways
        add(tree)
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
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription]) { issue in
            let diagnostic = XCTAttachment(string: "\(issue.auditType): \(issue.element?.debugDescription ?? "No element")")
            diagnostic.name = "Audit failure element"
            diagnostic.lifetime = .keepAlways
            self.add(diagnostic)
            return false
        }
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
        let addFirstCard = app.buttons["Add First Item"]
        scrollTo(addFirstCard, in: app)
        let emptyStateScroll = app.collectionViews.firstMatch
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

@MainActor
final class MobileAppStoreScreenshotUITests: NeoAnki2MobileUITestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "appstore-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureAppStoreScreenshots() throws {
        // This reset is safe only on the disposable Simulator created by the
        // release screenshot command. No personal library is used or copied.
        let app = launchApp()
        for (frontText, backText) in [
            ("What is spaced repetition?", "Reviewing information at increasing intervals to strengthen long-term memory."),
            ("Capital of France?", "Paris"),
            ("How do you say thank you in Spanish?", "Gracias"),
            ("What is active recall?", "Retrieving an answer from memory before checking it.")
        ] {
            open("Create", in: app)
            app.buttons["New Item"].tap()
            let front = app.textFields["add-card-field-front"]
            XCTAssertTrue(front.waitUntilExists(timeout: 5))
            front.tap()
            front.typeText(frontText)
            let back = app.textFields["add-card-field-back"]
            back.tap()
            back.typeText(backText)
            if frontText == "What is active recall?" { capture("04-authoring") }
            app.buttons["add-card-save"].tap()
        }
        open("Library", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "What is spaced")).firstMatch.waitUntilExists(timeout: 5))
        capture("01-library")
        open("Home", in: app)
        app.buttons["Start Studying"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 15))
        capture("02-study-question")
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.buttons["Good"].waitUntilExists(timeout: 5))
        capture("03-study-answer")
        app.buttons["endStudySession"].tap()
        open("Settings", in: app)
        let privacy = app.descendants(matching: .any)["mobilePrivacyPolicy"]
        scrollTo(privacy, in: app)
        XCTAssertTrue(privacy.exists)
        XCTAssertTrue(app.descendants(matching: .any)["mobileSupport"].exists)
        capture("05-settings")
    }
}

/// Run alone on a newly created Simulator. Unlike fixture-based acceptance,
/// this follows the normal Release launch path, including UIKit animations.
@MainActor
final class MobileProductionReviewJourneyUITests: NeoAnki2MobileUITestCase {
    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "production-review-" + name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "production-review-" + name + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testCleanInstallCreateStudyAndPersistenceWithoutFixtures() throws {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 15))
        XCTAssertTrue(app.buttons["Add First Item"].waitUntilExists(timeout: 5),
                      "This review must start with an empty, newly installed library")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Normal launch must not request optional permissions")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
                       "Normal launch must not request system permissions")
        capture("01-clean-home", in: app)

        open("Settings", in: app)
        XCTAssertTrue(app.buttons["Enable iCloud Sync…"].waitUntilExists(timeout: 5),
                      "A new installation must leave optional iCloud sync disabled")
        XCTAssertFalse(app.buttons["Sync Now"].isEnabled)
        XCTAssertEqual(app.switches["Remind me"].value as? String, "0")
        let privacy = app.descendants(matching: .any)["mobilePrivacyPolicy"]
        scrollTo(privacy, in: app)
        XCTAssertTrue(privacy.exists)
        XCTAssertTrue(app.descendants(matching: .any)["mobileSupport"].exists)
        capture("02-default-settings", in: app)

        open("Home", in: app)
        app.buttons["Add First Item"].tap()
        let front = app.textFields["add-card-field-front"]
        let back = app.textFields["add-card-field-back"]
        XCTAssertTrue(front.waitUntilExists(timeout: 5))
        front.tap(); front.typeText("Production review question")
        back.tap(); back.typeText("Production review answer")
        let save = app.buttons["add-card-save"]
        XCTAssertTrue(save.isEnabled)
        capture("03-first-item-authoring", in: app)
        save.tap()
        allowBadgePermissionIfPresented()
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 10))
        let start = app.buttons["Start Studying"]
        XCTAssertTrue(start.waitUntilExists(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 15))
        XCTAssertTrue(app.staticTexts["Production review question"].exists)
        XCTAssertFalse(app.staticTexts["Production review answer"].exists,
                       "The normal study question must conceal its answer")
        capture("04-study-question", in: app)
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.staticTexts["Production review answer"].waitUntilExists(timeout: 5))
        capture("05-study-answer", in: app)
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Session Complete"].waitUntilExists(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 15))
        XCTAssertFalse(app.buttons["Add First Item"].exists,
                       "A normal relaunch must preserve the first item")
        open("Library", in: app)
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Production review question")).firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5))
        XCTAssertFalse(app.staticTexts["Production review answer"].exists,
                       "Concealment must remain enabled after a normal relaunch")
        item.tap()
        XCTAssertTrue(app.staticTexts["Production review answer"].waitUntilExists(timeout: 5))
        capture("06-persisted-item", in: app)
        open("Settings", in: app)
        XCTAssertTrue(app.buttons["Enable iCloud Sync…"].waitUntilExists(timeout: 5))
        XCTAssertEqual(app.switches["Remind me"].value as? String, "0")
    }
}

@MainActor
final class MobileVisualRedesignUITests: NeoAnki2MobileUITestCase {
    func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
    func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    func testManagementScreenInventory() throws {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 15))
        capture("01-home-empty", app)
        open("Library", in: app); capture("02-library-empty", app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved Responses")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Saved Responses"].waitUntilExists(timeout: 5))
        capture("03-responses-empty", app)
        open("Create", in: app); capture("04-create", app)
        app.buttons["New Item"].tap()
        XCTAssertTrue(app.textFields["add-card-field-front"].waitUntilExists(timeout: 5))
        capture("05-add-item", app); app.buttons["Cancel"].tap()
        app.buttons["New Deck"].tap()
        XCTAssertTrue(app.textFields["e.g. Spanish vocabulary"].waitUntilExists(timeout: 5))
        capture("06-new-deck", app)
        app.textFields["e.g. Spanish vocabulary"].tap()
        app.textFields["e.g. Spanish vocabulary"].typeText("Audit Reading")
        app.buttons["new-deck-create"].tap()
        app.buttons["Import or Export"].tap()
        XCTAssertTrue(app.navigationBars["Transfer"].waitUntilExists(timeout: 5))
        capture("07-transfer", app)
        app.buttons["Audit Reading"].tap()
        XCTAssertTrue(app.navigationBars["Export Deck"].waitUntilExists(timeout: 5))
        capture("08-export", app)
        back(app); back(app)
        app.buttons["Deck Builders"].tap()
        XCTAssertTrue(app.navigationBars["Deck Builders"].waitUntilExists(timeout: 5))
        capture("09-builders", app)
        for title in ["Poem Deck", "Prose Deck", "Vocabulary Deck"] {
            app.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitUntilExists(timeout: 5))
            capture("10-builder-" + title, app)
            back(app)
        }
        back(app)
        app.buttons["Vocabulary Packs"].tap()
        XCTAssertTrue(app.navigationBars["Vocabulary Packs"].waitUntilExists(timeout: 5))
        capture("11-vocabulary-packs", app)
        open("Settings", in: app); capture("12-settings", app)
        app.buttons["Enable iCloud Sync…"].tap()
        XCTAssertTrue(app.buttons["Not Now"].waitUntilExists(timeout: 5))
        capture("13-sync-consent", app); app.buttons["Not Now"].tap()
        scrollToAndTap(app.buttons["Study Day"], in: app)
        XCTAssertTrue(app.navigationBars["Study Day"].waitUntilExists(timeout: 5))
        capture("14-study-day", app)
        open("Home", in: app)
        scrollToAndTap(app.staticTexts["Audit Reading"], in: app, maximumSteps: 14)
        XCTAssertTrue(app.navigationBars["Audit Reading"].waitUntilExists(timeout: 5))
        capture("15-deck-overview", app)
        scrollToAndTap(app.buttons["Progress"], in: app); capture("15b-deck-progress", app); back(app)
        scrollToAndTap(app.buttons["Deck Settings"], in: app)
        XCTAssertTrue(app.navigationBars["Deck Settings"].waitUntilExists(timeout: 5))
        capture("16-deck-settings", app)
    }
    func testStudyAndStudioScreenInventory() throws {
        let app = launchApp()
        open("Create", in: app); app.buttons["New Item"].tap()
        let front = app.textFields["add-card-field-front"]
        XCTAssertTrue(front.waitUntilExists(timeout: 5))
        front.tap(); front.typeText("What makes a mobile study app feel well designed?")
        let backField = app.textFields["add-card-field-back"]
        backField.tap(); backField.typeText("Readable content, clear hierarchy, generous touch targets, and predictable navigation.")
        capture("17-authoring-keyboard", app)
        app.buttons["add-card-save"].tap()
        open("Library", in: app); capture("18-library-populated", app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "What makes")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Basic"].waitUntilExists(timeout: 5))
        capture("19-item-detail", app)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Item"].waitUntilExists(timeout: 5))
        capture("20-item-edit", app); app.buttons["Cancel"].tap()
        open("Home", in: app); capture("21-home-populated", app)
        app.buttons["Start Studying"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 15))
        capture("22-study-question", app)
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.buttons["Good"].waitUntilExists(timeout: 5))
        capture("23-study-answer", app)
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Session Complete"].waitUntilExists(timeout: 15))
        capture("24-study-complete", app); app.buttons["Done"].tap()
        openItemTypeStudioCatalog(in: app); capture("25-item-types", app)
        app.staticTexts["Basic"].tap()
        XCTAssertTrue(app.textFields["item-type-studio.name"].waitUntilExists(timeout: 5))
        capture("26-item-type-studio", app)
        scrollToAndTap(firstCardSetupButton(in: app), in: app)
        XCTAssertTrue(app.descendants(matching: .any)["cardSetupEditor"].waitUntilExists(timeout: 5))
        capture("27-card-setup", app)
        scrollToAndTap(app.buttons["Question & Answer"], in: app)
        capture("27b-card-setup-question-answer", app); back(app)
        scrollToAndTap(app.buttons["Edit Content"], in: app)
        capture("27c-card-setup-content", app); back(app)
        scrollToAndTap(app.buttons["Layout, Focus"], in: app)
        capture("27d-card-setup-layouts", app); back(app)
        scrollToAndTap(app.buttons["Availability"], in: app)
        capture("28-card-setup-availability", app); back(app)
        scrollToAndTap(app.buttons["Learning Route"], in: app)
        capture("29-card-setup-learning-route", app); back(app)
        back(app)
        let summary = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".summary")).firstMatch
        summary.tap(); capture("30-field-editor", app)
    }
}

@MainActor
final class MobileStudyModesRedesignUITests: NeoAnki2MobileUITestCase {
    func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }
    func testStudyModesLayoutsAndFullContentConcealment() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-redesign"])
        let fixtures = app.staticTexts["Study Fixtures"]
        XCTAssertTrue(fixtures.waitUntilExists(timeout: 15)); fixtures.tap()
        XCTAssertTrue(app.navigationBars["Study Fixtures"].waitUntilExists(timeout: 5))
        capture("31-nested-decks", app)
        for mode in ["reveal", "cloze", "type", "choose", "arrange", "record", "audioSubmission"] {
            scrollToAndTap(app.staticTexts[mode], in: app)
            XCTAssertTrue(app.navigationBars[mode].waitUntilExists(timeout: 5))
            app.buttons["Start Studying"].tap()
            XCTAssertTrue(app.buttons["endStudySession"].waitUntilExists(timeout: 10))
            capture("32-study-" + mode + "-question", app)
            switch mode {
            case "type":
                app.textFields["Typed answer"].tap(); app.textFields["Typed answer"].typeText("Paris")
                capture("33-study-type-keyboard", app)
                app.buttons["Check Answer"].tap()
            case "choose": app.buttons["Paris"].tap(); app.buttons["Check Choice"].tap()
            case "arrange": app.buttons["Down"].firstMatch.tap(); app.buttons["Check Order"].tap()
            case "record": app.buttons["Compare Recording"].tap()
            case "audioSubmission":
                XCTAssertTrue(app.buttons["Start Recording"].isHittable)
                XCTAssertFalse(app.buttons["Save & Complete"].isEnabled)
                let permissionMonitor = addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
                    let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
                    guard deny.exists else { return false }
                    deny.tap(); return true
                }
                app.buttons["Start Recording"].tap()
                // A system privacy controller can own this alert rather than
                // SpringBoard. A subsequent app gesture invokes XCTest's native
                // interruption handler without depending on its process owner.
                let denial = app.staticTexts["Microphone access was denied. Allow it in Settings to record this response."]
                for _ in 0..<3 where !denial.exists {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
                    _ = denial.waitUntilExists(timeout: 2)
                }
                removeUIInterruptionMonitor(permissionMonitor)
                XCTAssertTrue(app.staticTexts["Microphone access was denied. Allow it in Settings to record this response."].waitUntilExists(timeout: 5))
                capture("34-study-microphone-denied", app)
            default:
                XCTAssertFalse(app.staticTexts["Paris"].exists)
                app.buttons["Show Answer"].tap()
            }
            if mode != "audioSubmission" {
                XCTAssertTrue(app.buttons["Good"].waitUntilExists(timeout: 5))
                capture("34-study-" + mode + "-answer", app)
            }
            app.buttons["endStudySession"].tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        scrollToAndTap(app.staticTexts["Long Content"], in: app)
        app.buttons["Start Studying"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 10))
        app.buttons["More"].tap(); app.buttons["Read Full Card"].tap()
        XCTAssertTrue(app.navigationBars["Full Card"].waitUntilExists(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CONCEALED ANSWER")).firstMatch.exists)
        capture("35-full-card-concealed", app)
        app.buttons["Done"].tap(); app.buttons["Show Answer"].tap()
        app.buttons["More"].tap(); app.buttons["Read Full Card"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CONCEALED ANSWER")).firstMatch.waitUntilExists(timeout: 5))
        capture("36-full-card-revealed", app)
    }
}

@MainActor
final class MobileRedesignParityUITests: NeoAnki2MobileUITestCase {
    func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }

    func testNavigationRetentionBothGradingModesUndoAndSkip() throws {
        let app = launchApp()
        for prompt in ["First practice question", "Second practice question"] {
            open("Create", in: app); app.buttons["New Item"].tap()
            let front = app.textFields["add-card-field-front"]
            XCTAssertTrue(front.waitUntilExists(timeout: 5)); front.tap(); front.typeText(prompt)
            let answer = app.textFields["add-card-field-back"]
            answer.tap(); answer.typeText("Private practice answer")
            app.buttons["add-card-save"].tap()
        }
        open("Library", in: app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "First practice question")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Basic"].waitUntilExists(timeout: 5))
        open("Settings", in: app); open("Library", in: app)
        XCTAssertTrue(app.navigationBars["Basic"].waitUntilExists(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.navigationBars["Basic"].waitUntilExists(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        capture("50-retained-item-detail-landscape", app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil(timeout: 5) { app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        defer { XCUIDevice.shared.orientation = .portrait }
        open("Home", in: app); app.buttons["Start Studying"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 10))
        let currentPrompt = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["First practice question", "Second practice question"])).firstMatch.label
        app.buttons["Show Answer"].tap(); app.buttons["Good"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitUntilExists(timeout: 5)); app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts[currentPrompt].waitUntilExists(timeout: 5))
        app.buttons["More"].tap(); app.buttons["skipStudyCard"].tap()
        let nextPrompt = currentPrompt == "First practice question" ? "Second practice question" : "First practice question"
        XCTAssertTrue(app.staticTexts[nextPrompt].waitUntilExists(timeout: 5))
        capture("51-study-after-undo-skip", app)
        app.buttons["endStudySession"].tap()
        open("Settings", in: app)
        let passFail = app.switches["usesPassFailGrades"]
        scrollTo(passFail, in: app)
        passFail.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 3) { passFail.value as? String == "1" })
        open("Home", in: app); app.buttons["Start Studying"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 10)); app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.buttons["Fail"].isHittable); XCTAssertTrue(app.buttons["Pass"].isHittable)
        XCTAssertFalse(app.buttons["Good"].exists)
        capture("52-study-pass-fail", app)
        app.buttons["Pass"].tap()
    }

    func testScopedBrowseSelectionAttentionAndSavedRecordingPersistence() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-redesign"])
        XCTAssertTrue(app.staticTexts["Study Fixtures"].waitUntilExists(timeout: 20))
        open("Library", in: app)
        app.buttons["Browse Options"].tap(); app.buttons["Repeatedly Forgotten"].tap()
        let prompt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeatedly forgotten prompt")).firstMatch
        XCTAssertTrue(prompt.waitUntilExists(timeout: 5))
        XCTAssertFalse(app.staticTexts["Private answer"].exists)
        capture("37-attention-filter", app)
        app.buttons["Browse Options"].tap(); app.buttons["Select Items"].tap()
        prompt.tap()
        XCTAssertTrue(app.buttons["Mark OK"].isEnabled)
        capture("38-library-selection", app)
        app.buttons["Mark OK"].tap()
        XCTAssertTrue(app.staticTexts["Nothing Needs Attention"].waitUntilExists(timeout: 5))
        app.buttons["Browse Options"].tap(); app.buttons["Done Selecting"].tap()
        app.buttons["Browse Options"].tap(); app.buttons["Repeatedly Forgotten"].tap()
        app.buttons["Browse Options"].tap(); app.buttons["Title"].tap()
        app.buttons["Browse Options"].tap(); app.buttons["Select Items"].tap()
        let reveal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Practice reveal:")).firstMatch
        scrollToAndTap(reveal, in: app)
        app.buttons["Move"].tap(); app.buttons["Needs Attention"].tap()
        app.buttons["Delete"].tap(); app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.last!.tap()
        app.buttons["Browse Options"].tap(); app.buttons["Done Selecting"].tap()
        scrollToAndTap(app.buttons["Saved Responses"], in: app, preferredDirection: .towardTop)
        XCTAssertTrue(app.staticTexts["Explain your favorite book"].waitUntilExists(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["Play"].frame.height, 44)
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitUntilExists(timeout: 2)); app.buttons["Stop"].tap()
        capture("39-saved-recording", app)
        app.terminate(); app.launchArguments.removeAll { $0 == "-NeoAnkiUITestingReset" }; app.launch()
        open("Library", in: app); app.buttons["Saved Responses"].tap()
        XCTAssertTrue(app.staticTexts["Explain your favorite book"].waitUntilExists(timeout: 5))
        app.buttons["Delete"].tap(); app.buttons["Delete Response"].tap()
        XCTAssertTrue(app.staticTexts["No Saved Responses"].waitUntilExists(timeout: 5))
        open("Home", in: app); app.staticTexts["Study Fixtures"].tap()
        scrollToAndTap(app.staticTexts["Needs Attention"], in: app)
        app.buttons["Browse Items"].tap()
        XCTAssertTrue(app.navigationBars["Browse Items"].waitUntilExists(timeout: 5))
        XCTAssertTrue(prompt.waitUntilExists(timeout: 5))
        app.buttons["Add Item"].tap()
        XCTAssertTrue(app.buttons["Deck, Needs Attention"].waitUntilExists(timeout: 5))
        capture("40-scoped-authoring", app)
        app.buttons["Cancel"].tap()
    }

    func testBuildersPreviewImportAndValidation() throws {
        let app = launchApp()
        open("Create", in: app)
        app.buttons["New Deck"].tap()
        app.textFields["e.g. Spanish vocabulary"].tap(); app.textFields["e.g. Spanish vocabulary"].typeText("Poems")
        app.buttons["new-deck-create"].tap()
        app.buttons["Deck Builders"].tap(); app.buttons["Poem Deck"].tap()
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.staticTexts["Enter at least two nonblank lines."].waitUntilExists(timeout: 3))
        capture("41-builder-validation", app)
        scrollToAndTap(app.buttons["poemBuilderRootDeck"], in: app); app.buttons["Poems"].tap()
        let author = app.textFields["poemBuilderAuthor"]
        scrollToAndTap(author, in: app); author.typeText("A Writer")
        let title = app.textFields["poemBuilderTitle"]
        scrollToAndTap(title, in: app); title.typeText("A Small Poem")
        let text = app.textViews["poemBuilderText"]
        scrollToAndTap(text, in: app); text.typeText("First line\nSecond line\nThird line")
        scrollToAndTap(app.buttons["Preview"], in: app)
        XCTAssertTrue(app.staticTexts["First line"].firstMatch.waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["Opening-line card included."].exists)
        XCTAssertTrue(app.staticTexts["Recall the first line."].exists)
        XCTAssertTrue(app.staticTexts["3 lines · 1 stanza · 3 cards"].exists)
        capture("42-poem-preview", app)
        app.buttons["Import"].tap()
        // Import creates the first due cards in this fresh library. Respond to
        // badge consent before waiting for the import operation to finish.
        allowBadgePermissionIfPresented()
        XCTAssertTrue(app.navigationBars["Deck Builders"].waitUntilExists(timeout: 10))
        open("Home", in: app)
        XCTAssertTrue(app.staticTexts["Poems"].waitUntilExists(timeout: 5))
        app.staticTexts["Poems"].tap()
        scrollToAndTap(app.staticTexts["A Small Poem"], in: app); app.buttons["Browse Items"].tap()
        let line = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "First line")).firstMatch
        XCTAssertTrue(line.waitUntilExists(timeout: 5)); line.tap(); app.buttons["Edit"].tap()
        let source = app.textViews["poemEditorSource"]
        XCTAssertTrue(source.waitUntilExists(timeout: 5)); source.tap(); source.typeText(" revised")
        capture("48-poem-editor", app)
        scrollToAndTap(app.buttons["poemEditorPreviewButton"], in: app)
        XCTAssertTrue(app.buttons["poemEditorSave"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["poemEditorSave"].isEnabled)
        capture("49-poem-reconciliation", app)
        app.buttons["poemEditorSave"].tap()
        XCTAssertTrue(app.navigationBars["Poem Line"].waitUntilExists(timeout: 10))
    }

    func testProsePreviewImportAndEditing() throws {
        let app = launchApp()
        open("Create", in: app); app.buttons["New Deck"].tap()
        let deckName = app.textFields["e.g. Spanish vocabulary"]
        deckName.tap(); deckName.typeText("Reading"); app.buttons["new-deck-create"].tap()
        app.buttons["Deck Builders"].tap(); app.buttons["Prose Deck"].tap()
        app.buttons["proseBuilderRootDeck"].tap(); app.buttons["Reading"].tap()
        let title = app.textFields["proseBuilderTitle"]
        title.tap(); title.typeText("A Passage")
        let text = app.textViews["proseBuilderText"]
        scrollToAndTap(text, in: app); text.typeText("A first sentence.\n\nA second paragraph.")
        scrollToAndTap(app.buttons["proseBuilderReview"], in: app)
        XCTAssertTrue(app.navigationBars["Preview"].waitUntilExists(timeout: 5))
        capture("53-prose-preview", app)
        app.buttons["proseBuilderAdd"].tap()
        XCTAssertTrue(app.navigationBars["Deck Builders"].waitUntilExists(timeout: 10))
        open("Home", in: app); app.staticTexts["Reading"].tap()
        app.staticTexts["A Passage"].tap(); app.buttons["Browse Items"].tap()
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Prose Unit")).firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5)); item.tap(); app.buttons["Edit"].tap()
        let source = app.textViews["proseEditorSource"]
        XCTAssertTrue(source.waitUntilExists(timeout: 5)); source.tap(); source.typeText(" Revised.")
        capture("54-prose-editor", app)
        app.buttons["proseEditorPreview"].tap()
        XCTAssertTrue(app.navigationBars["Review Prose Changes"].waitUntilExists(timeout: 5))
        capture("55-prose-reconciliation", app)
        XCTAssertTrue(app.buttons["proseEditorSave"].isEnabled); app.buttons["proseEditorSave"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.navigationBars["Prose Unit"].exists || app.navigationBars["Browse Items"].exists
        })
        if app.navigationBars["Browse Items"].exists {
            XCTAssertTrue(item.waitUntilExists(timeout: 5)); item.tap()
            XCTAssertTrue(app.navigationBars["Prose Unit"].waitUntilExists(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts["Loading item…"].exists)
        capture("56-prose-saved-detail", app)
    }

    func testAllFieldAuthoringMediaRemovalAndPickerCancellation() throws {
        let original = [
            Span("Large colored text", styles: [.bold, .italic, .underline], textColor: .red, textSize: .large),
            Span(" code", styles: [.code], textColor: .blue, textSize: .small, link: "https://example.com"),
            Span(" highlighted", styles: [.highlight, .strikethrough, .superscript])
        ]
        let edited = NSMutableAttributedString(attributedString: RichSpanTextEditor.attributed(original))
        edited.replaceCharacters(in: NSRange(location: 1, length: 1), with: "x")
        var expected = original
        expected[0].text = "Lxrge colored text"
        XCTAssertEqual(RichSpanTextEditor.spans(from: edited), expected,
                       "Editing must preserve formatting on both edited and untouched runs")
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-redesign"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        open("Library", in: app)
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Authoring media fixture")).firstMatch
        scrollToAndTap(item, in: app)
        XCTAssertTrue(app.navigationBars["All Field Types"].waitUntilExists(timeout: 5))
        capture("58-all-field-detail", app)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Item"].waitUntilExists(timeout: 5))
        scrollTo(app.textViews["Rich text"], in: app)
        XCTAssertTrue(app.textViews["Rich text"].isHittable)
        capture("59-rich-cloze-authoring", app)
        scrollToAndTap(app.buttons["Clear Blanks"], in: app)
        XCTAssertTrue(app.staticTexts["Select text, then make it a blank."].exists)
        let remove = app.buttons["Remove Media"]
        scrollTo(remove, in: app)
        XCTAssertTrue(remove.isHittable)
        let ready = app.staticTexts["Media ready"].firstMatch
        XCTAssertTrue(ready.exists)
        XCTAssertGreaterThanOrEqual(ready.frame.minX, app.windows.firstMatch.frame.minX)
        XCTAssertLessThanOrEqual(ready.frame.maxX, app.windows.firstMatch.frame.maxX)
        capture("60-media-authoring", app)
        remove.tap()
        XCTAssertFalse(remove.exists)
        let photos = app.buttons["Photos"].firstMatch
        scrollToAndTap(photos, in: app)
        // Scope to the native picker, including its unavailable-library state.
        // Its Cancel identifier varies; the underlying editor must not match.
        let pickerBars = app.navigationBars.matching(NSPredicate(
            format: "identifier == %@ OR identifier == %@ OR identifier == %@",
            "Photos", "PUSidebarView", "PUPickerUnavailableView"))
        let pickerCancel = pickerBars.buttons["Cancel"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { pickerCancel.exists && pickerCancel.isHittable })
        pickerCancel.tap()
        XCTAssertTrue(app.navigationBars["Edit Item"].waitUntilExists(timeout: 5))
        XCTAssertFalse(app.alerts["Could Not Save Item"].exists)
        scrollTo(app.textFields["Audio description (optional)"], in: app)
        XCTAssertTrue(app.textFields["Audio description (optional)"].isHittable)
        capture("61-audio-video-authoring", app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["All Field Types"].waitUntilExists(timeout: 10))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Item"].waitUntilExists(timeout: 5))
        scrollTo(app.buttons["Photos"].firstMatch, in: app)
        XCTAssertFalse(app.buttons["Remove Media"].exists)
        XCTAssertFalse(app.buttons["Clear Blanks"].exists)
        app.buttons["Cancel"].tap()
    }

    func testVocabularySearchPreviewImportAndPackPersistence() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-vocabulary"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        open("Create", in: app)
        app.buttons["New Deck"].tap()
        let deckName = app.textFields["e.g. Spanish vocabulary"]
        deckName.tap(); deckName.typeText("Words"); app.buttons["new-deck-create"].tap()
        app.buttons["Vocabulary Packs"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Acceptance Lexicon")).firstMatch.waitUntilExists(timeout: 10))
        capture("62-installed-vocabulary", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Deck Builders"].tap(); app.buttons["Vocabulary Deck"].tap()
        let search = app.textFields["vocabularyBuilderSearchField"]
        XCTAssertTrue(search.waitUntilExists(timeout: 10)); search.tap(); search.typeText("swift")
        app.buttons["vocabularyBuilderSearch"].tap()
        let entry = app.buttons["vocabularyBuilderEntry-en:swift"]
        scrollToAndTap(entry, in: app)
        scrollToAndTap(app.buttons["vocabularyBuilderRootDeck"], in: app); app.buttons["Words"].tap()
        let generatedName = app.textFields["vocabularyBuilderDeckName"]
        scrollToAndTap(generatedName, in: app); clearText(in: generatedName); generatedName.typeText("Swift Words")
        let preview = app.buttons["vocabularyBuilderPreview"]
        XCTAssertTrue(waitUntil(timeout: 5) { preview.isEnabled })
        capture("63-vocabulary-source", app)
        preview.tap()
        XCTAssertTrue(app.navigationBars["Preview"].waitUntilExists(timeout: 5))
        capture("64-vocabulary-preview", app)
        app.buttons["vocabularyBuilderAdd"].tap()
        XCTAssertTrue(app.navigationBars["Deck Builders"].waitUntilExists(timeout: 10))
        open("Library", in: app)
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "swift")).firstMatch
        XCTAssertTrue(imported.waitUntilExists(timeout: 5)); imported.tap()
        XCTAssertTrue(app.buttons["Edit"].waitUntilExists(timeout: 5))
        capture("65-vocabulary-imported-detail", app)
        app.terminate(); app.launchArguments.removeAll { $0 == "-NeoAnkiUITestingReset" }; app.launch()
        open("Create", in: app); app.buttons["Vocabulary Packs"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Acceptance Lexicon")).firstMatch.waitUntilExists(timeout: 10))
    }

    func testGenericDictionaryLookupInNewItemSavesToChosenDeck() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-item-lookup"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        open("Create", in: app)
        app.buttons["New Item"].tap()
        app.buttons["add-card-type"].tap(); app.buttons["Basic"].tap()
        app.buttons["add-card-deck"].tap(); app.buttons["Words"].tap()
        scrollToAndTap(app.buttons["Dictionary"].firstMatch, in: app)
        app.buttons["itemDictionarySource"].tap(); app.buttons["Front"].tap()
        app.buttons["itemDictionaryDestination"].tap(); app.buttons["Back"].tap()
        let front = app.textFields["add-card-field-front"]
        scrollToAndTap(front, in: app); front.typeText("swift")
        app.buttons["add-card-keyboard-done"].tap()
        let back = app.textFields["add-card-field-back"]
        XCTAssertTrue(waitUntil(timeout: 10) { (back.value as? String)?.contains("ˈswɪft") == true })
        XCTAssertTrue((back.value as? String)?.contains("Moving quickly and smoothly.") == true)
        app.buttons["add-card-save"].tap()
        XCTAssertTrue(app.navigationBars["Create"].waitUntilExists(timeout: 10))
        open("Home", in: app)
        scrollToAndTap(app.staticTexts["Words"], in: app)
        app.buttons["Browse Items"].tap()
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "swift")).firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        scrollToAndTap(app.buttons["Start Studying"], in: app)
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 10))
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ˈswɪft")).firstMatch.waitUntilExists(timeout: 5))
        app.buttons["endStudySession"].tap()
    }

    func testPhotoCanBeSelectedBeforeNameAndDescription() throws {
        // Initialize the disposable Simulator's system library before opening its extension.
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        for label in ["Continue", "Get Started"] {
            let button = photos.buttons[label]
            if button.exists && button.isHittable { button.tap() }
        }
        photos.terminate()
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-item-lookup"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        open("Create", in: app)
        app.buttons["New Item"].tap()
        app.buttons["add-card-type"].tap(); app.buttons["Photo Names"].tap()
        app.buttons["add-card-deck"].tap(); app.buttons["Words"].tap()
        scrollToAndTap(app.buttons["Photos"], in: app)
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitUntilExists(timeout: 30), "The disposable Simulator must have a photo added with simctl addmedia")
        // Photos exposes a thumbnail frame but no XCTest hit point on this runtime.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Media ready"].waitUntilExists(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["add-card-preview-photo"].exists)
        let name = app.textFields["add-card-field-name"]
        scrollToAndTap(name, in: app); name.typeText("Oak")
        app.buttons["add-card-keyboard-done"].tap()
        XCTAssertFalse(app.buttons["add-card-save"].isEnabled, "An optional attached photo still needs a description")
        let description = app.textFields["add-card-description-photo"]
        scrollToAndTap(description, in: app); description.typeText("A tree with lobed leaves")
        XCTAssertTrue(app.buttons["add-card-save"].isEnabled)
        description.typeText(" updated")
        app.buttons["add-card-keyboard-done"].tap()
        app.buttons["add-card-save"].tap()
        XCTAssertTrue(app.navigationBars["Create"].waitUntilExists(timeout: 10))
        open("Library", in: app)
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A tree with lobed leaves updated")).firstMatch
        XCTAssertTrue(item.waitUntilExists(timeout: 5)); item.tap()
        app.buttons["Edit"].tap()
        XCTAssertEqual(app.textFields["edit-card-description-photo"].value as? String, "A tree with lobed leaves updated")
        app.buttons["Cancel"].tap()
        open("Home", in: app)
        app.buttons["Start Studying"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 10))
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.staticTexts["Oak"].waitUntilExists(timeout: 5))
        app.buttons["endStudySession"].tap()
    }

    func testTransferPreviewImportAndConcealment() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-transfer"])
        open("Create", in: app); app.buttons["Import or Export"].tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["Imported question"].exists)
        capture("46-transfer-preview", app)
        app.buttons["Import"].tap()
        XCTAssertTrue(app.staticTexts["Imported 1 item"].waitUntilExists(timeout: 10))
        capture("47-transfer-success", app)
        open("Library", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Imported question")).firstMatch.waitUntilExists(timeout: 5))
        XCTAssertFalse(app.staticTexts["Imported answer"].exists)
    }

    func testSyncConflictRecoveryAndImportFailure() throws {
        var app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-sync-recovery"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        open("Settings", in: app)
        let issues = app.buttons["Sync Issues (2)"]
        XCTAssertTrue(issues.waitUntilExists(timeout: 10)); issues.tap()
        XCTAssertTrue(app.navigationBars["Sync Issues"].waitUntilExists(timeout: 5))
        capture("66-sync-conflicts", app)
        let restore = app.buttons.matching(identifier: "Restore as New Copy")
        scrollToAndTap(restore.element(boundBy: 1), in: app)
        XCTAssertTrue(app.alerts["Could Not Restore Copy"].waitUntilExists(timeout: 5))
        capture("67-sync-restore-error", app); app.buttons["OK"].tap()
        scrollToAndTap(restore.firstMatch, in: app, preferredDirection: .towardTop)
        XCTAssertTrue(waitUntil(timeout: 5) { restore.count == 1 })
        open("Home", in: app)
        XCTAssertTrue(app.staticTexts["Preserved reading deck (Recovered)"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synced reading deck"].exists)
        capture("68-sync-restored-deck", app)
        open("Settings", in: app)
        app.buttons["Dismiss"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Sync Issues"].waitUntilExists(timeout: 5))
        capture("69-sync-resolved", app)
        app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-transfer-error"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 15))
        open("Create", in: app); app.buttons["Import or Export"].tap()
        XCTAssertTrue(app.alerts["Import Failed"].waitUntilExists(timeout: 5))
        capture("70-transfer-error", app); app.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Choose File"].isHittable)
    }

    func testLibraryRecoveryPresentationAndRetry() throws {
        let app = launchApp(environment: ["NEOANKI_TEST_SCENARIO": "mobile-load-error"])
        XCTAssertTrue(app.staticTexts["Could Not Open NeoAnki2"].waitUntilExists(timeout: 15))
        XCTAssertTrue(app.buttons["Try Again"].isHittable)
        capture("71-library-recovery", app)
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 15))
        capture("72-library-retry-success", app)
    }

    func testLargeTextGradesReflowWithoutBreakingLabels() throws {
        let app = launchApp(additionalArguments: ["-NeoAnkiUITestingLargeText"], environment: ["NEOANKI_TEST_SCENARIO": "mobile-redesign"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        scrollToAndTap(app.staticTexts["Study Fixtures"], in: app)
        scrollToAndTap(app.staticTexts["reveal"], in: app)
        scrollToAndTap(app.buttons["Start Studying"], in: app)
        XCTAssertTrue(app.buttons["Show Answer"].waitUntilExists(timeout: 10)); app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.buttons["Good"].waitUntilExists(timeout: 5))
        for title in ["Again", "Hard", "Good", "Easy"] {
            XCTAssertTrue(app.buttons[title].isHittable)
            XCTAssertEqual(app.buttons[title].frame.height, app.buttons["Hard"].frame.height, accuracy: 1,
                           "Grade labels must fit without wrapping midword")
        }
        capture("73-large-text-grades", app)
    }

    func testLargestTypeStudyAccessibilityRotationAndKeyboard() throws {
        let app = launchApp(additionalArguments: ["-NeoAnkiUITestingAccessibility"], environment: ["NEOANKI_TEST_SCENARIO": "mobile-redesign"])
        XCTAssertTrue(app.navigationBars["Home"].waitUntilExists(timeout: 20))
        scrollToAndTap(app.staticTexts["Study Fixtures"], in: app, maximumSteps: 14)
        scrollToAndTap(app.staticTexts["type"], in: app)
        scrollToAndTap(app.buttons["Start Studying"], in: app)
        let input = app.textFields["Typed answer"]
        scrollToAndTap(input, in: app); input.typeText("Paris")
        let check = app.buttons["Check Answer"]
        XCTAssertTrue(check.isHittable)
        XCTAssertGreaterThanOrEqual(check.frame.height, 44)
        capture("43-largest-study-keyboard", app)
        check.tap()
        for title in ["Again", "Hard", "Good", "Easy"] {
            let grade = app.buttons[title]
            XCTAssertTrue(grade.waitUntilExists(timeout: 5)); XCTAssertTrue(grade.isHittable)
            XCTAssertGreaterThanOrEqual(grade.frame.height, 44)
            XCTAssertGreaterThanOrEqual(grade.frame.width, 44)
        }
        XCTAssertGreaterThan(app.buttons["Good"].frame.minY, app.buttons["Again"].frame.minY,
                             "Accessibility text must reflow grades into multiple rows")
        let question = app.staticTexts["Practice type: what do you remember?"]
        scrollTo(question, in: app, preferredDirection: .towardTop)
        for title in ["Again", "Hard", "Good", "Easy"] {
            XCTAssertEqual(app.buttons[title].frame.height, app.buttons["Hard"].frame.height, accuracy: 1,
                           "Grade labels must remain whole at the largest text size")
        }
        try auditVisibleContent(in: app)
        scrollTo(app.staticTexts["Correct"], in: app)
        XCTAssertTrue(app.staticTexts["Paris"].isHittable)
        try auditVisibleContent(in: app)
        capture("44-largest-study-grading", app)
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitUntil(timeout: 5) {
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        })
        // UIKit updates accessibility geometry before the rotation animation
        // finishes drawing. Retain a settled render instead of a transition.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue(app.buttons["Good"].isHittable)
        for title in ["Again", "Hard", "Good", "Easy"] {
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons[title].frame),
                          "\(title) must remain fully visible after rotation")
        }
        capture("45-largest-study-landscape", app)
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Session Complete"].waitUntilExists(timeout: 10))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(done.frame))
        done.tap()
    }
}
