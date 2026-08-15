import NeoAnkiApplication
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

    func studyAccessibilityLabel(preview: ReviewSchedulePreview?) -> String {
        guard let preview else { return studyAccessibilityLabel }
        return "\(studyButtonTitle), schedules the next review \(preview.accessibleIntervalDescription). \(studyTooltip)"
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
        case .again: "Didn't remember — repeat this card later in this session"
        case .hard: "Remembered with difficulty — may return later today"
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

extension ReviewSchedulePreview {
    var compactIntervalDescription: String {
        let seconds = intervalSeconds
        if seconds < 1 { return "Now" }
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 86_400 { return "\(max(1, Int((seconds / 3_600).rounded())))h" }
        let days = max(1, Int((seconds / 86_400).rounded()))
        return "\(days)d"
    }

    var accessibleIntervalDescription: String {
        let seconds = intervalSeconds
        if seconds < 1 { return "immediately" }
        if seconds < 60 { return "in less than one minute" }
        if seconds < 3_600 {
            let minutes = max(1, Int((seconds / 60).rounded()))
            return "in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        if seconds < 86_400 {
            let hours = max(1, Int((seconds / 3_600).rounded()))
            return "in \(hours) \(hours == 1 ? "hour" : "hours")"
        }
        let days = max(1, Int((seconds / 86_400).rounded()))
        return "in \(days) \(days == 1 ? "day" : "days")"
    }
}
