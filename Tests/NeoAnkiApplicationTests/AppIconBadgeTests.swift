import NeoAnkiApplication
import Testing

@Test(arguments: [-1, 0, 1, 42, 12_345])
func appIconBadgeUsesTheSameCountAndLabelOnEveryPlatform(dueCount: Int) {
    let badge = AppIconBadge(dueCount: dueCount)
    #expect(badge.count == max(0, dueCount))
    #expect(badge.label == (dueCount > 0 ? String(dueCount) : nil))
}
