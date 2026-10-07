#if os(iOS)
import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct MobileStudyCompositionView: View {
    let template: Template
    let item: Item
    let mediaStore: MediaStore?
    let isAnswerRevealed: Bool
    var occlusionGroup: Int? = nil
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
            isAnswerRevealed: isAnswerRevealed,
            mobileReading: true
        ) { component, _ in
            MobileContentValueView(
                value: component.value,
                mediaStore: mediaStore,
                mediaBehavior: component.presentation.media,
                revealMode: component.presentation.reveal,
                isAnswerRevealed: isAnswerRevealed,
                isStudyContent: true,
                occlusionGroup: occlusionGroup,
                clozeGroup: clozeGroup
            )
        }
        .cardWireframeIntrinsicSizing(referenceHeight: 240)
        .frame(maxWidth: 600)
    }
}
#endif
