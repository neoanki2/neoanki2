import NeoAnkiCore

/// A recording's alt text may be its transcript. It must not answer a listening question before reveal.
public enum ReviewMediaAccessibility {
    public static func description(for reference: MediaRef, isAnswerRevealed: Bool) -> String {
        let fallback: String = switch reference.kind {
        case .audio: "Audio"
        case .video: "Video"
        case .image: "Image"
        case .gif: "Animation"
        }
        if !isAnswerRevealed, reference.kind == .audio || reference.kind == .video { return fallback }
        guard let description = reference.altText, !description.isEmpty else { return fallback }
        return description
    }
}
