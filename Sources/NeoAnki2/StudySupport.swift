import NeoAnkiCore

enum StudySupport {
    static func isSupportedInteraction(_ interaction: Interaction) -> Bool {
        switch interaction {
        case .reveal, .cloze:
            true
        case .type, .choose, .record, .arrange:
            false
        }
    }
}
