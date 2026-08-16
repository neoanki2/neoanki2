import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct GradeGuideView: View {
    let gradingMode: StudyGradingMode

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("How to grade")
                .font(DesignSystem.Typography.uiTitle)

            Text("After you reveal or check your answer, pick the option that best matches how well you recalled it. NeoAnki2 uses your choice to schedule the next review.")
                .font(DesignSystem.Typography.uiBody)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(gradingMode.choices, id: \.rating) { choice in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Text(choice.title)
                        .font(DesignSystem.Typography.uiBody.bold())
                        .frame(width: 52, alignment: .leading)
                    Text(choice.guidance)
                        .font(DesignSystem.Typography.uiBody)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Keyboard: Space or Return to reveal; \(gradeShortcutSummary) to grade; ⌘Z to undo the last grade; Escape to end session; → to skip unsupported cards; ⌘⇧S to start study.")
                .font(DesignSystem.Typography.uiCaption)
                .foregroundStyle(.tertiary)
        }
        .padding(DesignSystem.Spacing.studyHorizontal)
        .frame(width: 360)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("gradeGuidePanel")
    }

    private var gradeShortcutSummary: String {
        gradingMode == .passFail ? "1–2" : "1–4"
    }

    private var accessibilitySummary: String {
        let choices = gradingMode.choices.map(\.title).joined(separator: ", ")
        let keys = gradingMode == .passFail ? "1 and 2" : "1 through 4"
        return "How to grade. After you reveal your answer, pick \(choices). Keyboard shortcuts: Space or Return to reveal, \(keys) to grade, Command Z to undo the last grade, Escape to end session, Right Arrow to skip unsupported cards, Command Shift S to start study."
    }
}
