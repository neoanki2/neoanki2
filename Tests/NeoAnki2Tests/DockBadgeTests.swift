import AppKit
import NeoAnkiApplication
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test func dockBadgeShowsPositiveDueCounts() {
    #expect(AppDelegate.badgeLabel(forDueCount: 1) == "1")
    #expect(AppDelegate.badgeLabel(forDueCount: 12_345) == "12345")
}

@Test func dockBadgeIsClearWhenNothingIsDue() {
    #expect(AppDelegate.badgeLabel(forDueCount: 0) == nil)
    #expect(AppDelegate.badgeLabel(forDueCount: -1) == nil)
}

@Test @MainActor func dockBadgePreservesCountAcrossLaunchOrdering() {
    var labels: [String?] = []
    let badge = DockBadgeController { labels.append($0) }
    // Cold bootstrap can finish before AppKit's launch notification.
    badge.update(dueCount: 7)
    badge.reapply()
    #expect(labels == ["7", "7"])

    // Launch can also finish before bootstrap.
    let other = DockBadgeController { labels.append($0) }
    other.reapply()
    other.update(dueCount: 3)
    other.update(dueCount: 0)
    #expect(Array(labels.suffix(3)) == [nil, "3", nil])
}

@Test @MainActor func dockBadgePublishesColdSnapshotAndRefreshWithoutAView() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-dock-badge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await library.bootstrap()
    let deck = try await library.createDeck(Deck(name: "Selected"))
    let now = Date.now
    let item = try await library.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    ), asOf: now)
    var labels: [String?] = []
    let badge = DockBadgeController { labels.append($0) }
    let model = DecksModel(library: library, onDueCountChange: { badge.update(dueCount: $0) })
    model.selectedScope = .deck(deck.id)
    let snapshot = try await library.coldHomeSnapshot(scope: .deck(deck.id), asOf: now)
    model.applyColdHomeSnapshot(snapshot)
    #expect(labels == ["1"])
    #expect(model.scopeDueCount == 0)

    badge.reapply()
    await model.refreshCounts(asOf: now)
    #expect(labels == ["1", "1"])
    _ = try await library.deleteItem(id: item.id)
    await model.refreshCounts(asOf: now)
    #expect(labels.last == .some(nil))

    // The uncached first-load path also publishes without mounting ContentView.
    _ = try await library.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("New Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("New A")),
        ]
    ), asOf: now)
    let uncached = DecksModel(library: library, onDueCountChange: { badge.update(dueCount: $0) })
    await uncached.load(asOf: now)
    #expect(labels.last == .some("1"))
}

@Test("Window height stays inside the visible screen with bottom clearance")
func windowHeightIsConstrainedToVisibleScreen() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let oversized = NSRect(x: 120, y: -80, width: 960, height: 1_100)

    let constrained = WindowFramePolicy.constrainedFrame(
        oversized,
        in: visibleFrame,
        bottomClearance: 16
    )

    #expect(constrained == NSRect(x: 120, y: 16, width: 960, height: 884))
}

@Test("Window policy preserves a frame that already has bottom clearance")
func windowFrameIsPreservedWhenAlreadyVisible() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let frame = NSRect(x: 120, y: 80, width: 960, height: 640)

    #expect(
        WindowFramePolicy.constrainedFrame(
            frame,
            in: visibleFrame,
            bottomClearance: 16
        ) == frame
    )
}
