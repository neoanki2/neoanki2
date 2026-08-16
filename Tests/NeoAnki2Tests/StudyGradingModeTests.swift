import NeoAnkiCore
import NeoAnkiSharedUI
import Testing

@Test func passFailGradingUsesAgainAndGoodSchedulerRatings() throws {
    let choices = StudyGradingMode.passFail.choices

    #expect(choices.map(\.title) == ["Fail", "Pass"])
    #expect(choices.map(\.shortcutLabel) == ["1", "2"])
    #expect(choices.map(\.rating) == [.again, .good])
}

@Test func standardGradingRetainsAllFourSchedulerRatings() {
    let choices = StudyGradingMode.standard.choices

    #expect(choices.map(\.title) == ["Again", "Hard", "Good", "Easy"])
    #expect(choices.map(\.shortcutLabel) == ["1", "2", "3", "4"])
    #expect(choices.map(\.rating) == [.again, .hard, .good, .easy])
}
