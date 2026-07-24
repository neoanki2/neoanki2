import NeoAnkiCore
import SwiftUI

struct GradeGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("How to grade")
                .font(DesignSystem.Typography.uiTitle)

            Text("After you reveal or check your answer, pick the option that best matches how well you recalled it. NeoAnki2 uses your choice to schedule the next review.")
                .font(DesignSystem.Typography.uiBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(ReviewRating.allCases, id: \.self) { rating in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Text(rating.studyButtonTitle)
                        .font(DesignSystem.Typography.uiBody.bold())
                        .frame(width: 52, alignment: .leading)
                    Text(rating.studyTooltip)
                        .font(DesignSystem.Typography.uiBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Keyboard: Space or Return to reveal; 1–4 to grade; ⌘⇧S to start study.")
                .font(DesignSystem.Typography.uiCaption)
                .foregroundStyle(.tertiary)
        }
        .padding(DesignSystem.Spacing.studyHorizontal)
        .frame(width: 360)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How to grade. After you reveal your answer, pick Again, Hard, Good, or Easy. Keyboard shortcuts: Space or Return to reveal, 1 through 4 to grade, Command Shift S to start study.")
    }
}
