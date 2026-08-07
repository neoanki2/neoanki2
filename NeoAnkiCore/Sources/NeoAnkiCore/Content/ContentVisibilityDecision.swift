/// Semantic visibility chosen before any platform renders content.
public enum ContentVisibilityRendering: Sendable, Equatable {
    case content
    case blurredMedia
    case placeholder
}

public struct ContentVisibilityDecision: Sendable, Equatable {
    public let rendering: ContentVisibilityRendering
    public let shouldResolveMedia: Bool

    public init(rendering: ContentVisibilityRendering, shouldResolveMedia: Bool) {
        self.rendering = rendering
        self.shouldResolveMedia = shouldResolveMedia
    }
}

public enum ContentVisibilityPolicy {
    public static func decision(
        for value: ContentValue,
        revealMode: RevealMode,
        isAnswerRevealed: Bool
    ) -> ContentVisibilityDecision {
        if case .empty = value {
            return .init(rendering: .content, shouldResolveMedia: false)
        }
        // Cloze content masks individual blanks in its renderer; concealing the
        // whole value would remove the sentence context needed to answer it.
        if case .cloze = value {
            return .init(rendering: .content, shouldResolveMedia: false)
        }
        guard !isAnswerRevealed, revealMode != .always else {
            return .init(rendering: .content, shouldResolveMedia: isMedia(value))
        }
        switch revealMode {
        case .always:
            preconditionFailure("Always-visible content was handled above.")
        case .hiddenUntilAnswer:
            return .init(rendering: .placeholder, shouldResolveMedia: false)
        case .blurred:
            if case let .media(reference) = value,
               reference.kind == .image || reference.kind == .gif {
                return .init(rendering: .blurredMedia, shouldResolveMedia: true)
            }
            return .init(rendering: .placeholder, shouldResolveMedia: false)
        }
    }

    private static func isMedia(_ value: ContentValue) -> Bool {
        if case .media = value { return true }
        return false
    }
}
