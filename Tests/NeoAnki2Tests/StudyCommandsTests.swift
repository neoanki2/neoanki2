import NeoAnkiCore
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

@Test func spaceRevealsThenGradesGoodWhenAvailable() {
    var reveals = 0
    var ratings: [ReviewRating] = []
    let primaryAction = StudyPrimaryActionHandler(
        action: { reveals += 1 },
        isEnabled: true
    )
    var handlers = StudyCommandHandlers()
    handlers.grade = { ratings.append($0) }

    #expect(handlers.canUseSpace(primaryAction: primaryAction))
    handlers.useSpace(primaryAction: primaryAction)
    #expect(reveals == 1)
    #expect(ratings.isEmpty)

    handlers.canGrade = true
    #expect(handlers.canUseSpace(primaryAction: nil))
    handlers.useSpace(primaryAction: primaryAction)
    #expect(reveals == 1)
    #expect(ratings == [.good])
}

@Test func spaceDoesNothingWhenStudyActionsAreDisabled() {
    var reveals = 0
    var grades = 0
    let primaryAction = StudyPrimaryActionHandler(
        action: { reveals += 1 },
        isEnabled: false
    )
    var handlers = StudyCommandHandlers()
    handlers.grade = { _ in grades += 1 }

    #expect(!handlers.canUseSpace(primaryAction: primaryAction))
    handlers.useSpace(primaryAction: primaryAction)
    #expect(reveals == 0)
    #expect(grades == 0)
}
