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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(DesignSystem.Typography.uiSecondary)

            TextEditor(text: $text)
                .font(DesignSystem.Typography.uiBody)
                .frame(minHeight: 100)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityIdentifier)

            HStack {
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
        guard blank.start >= 0, blank.start + blank.length <= text.count else { return "?" }
        let start = text.index(text.startIndex, offsetBy: blank.start)
        let end = text.index(start, offsetBy: blank.length)
        return String(text[start ..< end])
    }

    private func markSelectionAsBlank() {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Use last non-empty word as a simple default when no selection API is available.
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let lastWord = words.last else { return }
        let word = String(lastWord)
        guard let range = text.range(of: word, options: .backwards) else { return }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let blank = ClozeSpan(group: nextGroup(), start: start, length: word.count)

        do {
            let candidate = blanks + [blank]
            try ClozeValidation.validate(text: text, blanks: candidate)
            blanks = candidate
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
    }

    private func nextGroup() -> Int {
        (blanks.map(\.group).max() ?? 0) + 1
    }
}

struct ClozeContentView: View {
    let text: String
    let blanks: [ClozeSpan]
    let revealMode: RevealMode
    let isAnswerRevealed: Bool

    var body: some View {
        Text(displayText)
            .multilineTextAlignment(.center)
            .font(DesignSystem.Typography.cardPrompt)
    }

    private var displayText: String {
        let revealed = isAnswerRevealed || revealMode == .always
        return ClozeValidation.displayText(from: text, blanks: blanks, revealed: revealed)
    }
}
