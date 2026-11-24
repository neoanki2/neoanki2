import NeoAnkiCore
import SwiftUI

package struct ScopeCardCountsView: View {
    private let summary: ScopeSummary

    package init(summary: ScopeSummary) {
        self.summary = summary
    }

    private var suspendedCount: Int {
        summary.cardCount - summary.newCount - summary.inLearningCount - summary.reviewCount
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(summary.cardCount) total \(summary.cardCount == 1 ? "card" : "cards")")
                .font(.subheadline.weight(.semibold))

            Group {
                // A recovery snapshot retains scheduling totals even when
                // maturity evidence for active cards could not be read.
                if summary.maturity.activeCardCount == summary.cardCount - suspendedCount {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { breakdown }
                        VStack(alignment: .leading, spacing: 4) { breakdown }
                    }
                } else {
                    Text("Card breakdown unavailable")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scopeHomeCardStates")
    }

    @ViewBuilder
    private var breakdown: some View {
        let maturity = summary.maturity
        let learning = maturity.activeCardCount - maturity.notStartedCardCount - maturity.maintainingCardCount
        Text("\(maturity.notStartedCardCount) new")
        Text("\(learning) learning")
        Text("\(maturity.maintainingCardCount) mature")
        if suspendedCount > 0 {
            Text("\(suspendedCount) suspended")
        }
    }
}
