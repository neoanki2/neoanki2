#if os(iOS)
import NeoAnkiCore
import SwiftUI
import UIKit

struct ClozeSelectionEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    @Binding var blanks: [ClozeSpan]
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SelectionTextView(text: $text, selection: $selection)
                .modifier(MobileTextEditorHeight())
            MobileAdaptiveActionGroup {
                Button { makeCloze() } label: { Text("Make Cloze").frame(minHeight: 44) }
                    .disabled(selection.length == 0)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if !blanks.isEmpty {
                    Button(role: .destructive) { blanks = [] } label: { Text("Clear Blanks").frame(minHeight: 44) }
                }
            }.buttonStyle(.borderless)
            Text(blanks.isEmpty ? "Select text, then make it a blank." : "\(blanks.count) \(blanks.count == 1 ? "blank" : "blanks")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func makeCloze() {
        // UITextView reports UTF-16 offsets. Convert through String.Index so
        // stored offsets count grapheme clusters and never split an emoji or
        // combining sequence.
        guard let utf16Start = text.utf16.index(text.utf16.startIndex, offsetBy: selection.location, limitedBy: text.utf16.endIndex),
              let utf16End = text.utf16.index(utf16Start, offsetBy: selection.length, limitedBy: text.utf16.endIndex),
              let start = String.Index(utf16Start, within: text),
              let end = String.Index(utf16End, within: text)
        else { return }
        let characterStart = text.distance(from: text.startIndex, to: start)
        let characterLength = text.distance(from: start, to: end)
        guard characterLength > 0 else { return }
        let nextGroup = (blanks.map(\.group).max() ?? 0) + 1
        let candidate = ClozeSpan(group: nextGroup, start: characterStart, length: characterLength)
        let updated = ClozeValidation.sanitize(text: text, blanks: blanks + [candidate])
        if updated.count == blanks.count + 1 { blanks = updated }
    }
}

private struct SelectionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, selection: $selection) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.accessibilityLabel = "Cloze text"
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.updateBindings(text: $text, selection: $selection)
        guard view.text != text else { return }
        // Assigning text can invoke the selection delegate synchronously. Keep
        // UIKit's programmatic updates from publishing state during rendering.
        context.coordinator.isUpdatingText = true
        defer { context.coordinator.isUpdatingText = false }
        view.text = text
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String; @Binding var selection: NSRange
        var isUpdatingText = false
        init(text: Binding<String>, selection: Binding<NSRange>) { _text = text; _selection = selection }
        func updateBindings(text: Binding<String>, selection: Binding<NSRange>) {
            _text = text; _selection = selection
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingText else { return }
            if text != textView.text { text = textView.text }
            updateSelection(textView)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdatingText else { return }
            updateSelection(textView)
        }
        private func updateSelection(_ textView: UITextView) {
            if selection != textView.selectedRange { selection = textView.selectedRange }
        }
    }
}
#endif
