import NeoAnkiCore

enum StudySupport {
    static func isSupportedInteraction(_ interaction: Interaction) -> Bool {
        true
    }

    static func acceptedAnswers(for card: DueCard) -> [String] {
        StudyResponseEvaluator.acceptedAnswers(for: card)
    }

    static func evaluate(_ response: String, for card: DueCard) -> AnswerEvaluation {
        StudyResponseEvaluator.evaluate(response, for: card)
    }

    static func hasReferenceAudio(for card: DueCard) -> Bool {
        StudyResponseEvaluator.hasReferenceAudio(for: card)
    }

    static func choiceOptions(for card: DueCard, maximum: Int = 4) -> [String] {
        StudyResponseEvaluator.choiceOptions(for: card, maximum: maximum)
    }

    static func arrangement(for card: DueCard) -> Arrangement? {
        StudyResponseEvaluator.arrangement(for: card)
    }

    static func isCorrectArrangement(_ response: [String], for card: DueCard) -> AnswerEvaluation {
        StudyResponseEvaluator.isCorrectArrangement(response, for: card)
    }
}

typealias AnswerEvaluation = NeoAnkiCore.AnswerEvaluation
typealias Arrangement = NeoAnkiCore.Arrangement
