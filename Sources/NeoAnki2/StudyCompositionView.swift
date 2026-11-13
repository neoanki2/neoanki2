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

    private var components: [ResolvedTemplateComponent] {
        SideContent.resolvedComponents(for: template, from: item)
    }

    private var effectiveLayout: CardLayoutID {
        StudyStageGeometry.effectiveLayout(for: template, item: item)
    }

    var body: some View {
        StudyCardViewport(fitsMedia: hasVisibleVisualMedia) {
            wireframe
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private var hasVisibleVisualMedia: Bool {
        CardWireframeDescriptor.descriptor(for: effectiveLayout)
            .renderedComponents(from: components, answerRevealed: isAnswerRevealed)
            .contains { rendered in
                switch rendered.component.value {
                case .imageOcclusion: true
                case let .media(ref): ref.kind != .audio
                default: false
                }
            }
    }

    private var wireframe: some View {
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
                isStudyContent: true,
                occlusionGroup: occlusionGroup,
                clozeGroup: clozeGroup
            )
            // Inherit the wireframe's study font. A local font(nil) resets it
            // to the small UI default, including on unrelated poetry cards.
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
}

/// Images need a finite height proposal to aspect-fit. Measuring the entire
/// card with fixedSize first instead gives tall diagrams their natural height.
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
