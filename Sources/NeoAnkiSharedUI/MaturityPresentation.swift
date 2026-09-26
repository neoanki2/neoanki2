import NeoAnkiCore

public extension CardMaturityStatus {
    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .learning: "Learning"
        case .maintaining: "Maintaining"
        case .inactive: "Inactive"
        }
    }
}

public extension MaturitySummary {
    var displayName: String {
        switch status {
        case .noActiveCards: "No active cards"
        case .notStarted: "Not started"
        case .learning: "Learning"
        case .maintaining: "Maintaining"
        }
    }

    var progressText: String {
        "\(maintainingCardCount) of \(activeCardCount) maintaining"
    }
}
