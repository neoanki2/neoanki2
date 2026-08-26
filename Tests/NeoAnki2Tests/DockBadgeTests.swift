import AppKit
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
