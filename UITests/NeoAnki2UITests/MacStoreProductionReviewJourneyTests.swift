import AppKit
import CryptoKit
import Darwin
import XCTest

/// The Store review runner launches the optimized sandboxed application without
/// fixture arguments. Its caller owns a fresh container and preserves the result.
final class MacStoreProductionReviewJourneyTests: NeoAnkiUITestCase {
    func testFreshInstallCreateStudyAndPersistence() async throws {
        guard ProcessInfo.processInfo.environment["NEOANKI_MAC_STORE_REVIEW"] == "1" else {
            throw XCTSkip("Run through Scripts/review-macos-app.py against the Store candidate")
        }
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        runningApp = app
        defer { app.terminate() }
        app.launch()
        guard app.wait(for: .runningForeground, timeout: 10) else {
            XCTFail("The Apple-installed Store app failed its ordinary launch")
            return
        }
        waitForLibraryReady(in: app)
        assertEmptyLibrary(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["emptyLibraryState"].waitUntilExists(timeout: 5),
                      "A fresh Store container must contain no study items")
        try storeCapture("01-native-mac-first-launch", app)
        addBasicItem(front: "What does spaced repetition improve?", back: "Long-term recall.", in: app)
        waitForItem(named: "What does spaced repetition improve?", in: app)
        try storeCapture("02-native-mac-library", app)
        leaveBrowseMode(in: app)
        startStudyViaMenu(in: app)
        try storeCapture("03-native-mac-study", app)
        let action = app.buttons.identified("primaryStudyAction")
        XCTAssertTrue(action.waitUntilExists(timeout: 5), "The new card must be available to study")
        action.click()
        XCTAssertTrue(app.staticTexts["Long-term recall."].waitUntilExists(timeout: 5))
        try storeCapture("04-native-mac-answer", app)
        let grade = app.buttons.identified("gradeEasy")
        XCTAssertTrue(grade.waitUntilExists(timeout: 5))
        grade.click()
        XCTAssertTrue(app.buttons.identified("studySessionDone").waitUntilExists(timeout: 10))
        app.terminate()
        app.launch()
        waitForLibraryReady(in: app)
        waitForItem(named: "What does spaced repetition improve?", in: app)
        try storeCapture("05-native-mac-persistence", app)
        try verifySandboxFilesAndRecording(in: app)
        try await verifySandboxLocalAPI(in: app)
    }

