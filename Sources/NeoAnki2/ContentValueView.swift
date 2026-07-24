import NeoAnkiCore
import SwiftUI

struct ContentValueView: View {
    let value: ContentValue

    var body: some View {
        switch value {
        case .text, .number:
            Text(ItemDisplay.plainText(from: value))
                .multilineTextAlignment(.center)
        case let .rich(spans):
            Text(attributedString(from: spans))
                .multilineTextAlignment(.center)
        case .media, .cloze:
            Text("Content not available yet")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .empty:
            EmptyView()
        }
    }

    private func attributedString(from spans: [Span]) -> AttributedString {
        spans.reduce(into: AttributedString()) { result, span in
            var run = AttributedString(span.text)

            var font: Font = .body
            if span.styles.contains(.code) {
                font = .body.monospaced()
            }
            if span.styles.contains(.bold) {
                font = font.bold()
            }
            if span.styles.contains(.italic) {
                font = font.italic()
            }
            run.font = font

            if span.styles.contains(.underline) {
                run.underlineStyle = .single
            }
            if span.styles.contains(.strikethrough) {
                run.strikethroughStyle = .single
            }
            if span.styles.contains(.code) {
                run.backgroundColor = Color(nsColor: .controlBackgroundColor)
            }
            if span.styles.contains(.highlight) {
                run.backgroundColor = DesignSystem.contentHighlightBackground
            }

            result.append(run)
        }
    }
}

struct SideContentView: View {
    let side: Side
    let item: Item

    var body: some View {
        let values = SideContent.values(for: side, from: item)
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                ContentValueView(value: value)
            }
        }
    }
}
