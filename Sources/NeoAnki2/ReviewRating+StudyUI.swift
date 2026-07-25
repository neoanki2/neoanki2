import NeoAnkiCore
import SwiftUI

extension ReviewRating {
    var studyButtonTitle: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }

    var studyButtonTitleWithShortcut: String {
        "\(studyButtonTitle) (\(studyShortcutLabel))"
    }

    var studyShortcutLabel: String {
        switch self {
        case .again: "1"
        case .hard: "2"
        case .good: "3"
        case .easy: "4"
        }
    }

    var studyTooltip: String {
        switch self {
        case .again: "Didn't remember — show this card again soon"
        case .hard: "Remembered with difficulty"
        case .good: "Remembered correctly"
        case .easy: "Too easy — wait longer before the next review"
        }
    }

    var studyAccessibilityLabel: String {
        "\(studyButtonTitle), \(studyTooltip)"
    }

    var studyKeyboardShortcut: KeyEquivalent {
        switch self {
        case .again: "1"
        case .hard: "2"
        case .good: "3"
        case .easy: "4"
        }
    }

    var gradeAccessibilityIdentifier: String {
        switch self {
        case .again: "gradeAgain"
        case .hard: "gradeHard"
        case .good: "gradeGood"
        case .easy: "gradeEasy"
        }
    }
}
