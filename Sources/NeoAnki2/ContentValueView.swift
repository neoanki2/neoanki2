import NeoAnkiCore
import SwiftUI

struct ContentValueView: View {
    let value: ContentValue

    var body: some View {
        switch value {
        case .text, .rich, .number:
            Text(ItemDisplay.plainText(from: value))
                .multilineTextAlignment(.center)
        case .media, .cloze:
            Text("Unsupported content")
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

    var body: some View {
        let values = SideContent.values(for: side, from: item)
        VStack(spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                ContentValueView(value: value)
            }
        }
    }
}
