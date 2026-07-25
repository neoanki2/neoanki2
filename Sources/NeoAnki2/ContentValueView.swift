import Foundation
import NeoAnkiCore
import SwiftUI

struct ContentValueView: View {
    @Environment(\.locale) private var locale

    let value: ContentValue
    var presentation: Presentation = Presentation()
    var isAnswerRevealed: Bool = true
    var richTextPointSize: CGFloat = DesignSystem.Typography.richTextPointSize
    var mediaStore: MediaStore?
    var clozeGroup: Int?

    var body: some View {
        switch value {
        case let .text(string, language):
            Text(LanguageMetadata.attributedString(string, language: language))
                .multilineTextAlignment(.center)
                .opacity(shouldHideText ? 0 : 1)
                .accessibilityHidden(shouldHideText)
        case let .number(number):
            Text(ContentNumberRendering.string(from: number, locale: locale))
                .multilineTextAlignment(.center)
        case let .rich(spans):
            Text(SpanFormatting.swiftUIAttributedString(from: spans, pointSize: richTextPointSize))
                .multilineTextAlignment(.center)
                .blur(radius: presentation.reveal == .blurred && !isAnswerRevealed ? 8 : 0)
                .opacity(shouldHideText ? 0 : 1)
                .accessibilityHidden(shouldHideText)
        case let .media(ref):
            if let mediaStore {
                ResolvedMediaView(
                    ref: ref,
                    presentation: presentation,
                    isAnswerRevealed: isAnswerRevealed,
                    store: mediaStore
                )
            } else {
                Text(ref.altText ?? FieldTypeLabels.name(for: fieldType(for: ref.kind)))
                    .font(DesignSystem.Typography.uiSecondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case let .cloze(text, blanks):
            ClozeContentView(
                text: text,
                blanks: blanks,
                revealMode: presentation.reveal,
                isAnswerRevealed: isAnswerRevealed,
                group: clozeGroup
            )
        case .empty:
            EmptyView()
        }
    }

    private var shouldHideText: Bool {
        presentation.reveal == .hiddenUntilAnswer && !isAnswerRevealed
    }

    private func fieldType(for kind: MediaKind) -> FieldType {
        switch kind {
        case .audio: .audio
        case .image: .image
        case .gif: .gif
        case .video: .video
        }
    }
}

enum LanguageMetadata {
    static func attributedString(_ text: String, language: String?) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.languageIdentifier = accessibilityTag(from: language)
        return attributed
    }

    static func accessibilityTag(from language: String?) -> String? {
        guard let language else { return nil }
        let tag = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty, tag.count <= 35 else { return nil }

        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first,
              (2 ... 8).contains(primary.count),
              primary.allSatisfy(\.isLetter),
              parts.dropFirst().allSatisfy({
                  (1 ... 8).contains($0.count) && $0.allSatisfy { $0.isLetter || $0.isNumber }
              }) else {
            return nil
        }
        return tag
    }
}

struct SideContentView: View {
    let side: Side
    let item: Item
    var isAnswerRevealed: Bool = true
    var richTextPointSize: CGFloat = DesignSystem.Typography.richTextPointSize
    var mediaStore: MediaStore?
    var clozeGroup: Int?

    var body: some View {
        let slots = SideContent.resolvedSlots(for: side, from: item)
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                ContentValueView(
                    value: slot.value,
                    presentation: slot.presentation,
                    isAnswerRevealed: isAnswerRevealed,
                    richTextPointSize: richTextPointSize,
                    mediaStore: mediaStore,
                    clozeGroup: clozeGroup
                )
            }
        }
    }
}
