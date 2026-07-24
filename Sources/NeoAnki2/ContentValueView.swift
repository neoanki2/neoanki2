import NeoAnkiCore
import SwiftUI

struct ContentValueView: View {
    let value: ContentValue
    var richTextPointSize: CGFloat = DesignSystem.Typography.richTextPointSize

    var body: some View {
        switch value {
        case .text, .number:
            Text(ItemDisplay.plainText(from: value))
                .multilineTextAlignment(.center)
        case let .rich(spans):
            Text(SpanFormatting.swiftUIAttributedString(from: spans, pointSize: richTextPointSize))
                .multilineTextAlignment(.center)
        case .media, .cloze:
            Text("Content not available yet")
                .font(DesignSystem.Typography.uiSecondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .empty:
            EmptyView()
        }
    }

}

struct SideContentView: View {
    let side: Side
    let item: Item
    var richTextPointSize: CGFloat = DesignSystem.Typography.richTextPointSize

    var body: some View {
        let values = SideContent.values(for: side, from: item)
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                ContentValueView(value: value, richTextPointSize: richTextPointSize)
            }
        }
    }
}
