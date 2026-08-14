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
