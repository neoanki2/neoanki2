import AppKit
import NeoAnkiCore
import SwiftUI

struct ClozeFieldEditor: View {
    let label: String
    @Binding var text: String
    @Binding var blanks: [ClozeSpan]
    let accessibilityIdentifier: String

    @State private var selectionStart: Int?
    @State private var selectionLength: Int = 0
    @State private var errorMessage: String?
    @State private var selectedGroup: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(DesignSystem.Typography.uiSecondary)

            ClozeTextEditor(
                text: $text,
                selectionStart: $selectionStart,
                selectionLength: $selectionLength,
                accessibilityLabel: label
            )
                .frame(minHeight: 100)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityIdentifier)
                .onChange(of: text) { oldText, newText in
                    rebaseBlanks(from: oldText, to: newText)
                }

            HStack {
                Picker("Add to", selection: $selectedGroup) {
                    Text("New group").tag(Int?.none)
                    ForEach(Array(Set(blanks.map(\.group))).sorted(), id: \.self) { group in
                        Text("Group \(group)").tag(Optional(group))
                    }
                }
                .frame(maxWidth: 180)

                Button("Mark Blank") {
                    markSelectionAsBlank()
                }
                .disabled(text.isEmpty)
                .accessibilityIdentifier("\(accessibilityIdentifier)-markBlank")

                if !blanks.isEmpty {
                    Button("Clear Blanks", role: .destructive) {
                        blanks = []
                    }
                }
            }

            if !blanks.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                    ForEach(Array(blanks.enumerated()), id: \.offset) { index, blank in
                        clozeBlankRow(index: index, blank: blank)
                    }
                }
            }

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }
        }
    }

    @ViewBuilder
    private func clozeBlankRow(index: Int, blank: ClozeSpan) -> some View {
        let snippet = snippet(for: blank)
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Group \(blank.group): \"\(snippet)\"")
                .font(DesignSystem.Typography.uiCaption)
                .foregroundStyle(.secondary)
            Picker("Group", selection: groupBinding(for: index)) {
                ForEach(Array(Set(blanks.map(\.group))).sorted(), id: \.self) { group in
                    Text("\(group)").tag(group)
                }
                Text("New").tag(nextGroup())
            }
            .labelsHidden()
            .frame(width: 70)
            TextField("Hint", text: hintBinding(for: index))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            Button(role: .destructive) {
                blanks.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove blank \(snippet) from group \(blank.group)")
        }
    }

    private func groupBinding(for index: Int) -> Binding<Int> {
        Binding(
            get: { blanks[index].group },
            set: { blanks[index].group = $0 }
        )
    }

    private func hintBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { blanks[index].hint ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                blanks[index].hint = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func snippet(for blank: ClozeSpan) -> String {
        let (endOffset, overflowed) = blank.start.addingReportingOverflow(blank.length)
        guard blank.start >= 0, blank.length > 0, !overflowed, endOffset <= text.count,
              let start = text.index(
                  text.startIndex,
                  offsetBy: blank.start,
                  limitedBy: text.endIndex
              ),
              let end = text.index(start, offsetBy: blank.length, limitedBy: text.endIndex)
        else { return "?" }
        return String(text[start ..< end])
    }

    private func markSelectionAsBlank() {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let start: Int
        let length: Int
        if let selectionStart, selectionLength > 0 {
            start = selectionStart
            length = selectionLength
        } else {
            let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let lastWord = words.last else { return }
            let word = String(lastWord)
            guard let range = text.range(of: word, options: .backwards) else { return }
            start = text.distance(from: text.startIndex, to: range.lowerBound)
            length = word.count
        }
        guard let blank = ClozeBlankBuilder.blank(
            text: text,
            selectionStart: start,
            selectionLength: length,
            group: selectedGroup ?? nextGroup()
        ) else {
            return
        }

        do {
            let candidate = blanks + [blank]
            try ClozeValidation.validate(text: text, blanks: candidate)
            blanks = candidate
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
    }

    private func rebaseBlanks(from oldText: String, to newText: String) {
        let result = ClozeSpanRebaser.rebase(spans: blanks, from: oldText, to: newText)
        guard result.spans != blanks || !result.invalidated.isEmpty else { return }
        blanks = result.spans
        if let selectedGroup, !blanks.contains(where: { $0.group == selectedGroup }) {
            self.selectedGroup = nil
        }
        if !result.invalidated.isEmpty {
            let count = result.invalidated.count
            errorMessage = count == 1
                ? "One blank was removed because the edit crossed its boundary. Mark it again if needed."
                : "\(count) blanks were removed because the edit crossed their boundaries. Mark them again if needed."
        }
    }

    private func nextGroup() -> Int {
        let maximum = blanks.map(\.group).max() ?? 0
        let (next, overflowed) = maximum.addingReportingOverflow(1)
        return overflowed ? 1 : max(1, next)
    }
}

enum ClozeBlankBuilder {
    static func blank(
        text: String,
        selectionStart: Int,
        selectionLength: Int,
        group: Int
    ) -> ClozeSpan? {
        guard selectionStart >= 0, selectionLength > 0 else { return nil }
        guard let start = text.index(
            text.startIndex,
            offsetBy: selectionStart,
            limitedBy: text.endIndex
        ), let end = text.index(
            start,
            offsetBy: selectionLength,
            limitedBy: text.endIndex
        ), start < end else {
            return nil
        }
        return ClozeSpan(
            group: group,
            start: text.distance(from: text.startIndex, to: start),
            length: text.distance(from: start, to: end)
        )
    }
}

private struct ClozeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionStart: Int?
    @Binding var selectionLength: Int
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let selectedRange = textView.selectedRange()
        textView.string = text
        textView.setSelectedRange(NSIntersectionRange(selectedRange, NSRange(location: 0, length: text.utf16.count)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClozeTextEditor

        init(parent: ClozeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateSelection(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateSelection(in: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch ClozeFocusNavigation.direction(for: commandSelector) {
            case .forward:
                textView.window?.selectNextKeyView(textView)
                return true
            case .backward:
                textView.window?.selectPreviousKeyView(textView)
                return true
            case nil:
                return false
            }
        }

        private func updateSelection(in textView: NSTextView) {
            let string = textView.string
            let selected = textView.selectedRange()
            guard selected.length > 0,
                  let range = Range(selected, in: string)
            else {
                parent.selectionStart = nil
                parent.selectionLength = 0
                return
            }
            parent.selectionStart = string.distance(from: string.startIndex, to: range.lowerBound)
            parent.selectionLength = string.distance(from: range.lowerBound, to: range.upperBound)
        }
    }
}

enum ClozeFocusNavigation {
    static func direction(for selector: Selector) -> RichTextFocusNavigation.Direction? {
        RichTextFocusNavigation.direction(for: selector)
    }
}

struct ClozeContentView: View {
    let text: String
    let blanks: [ClozeSpan]
    let revealMode: RevealMode
    let isAnswerRevealed: Bool
    var group: Int?

    var body: some View {
        Text(displayText)
            .multilineTextAlignment(.center)
            .font(DesignSystem.Typography.cardPrompt)
    }

    private var displayText: String {
        // A cloze prompt always shows the sentence with its blanks masked; the
        // blanks reveal only once the answer is shown. `revealMode` is
        // intentionally ignored for concealment so an author-selected
        // `.always` slot can't leak the answer on the prompt side.
        ClozeValidation.displayText(
            from: text,
            blanks: blanks,
            revealed: isAnswerRevealed,
            group: group
        )
    }
}
