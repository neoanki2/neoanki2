import NeoAnkiCore
import SwiftUI

struct StudyCommandHandlers {
    var startStudy: (() -> Void)?
    var requestEndSession: (() -> Void)?
    var showAnswer: (() -> Void)?
    var grade: ((ReviewRating) -> Void)?
    var undoLastGrade: (() -> Void)?
    var canStartStudy = false
    var canEndSession = false
    var canShowAnswer = false
    var canGrade = false
    var canUndoLastGrade = false
}

private struct StudyCommandHandlersKey: FocusedValueKey {
    typealias Value = StudyCommandHandlers
    static var defaultValue: StudyCommandHandlers? { nil }
}

extension FocusedValues {
    var studyCommandHandlers: StudyCommandHandlers? {
        get { self[StudyCommandHandlersKey.self] }
        set { self[StudyCommandHandlersKey.self] = newValue }
    }
}

struct StudyCommands: Commands {
    @FocusedValue(\.studyCommandHandlers) private var handlers

    var body: some Commands {
        CommandMenu("Study") {
            Button("Start Study") {
                handlers?.startStudy?()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!(handlers?.canStartStudy ?? false))

            Button("End Session") {
                handlers?.requestEndSession?()
            }
            .disabled(!(handlers?.canEndSession ?? false))

            Divider()

            Button("Show Answer") {
                handlers?.showAnswer?()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!(handlers?.canShowAnswer ?? false))

            Divider()

            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button("Grade: \(rating.studyButtonTitle)") {
                    handlers?.grade?(rating)
                }
                .keyboardShortcut(rating.studyKeyboardShortcut, modifiers: [])
                .disabled(!(handlers?.canGrade ?? false))
            }

            Divider()

            Button("Undo Last Grade") {
                handlers?.undoLastGrade?()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!(handlers?.canUndoLastGrade ?? false))
        }
    }
}
