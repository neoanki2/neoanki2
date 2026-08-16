import NeoAnkiCore

public enum StudyPreferences {
    public static let usesPassFailGrades = "usesPassFailGrades"
}

public struct StudyGradeChoice: Equatable, Sendable {
    public let title: String
    public let rating: ReviewRating
    public let shortcutLabel: String
    public let guidance: String

    public init(
        title: String,
        rating: ReviewRating,
        shortcutLabel: String,
        guidance: String
    ) {
        self.title = title
        self.rating = rating
        self.shortcutLabel = shortcutLabel
        self.guidance = guidance
    }

    public var titleWithShortcut: String {
        "\(title) (\(shortcutLabel))"
    }

    public var accessibilityLabel: String {
        "\(title), \(guidance)"
    }
}

public enum StudyGradingMode: Equatable, Sendable {
    case standard
    case passFail

    public init(usesPassFailGrades: Bool) {
        self = usesPassFailGrades ? .passFail : .standard
    }

    public var choices: [StudyGradeChoice] {
        switch self {
        case .standard:
            [
                StudyGradeChoice(
                    title: "Again",
                    rating: .again,
                    shortcutLabel: "1",
                    guidance: "Didn't remember — repeat this card later in this session"
                ),
                StudyGradeChoice(
                    title: "Hard",
                    rating: .hard,
                    shortcutLabel: "2",
                    guidance: "Remembered with difficulty — may return later today"
                ),
                StudyGradeChoice(
                    title: "Good",
                    rating: .good,
                    shortcutLabel: "3",
                    guidance: "Remembered correctly"
                ),
                StudyGradeChoice(
                    title: "Easy",
                    rating: .easy,
                    shortcutLabel: "4",
                    guidance: "Too easy — wait longer before the next review"
                ),
            ]
        case .passFail:
            [
                StudyGradeChoice(
                    title: "Fail",
                    rating: .again,
                    shortcutLabel: "1",
                    guidance: "Didn't remember — schedules as Again"
                ),
                StudyGradeChoice(
                    title: "Pass",
                    rating: .good,
                    shortcutLabel: "2",
                    guidance: "Remembered correctly — schedules as Good"
                ),
            ]
        }
    }

    public func title(for rating: ReviewRating) -> String {
        choices.first(where: { $0.rating == rating })?.title ?? Self.standardTitle(for: rating)
    }

    private static func standardTitle(for rating: ReviewRating) -> String {
        switch rating {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}
