import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct StudyCompositionView: View {
    let template: Template
    let item: Item
    let isAnswerRevealed: Bool
    let mediaStore: MediaStore?
    let clozeGroup: Int?

    private var components: [ResolvedTemplateComponent] {
        SideContent.resolvedComponents(for: template, from: item)
    }

    private var effectiveLayout: CardLayoutID {
        StudyStageGeometry.effectiveLayout(for: template, item: item)
    }

    var body: some View {
        CardWireframeView(
            layout: effectiveLayout,
            components: components,
            isAnswerRevealed: isAnswerRevealed
        ) { component, hole in
            ContentValueView(
                value: component.value,
                presentation: component.presentation,
                isAnswerRevealed: isAnswerRevealed,
                richTextPointSize: richTextPointSize(for: hole),
                mediaStore: mediaStore,
                clozeGroup: clozeGroup
            )
        }
        .frame(maxWidth: 820, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private func richTextPointSize(for hole: CardWireframeHole) -> CGFloat {
        switch hole {
        case .question:
            DesignSystem.Typography.cardPromptPointSize
        case .answer:
            DesignSystem.Typography.cardAnswerPointSize
        case .instruction, .media, .context:
            DesignSystem.Typography.richTextPointSize
        }
    }
}
