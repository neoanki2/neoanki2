import Foundation

enum EditorDismissalDecision: Equatable {
    case dismiss
    case confirmDiscard
}

enum EditorDecisionState {
    static func dismissalDecision<Draft: Equatable>(
        initial: Draft,
        current: Draft
    ) -> EditorDismissalDecision {
        initial == current ? .dismiss : .confirmDiscard
    }

    static func requiresTemplateDeletionConfirmation(templateExists: Bool) -> Bool {
        templateExists
    }
}
