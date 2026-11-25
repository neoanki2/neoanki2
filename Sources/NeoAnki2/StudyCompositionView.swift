import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct StudyCompositionView: View {
    let template: Template
    let item: Item
    let isAnswerRevealed: Bool
    let mediaStore: MediaStore?
    var occlusionGroup: Int? = nil
    let clozeGroup: Int?
    var response: String? = nil
    var evaluation: AnswerEvaluation? = nil

    private var components: [ResolvedTemplateComponent] {
        SideContent.resolvedComponents(for: template, from: item)
    }

    private var effectiveLayout: CardLayoutID {
        StudyStageGeometry.effectiveLayout(for: template, item: item)
    }

    var body: some View {
        StudyCardViewport(
            fitsMedia: fitsVisualPromptInViewport || (template.fitStudyArea && !isAnswerRevealed)
        ) {
            wireframe
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private var fitsVisualPromptInViewport: Bool {
        let visible = CardWireframeDescriptor.descriptor(for: effectiveLayout)
            .renderedComponents(from: components, answerRevealed: isAnswerRevealed)
        // Occlusion needs its entire coordinate space on screen. An ordinary
        // image can share the scrolling reader with text at its natural size.
        if template.interaction == .imageOcclusion { return true }
        return !visible.isEmpty && visible.allSatisfy { rendered in
            switch rendered.component.value {
            case .imageOcclusion: true
            case let .media(ref): ref.kind != .audio
            default: false
            }
        }
    }

    private var wireframe: some View {
        StudyAnswerReview(
            layout: effectiveLayout,
            components: components,
            isAnswerRevealed: isAnswerRevealed,
            response: response,
            evaluation: evaluation,
            enabled: [.type, .choose, .arrange].contains(template.interaction)
        ) { component, hole in
            let content = ContentValueView(
                value: component.value,
                presentation: component.presentation,
                isAnswerRevealed: isAnswerRevealed,
                richTextPointSize: richTextPointSize(for: hole),
                mediaStore: mediaStore,
                isStudyContent: true,
                occlusionGroup: occlusionGroup,
                clozeGroup: clozeGroup
            )
            if shouldFitPrompt(component, hole: hole), case .text = component.value {
                StudyAreaFittedPrompt { content }
            } else {
                content
            }
        }
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

    private func shouldFitPrompt(
        _ component: ResolvedTemplateComponent,
        hole: CardWireframeHole
    ) -> Bool {
        template.fitStudyArea && !isAnswerRevealed
            && hole == .question && component.purpose == .question
    }
}

/// An image-only prompt fits in the viewport. A mixed card has to keep its
/// text at full height so the reader can scroll past the available space.
struct StudyCardViewport<Card: View>: View {
    let fitsMedia: Bool
    @ViewBuilder let card: Card

    var body: some View {
        if fitsMedia {
            card
        } else {
            ViewThatFits(in: .vertical) {
                card
                    .cardWireframeIntrinsicSizing()
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    card.cardWireframeIntrinsicSizing()
                }
            }
        }
    }
}
