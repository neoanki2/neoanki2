import NeoAnkiCore

enum ContentRenderingPolicy {
    enum Rendering: Equatable {
        case content
        case blurredMedia
        case placeholder
    }

    struct Decision: Equatable {
        let rendering: Rendering
        let accessibilityLabel: String?
        let shouldResolveMedia: Bool
    }

    static func decision(
        for value: ContentValue,
        revealMode: RevealMode,
        isAnswerRevealed: Bool
    ) -> Decision {
        let semantic = ContentVisibilityPolicy.decision(
            for: value,
            revealMode: revealMode,
            isAnswerRevealed: isAnswerRevealed
        )
        let rendering: Rendering = switch semantic.rendering {
        case .content: .content
        case .blurredMedia: .blurredMedia
        case .placeholder: .placeholder
        }
        let label: String?
        if semantic.rendering == .content {
            label = nil
        } else if semantic.rendering == .blurredMedia {
            label = "Blurred \(contentDescription(for: value).lowercased())"
        } else {
            let suffix = revealMode == .hiddenUntilAnswer ? "hidden until answer" : "concealed until answer"
            label = "\(contentDescription(for: value)) \(suffix)"
        }
        return Decision(
            rendering: rendering,
            accessibilityLabel: label,
            shouldResolveMedia: semantic.shouldResolveMedia
        )
    }

    private static func contentDescription(for value: ContentValue) -> String {
        switch value {
        case .text, .rich:
            "Text"
        case .number:
            "Number"
        case .cloze:
            "Cloze"
        case let .media(ref):
            switch ref.kind {
            case .audio: "Audio"
            case .image: "Image"
            case .gif: "Animation"
            case .video: "Video"
            }
        case .empty:
            "Content"
        }
    }
}