    private func verifySandboxFilesAndRecording(in app: XCUIApplication) throws {
        // These are ordinary external user documents, selected through native
        // panels after the unmodified application's clean-first-launch journey.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-documents-\(UUID().uuidString)")
        let bundle = directory.appendingPathComponent("Store Review.neoanki")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("media"), withIntermediateDirectories: true)
        let image = try Data(contentsOf: fixturesDirectory().appendingPathComponent("media/cover.png"))
        try image.write(to: bundle.appendingPathComponent("media/cover.png"))
        let records = [
            #"{"kind":"neoanki","version":4,"root":"root","parts":["items.jsonl"]}"#,
            #"{"kind":"type","id":"image","name":"Store Image","fields":[{"id":"prompt","name":"Prompt","type":"text","required":true},{"id":"image","name":"Image","type":"image","required":true}],"templates":[{"name":"Image","prompt":[{"field":"prompt"}],"answer":[{"field":"image"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}"#,
            #"{"kind":"type","id":"voice","name":"Store Voice","fields":[{"id":"prompt","name":"Prompt","type":"text","required":true}],"templates":[{"name":"Private Response","prompt":[{"field":"prompt"}],"answer":[],"interaction":"audioSubmission","skill":{"input":"text","output":"audio","operation":"reproduce"}}]}"#,
            #"{"kind":"deck","id":"root","name":"Store Import","itemTypes":["image","voice"],"defaultType":"image"}"#,
            #"{"kind":"deck","id":"images","parent":"root","name":"Images","itemTypes":["image"],"defaultType":"image"}"#,
            #"{"kind":"deck","id":"voice","parent":"root","name":"Voice","itemTypes":["voice"],"defaultType":"voice"}"#,
        ]
        try (records.joined(separator: "\n") + "\n").write(to: bundle.appendingPathComponent("deck.jsonl"), atomically: true, encoding: .utf8)
        try (#"{"kind":"item","deck":"images","type":"image","fields":{"prompt":{"text":"Sandbox image question"},"image":{"media":{"path":"media/cover.png","alt":"Store review cover"}}}}"# + "\n" +
             #"{"kind":"item","deck":"voice","type":"voice","fields":{"prompt":{"text":"Describe what you learned today"}}}"# + "\n")
            .write(to: bundle.appendingPathComponent("items.jsonl"), atomically: true, encoding: .utf8)
        app.menuBarItems["File"].click()
        app.menuItems.identified("Import Deck…").click()
        cancelFilePicker(in: app)
        waitForItem(named: "What does spaced repetition improve?", in: app)
        choosePortableDeckImport(bundle, in: app)
        finishPortableImport(in: app)
        waitForItem(named: "Sandbox image question", in: app)
        showSidebar(in: app)
        if !app.descendants(matching: .any)["deckRow-Images"].exists {
            let disclosure = app.disclosureTriangles.firstMatch
            XCTAssertTrue(disclosure.waitUntilExists(timeout: 5))
            disclosure.click()
        }
        selectScope("deckRow-Images", in: app)
        leaveBrowseMode(in: app)
        startStudyViaMenu(in: app)
        triggerPrimaryStudyAction(in: app)
        XCTAssertTrue(app.images["Store review cover"].waitUntilExists(timeout: 10))
        try evidenceCapture("sandbox-imported-image", app)
        clickOrType("gradeEasy", shortcut: "4", in: app)
        finishStudySession(in: app)
        selectScope("deckRow-Store Import", in: app)
        app.menuBarItems["File"].click()
        app.menuItems.identified("Export Deck…").click()
        cancelFilePicker(in: app)
        let exported = directory.appendingPathComponent("roundtrip.neodeck")
        chooseExportDestination(exported, in: app)
        XCTAssertTrue(waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: exported.path) })
        _ = dismissPortableDeckNoticeIfPresent(titled: "Deck Exported", in: app)
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        query.arguments = [exported.path, "SELECT count(*) FROM items; SELECT lower(hex(digest)) FROM media_assets;"]
        let pipe = Pipe()
        query.standardOutput = pipe
        try query.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        query.waitUntilExit()
        XCTAssertEqual(query.terminationStatus, 0)
        let exportedContent = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(exportedContent.hasPrefix("2\n"), exportedContent)
        let expectedHash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(exportedContent.contains(expectedHash), "Export must retain the selected external image bytes")
        try evidenceCapture("sandbox-export-complete", app)
        selectScope("deckRow-Voice", in: app)
        leaveBrowseMode(in: app)
        startStudy(in: app)
        let start = app.buttons.identified("startAudioSubmission")
        XCTAssertTrue(start.waitUntilHittable(timeout: 10))
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].click(); return true }
            if alert.buttons["OK"].exists { alert.buttons["OK"].click(); return true }
            return false
        }
        start.click()
        app.click()
        let stop = app.buttons.identified("stopAudioSubmission")
        XCTAssertTrue(stop.waitUntilHittable(timeout: 15), "Actual microphone recording must start")
        let duration = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Recording duration ")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) {
            duration.exists && !["00:00", "00:01", "00:02"].contains(where: duration.label.hasSuffix)
        })
        try evidenceCapture("sandbox-microphone-recording", app)
        stop.click()
        app.buttons.identified("audioSubmissionActions").click()
        app.menuItems.identified("playAudioSubmission").click()
        XCTAssertTrue(app.staticTexts["Playing your recording…"].waitUntilExists(timeout: 5))
        let save = app.buttons.identified("saveAudioSubmission")
        XCTAssertTrue(save.waitUntilHittable(timeout: 10))
        save.click()
        finishStudySession(in: app)
        app.terminate()
        app.launch()
        waitForLibraryReady(in: app)
        showSidebar(in: app)
        app.descendants(matching: .any)["savedResponsesSidebar"].click()
        XCTAssertTrue(app.staticTexts["Describe what you learned today"].waitUntilExists(timeout: 10))
        let persistedPlay = app.buttons["Play recording"]
        XCTAssertTrue(persistedPlay.waitUntilHittable(timeout: 10))
        persistedPlay.click()
        let persistedStop = app.buttons["Stop recording"]
        XCTAssertTrue(persistedStop.waitUntilExists(timeout: 5), "The saved response must play from library storage after restart")
        try evidenceCapture("sandbox-recording-persisted", app)
        if persistedStop.exists { persistedStop.click() }
    }

    private func verifySandboxLocalAPI(in app: XCUIApplication) async throws {
        app.typeKey(",", modifierFlags: [.command])
        let apiTab = app.buttons["Local API"]
        if apiTab.waitUntilExists(timeout: 5) { apiTab.click() }
        else { app.radioButtons["Local API"].click() }
        let port = app.textFields["Local API port"]
        XCTAssertTrue(port.waitUntilExists(timeout: 5))
        let number = try unusedLoopbackPort()
        port.click()
        port.typeKey("a", modifierFlags: [.command])
        port.typeText(String(number))
        app.buttons["Apply"].click()
        let toggle = app.checkBoxes["Enable local automation API"]
        XCTAssertTrue(toggle.waitUntilHittable(timeout: 5))
        toggle.click()
        XCTAssertTrue(app.staticTexts["Listening on the configured loopback port"].waitUntilExists(timeout: 10))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let address = "http://127.0.0.1:\(number)"
        let (_, health) = try await session.data(from: XCTUnwrap(URL(string: address + "/health")))
        XCTAssertEqual((health as? HTTPURLResponse)?.statusCode, 200)
        let (_, unauthorized) = try await session.data(from: XCTUnwrap(URL(string: address + "/v1/decks")))
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        try evidenceCapture("sandbox-local-api-listening", app)
        toggle.click()
        XCTAssertTrue(app.staticTexts["Not listening"].waitUntilExists(timeout: 10))
        do {
            _ = try await session.data(from: XCTUnwrap(URL(string: address + "/health")))
            XCTFail("Disabling the API must stop the actual sandboxed listener")
        } catch is URLError { }
        app.typeKey("w", modifierFlags: [.command])
    }

    private func evidenceCapture(_ name: String, _ app: XCUIApplication) throws {
        try storeCapture("review-" + name, app)
    }

    private func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func prepareStoreCaptureWindow(in app: XCUIApplication) throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let primaryTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let visible = CGRect(x: screen.visibleFrame.minX, y: primaryTop - screen.visibleFrame.maxY,
                             width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        let window = app.windows.firstMatch
        if visible.width >= 1440 && visible.height >= 900 {
            let initial = window.frame
            let proposed = CGRect(origin: initial.origin, size: CGSize(width: 1440, height: 900))
            if !visible.contains(proposed) {
                // The retained failed gesture grabbed ten points below the
                // outer frame and never moved the window. Use the observed
                // native chrome control's vertical center as the drag band.
                let close = window.buttons[XCUIIdentifierCloseWindow]
                XCTAssertTrue(close.waitUntilExists(timeout: 5), app.debugDescription)
                let title = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: initial.width / 2, dy: close.frame.midY - initial.minY))
                let destinationOrigin = CGPoint(x: visible.minX + (visible.width - 1440) / 2,
                                                y: visible.minY + (visible.height - 900) / 2)
                let destination = title.withOffset(CGVector(dx: destinationOrigin.x - initial.minX,
                                                            dy: destinationOrigin.y - initial.minY))
                title.press(forDuration: 0.1, thenDragTo: destination)
                XCTAssertTrue(waitUntil(timeout: 5) {
                    let proposed = CGRect(origin: window.frame.origin, size: CGSize(width: 1440, height: 900))
                    return visible.insetBy(dx: -1, dy: -1).contains(proposed)
                }, "The actual window origin must leave room for the full Store capture: \(window.frame), visible: \(visible)")
            }
            if abs(window.frame.width - 1440) >= 1 || abs(window.frame.height - 900) >= 1 {
                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                    .withOffset(CGVector(dx: -3, dy: -3))
                let destination = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: 1437, dy: 897))
                corner.press(forDuration: 0.1, thenDragTo: destination)
            }
            XCTAssertTrue(waitUntil(timeout: 10) {
                let frame = window.frame
                return abs(frame.width - 1440) < 1 && abs(frame.height - 900) < 1
                    && visible.insetBy(dx: -1, dy: -1).contains(frame)
            }, "The review window must have native Store dimensions and remain fully visible: \(window.frame)")
        } else {
            app.typeKey("f", modifierFlags: [.control, .command])
            XCTAssertTrue(waitUntil(timeout: 10) {
                let frame = window.frame
                return abs(frame.width - 1440) < 1 && abs(frame.height - 900) < 1
            }, "Full Screen must supply a native 1440x900 Store capture on this display")
        }
    }

    private func storeCapture(_ name: String, _ app: XCUIApplication) throws {
        let listingCapture = name.contains("-native-mac-")
        if listingCapture { try prepareStoreCaptureWindow(in: app) }
        let window = app.windows.firstMatch
        let frame = window.frame
        guard let primary = NSScreen.screens.first else {
            XCTFail("A Store capture requires a connected screen")
            return
        }
        let fullyOnscreen = NSScreen.screens.contains { screen in
            let bounds = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                                width: screen.frame.width, height: screen.frame.height)
            return bounds.insetBy(dx: -1, dy: -1).contains(frame)
        }
        guard fullyOnscreen else {
            XCTFail("Capture \(name) requires a fully onscreen app window; actual: \(frame)")
            return
        }
        if listingCapture && (abs(frame.width - 1440) >= 1 || abs(frame.height - 900) >= 1) {
            XCTFail("Listing capture \(name) requires a 1440x900 window; actual: \(frame)")
            return
        }
        // Application screenshots include the surrounding desktop on macOS.
        // Capture only this real window and verify the unmodified PNG pixels.
        let screenshot = window.screenshot()
        if listingCapture {
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            guard (pixels.pixelsWide == 1440 && pixels.pixelsHigh == 900)
                    || (pixels.pixelsWide == 2880 && pixels.pixelsHigh == 1800) else {
                XCTFail("Capture \(name) must have native 1440x900 or 2880x1800 pixels; actual: \(pixels.pixelsWide)x\(pixels.pixelsHigh)")
                return
            }
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
