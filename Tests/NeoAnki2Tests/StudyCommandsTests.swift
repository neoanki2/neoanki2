import Testing

@testable import NeoAnki2

@Test func primaryStudyCommandHonorsEnablement() {
    var invocationCount = 0
    var handler = StudyPrimaryActionHandler(
        action: { invocationCount += 1 },
        isEnabled: false
    )

    handler.invoke()
    #expect(invocationCount == 0)

    handler.isEnabled = true
    handler.invoke()
    #expect(invocationCount == 1)
}
