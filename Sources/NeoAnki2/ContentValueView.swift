import NeoAnkiCore
import SwiftUI

struct ContentValueView: View {
    let value: ContentValue
    var presentation: Presentation = Presentation()
    var isAnswerRevealed: Bool = true
    var richTextPointSize: CGFloat = DesignSystem.Typography.richTextPointSize
    var mediaStore: MediaStore?

    var body: some View {
        switch value {
        case let .text(string, _):
            Text(string)
                .multilineTextAlignment(.center)
                .opacity(shouldHideText ? 0 : 1)
        case let .number(number):
            Text(String(number))
                .multilineTextAlignment(.center)
        case let .rich(spans):
            Text(SpanFormatting.swiftUIAttributedString(from: spans, pointSize: richTextPointSize))
                .multilineTextAlignment(.center)
                .blur(radius: presentation.reveal == .blurred && !isAnswerRevealed ? 8 : 0)
                .opacity(shouldHideText ? 0 : 1)
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
                isAnswerRevealed: isAnswerRevealed
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

struct SideContentView: View {
    let side: Side
    let item: Item
    var isAnswerRevealed: Bool = true
    var richTextPointSize: CGFloat = DesignSystem.Typography.richTextPointSize
    var mediaStore: MediaStore?

    var body: some View {
        let slots = SideContent.resolvedSlots(for: side, from: item)
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                ContentValueView(
                    value: slot.value,
                    presentation: slot.presentation,
                    isAnswerRevealed: isAnswerRevealed,
                    richTextPointSize: richTextPointSize,
                    mediaStore: mediaStore
                )
            }
        }
    }
}
