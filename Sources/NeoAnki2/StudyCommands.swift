import NeoAnkiCore
import SwiftUI

struct StudyCommandHandlers {
    var startStudy: (() -> Void)?
    var requestEndSession: (() -> Void)?
    var editCurrentCard: (() -> Void)?
    var grade: ((ReviewRating) -> Void)?
    var undoLastGrade: (() -> Void)?
    var canStartStudy = false
    var canEndSession = false
    var canEditCurrentCard = false
    var canGrade = false
    var canUndoLastGrade = false
}

struct StudyPrimaryActionHandler {
    var action: (() -> Void)?
    var isEnabled = false

    func invoke() {
        guard isEnabled else { return }
        action?()
    }
}

private struct StudyPrimaryActionHandlerKey: FocusedValueKey {
    typealias Value = StudyPrimaryActionHandler
    static var defaultValue: StudyPrimaryActionHandler? { nil }
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

    var studyPrimaryActionHandler: StudyPrimaryActionHandler? {
        get { self[StudyPrimaryActionHandlerKey.self] }
        set { self[StudyPrimaryActionHandlerKey.self] = newValue }
    }
}

struct StudyCommands: Commands {
    @FocusedValue(\.studyCommandHandlers) private var handlers
    @FocusedValue(\.studyPrimaryActionHandler) private var primaryAction

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

            Button("Edit Card…") {
                handlers?.editCurrentCard?()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!(handlers?.canEditCurrentCard ?? false))

            Divider()

            Button("Continue") {
                primaryAction?.invoke()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!(primaryAction?.isEnabled ?? false))

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
