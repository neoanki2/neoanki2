import SwiftUI

/// Shared review of generated cues and editable unit boundaries.
struct ProseUnitReviewView: View {
    @Binding var units: [ProseUnit]
    var newCardIndices: Set<Int> = []
    var retiredCards: [ProseRetiredCard] = []

    var body: some View {
        let prompts = ProsePromptPlanner.prompts(for: units)
        List {
            Section {
                Text(
                    "\(ProseText.paragraphCount(in: units)) paragraphs · \(units.count) cards"
                )
                .font(.headline)
                Text("Say or write the next unit before revealing it. Adjust any break that feels unnatural.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !retiredCards.isEmpty {
                Section("Cards to retire") {
                    ForEach(Array(retiredCards.enumerated()), id: \.offset) { _, card in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.prompt)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(card.answer)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            ForEach(Array(units.enumerated()), id: \.offset) { index, unit in
                ProseUnitRow(
                    index: index,
                    unit: unit,
                    prompt: prompts[index],
                    isNewCard: newCardIndices.contains(index),
                    canJoin: index + 1 < units.count && units[index + 1].separator != "\n\n",
                    onSplit: { word in
                        guard let parts = ProseText.split(units[index], afterWord: word) else { return }
                        units.replaceSubrange(index...index, with: [parts.0, parts.1])
                    },
                    onJoin: {
                        guard index + 1 < units.count,
                              units[index + 1].separator != "\n\n" else { return }
                        units[index].text += units[index + 1].separator + units[index + 1].text
                        units.remove(at: index + 1)
                    }
                )
            }
        }
    }
}

private struct ProseUnitRow: View {
    let index: Int
    let unit: ProseUnit
    let prompt: String
    let isNewCard: Bool
    let canJoin: Bool
    let onSplit: (Int) -> Void
    let onJoin: () -> Void

    @State private var splitAfter = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Card \(index + 1)" + (index == 0 ? " · Opening unit" : "") + (isNewCard ? " · New card" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            if unit.separator == "\n\n" {
                Text("New paragraph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(prompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(unit.text)
                .font(.body)
                .textSelection(.enabled)
            if positionCount > 1 || canJoin {
                DisclosureGroup("Adjust boundary") {
                    VStack(alignment: .leading, spacing: 8) {
                        if positionCount > 1 {
                            Stepper(
                                "Split after \(usesWords ? "word" : "character") \(splitAfter)",
                                value: $splitAfter,
                                in: 1...(positionCount - 1)
                            )
                            let parts = ProseText.split(unit, afterWord: splitAfter)
                            if let parts {
                                Text("\(parts.0.text) | \(parts.1.text)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Button("Split here") { onSplit(splitAfter) }
                                .accessibilityIdentifier("proseSplit\(index)")
                        }
                        if canJoin {
                            Button("Join with next unit") { onJoin() }
                                .accessibilityIdentifier("proseJoin\(index)")
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: positionCount) { _, count in
            splitAfter = min(max(splitAfter, 1), max(count - 1, 1))
        }
    }

    private var usesWords: Bool { ProseText.wordCount(unit.text) > 1 }
    private var positionCount: Int { ProseText.splitPositionCount(unit.text) }
}
