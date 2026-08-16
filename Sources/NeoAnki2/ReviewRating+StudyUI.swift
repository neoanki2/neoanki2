import NeoAnkiCore

extension ReviewRating {
    var gradeAccessibilityIdentifier: String {
        switch self {
        case .again: "gradeAgain"
        case .hard: "gradeHard"
        case .good: "gradeGood"
        case .easy: "gradeEasy"
        }
    }
}
