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
        if case .empty = value {
            return Decision(
                rendering: .content,
                accessibilityLabel: nil,
                shouldResolveMedia: false
            )
        }

        // Cloze content is self-concealing: the surrounding sentence must stay
        // visible while its blanks are masked until the answer is revealed. It
        // therefore always renders inline (ClozeContentView performs the
        // per-blank masking based on `isAnswerRevealed`) and never collapses to
        // a generic placeholder, which would hide the whole prompt.
        if case .cloze = value {
            return Decision(
                rendering: .content,
                accessibilityLabel: nil,
                shouldResolveMedia: false
            )
        }

        guard !isAnswerRevealed, revealMode != .always else {
            return Decision(
                rendering: .content,
                accessibilityLabel: nil,
                shouldResolveMedia: isMedia(value)
            )
        }

        let description = contentDescription(for: value)
        switch revealMode {
        case .always:
            preconditionFailure("Always-visible content was handled above.")
        case .hiddenUntilAnswer:
            return Decision(
                rendering: .placeholder,
                accessibilityLabel: "\(description) hidden until answer",
                shouldResolveMedia: false
            )
        case .blurred:
            if case let .media(ref) = value, ref.kind == .image || ref.kind == .gif {
                return Decision(
                    rendering: .blurredMedia,
                    accessibilityLabel: "Blurred \(description.lowercased())",
                    shouldResolveMedia: true
                )
            }
            return Decision(
                rendering: .placeholder,
                accessibilityLabel: "\(description) concealed until answer",
                shouldResolveMedia: false
            )
        }
    }

    private static func isMedia(_ value: ContentValue) -> Bool {
        if case .media = value {
            return true
        }
        return false
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
