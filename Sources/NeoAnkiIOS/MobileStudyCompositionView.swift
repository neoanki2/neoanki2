#if os(iOS)
import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct MobileStudyCompositionView: View {
    let template: Template
    let item: Item
    let mediaStore: MediaStore?
    let isAnswerRevealed: Bool

    private var components: [ResolvedTemplateComponent] {
        SideContent.resolvedComponents(for: template, from: item).filter {
            isAnswerRevealed || $0.purpose != .expectedAnswer
        }
    }

    private var effectiveLayout: CardLayoutID {
        StudyStageGeometry.effectiveLayout(for: template, item: item)
    }

    var body: some View {
        GeometryReader { proxy in
            composition(width: proxy.size.width)
                .frame(maxWidth: 680, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func composition(width: CGFloat) -> some View {
        switch effectiveLayout {
        case .focus:
            focusComposition
        case .actionStage:
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                region(.label)
                region(.primary, font: .largeTitle)
                region(.supporting, font: .body)
                if isAnswerRevealed { region(.secondary, font: .title) }
                Spacer(minLength: 0)
            }
        case .split:
            if StudyStageGeometry.usesVerticalSplit(for: .split, width: width) {
                VStack(spacing: 16) { question; answer }
            } else {
                HStack(spacing: 16) { question; answer }
            }
        case .mediaAside:
            if StudyStageGeometry.usesVerticalSplit(for: .mediaAside, width: width) {
                VStack(spacing: 16) { media; question }
            } else {
                HStack(spacing: 16) {
                    question
                    media.frame(width: width * StudyStageGeometry.mediaFraction(for: .mediaAside, width: width))
                }
            }
        case .mediaHero:
            VStack(spacing: 14) {
                media.frame(maxHeight: .infinity).layoutPriority(1)
                region(.primary, font: .title)
                region(.supporting, font: .body)
                if isAnswerRevealed { region(.secondary, font: .title2) }
            }
        }
    }

    private var focusComposition: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            if isAnswerRevealed {
                region(.secondary, font: .largeTitle)
                region(.primary, font: .title2)
                    .foregroundStyle(.secondary)
                region(.supporting, font: .body, purpose: .expectedAnswer)
            } else {
                region(.label)
                region(.primary, font: .largeTitle)
                region(.supporting, font: .body)
            }
            Spacer(minLength: 0)
        }
    }

    private var question: some View {
        VStack(spacing: 12) {
            region(.label, font: .caption)
            region(.primary, font: .largeTitle)
            region(.supporting, font: .body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var answer: some View {
        Group {
            if isAnswerRevealed {
                region(.secondary, font: .title)
            } else {
                Label("Answer concealed", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }

    private var media: some View {
        region(.media)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func region(
        _ region: ComponentRegion,
        font: Font? = nil,
        purpose: ComponentPurpose? = nil
    ) -> some View {
        let matching = components.filter {
            $0.region == region && (purpose == nil || $0.purpose == purpose)
        }
        VStack(spacing: 10) {
            ForEach(matching) { component in
                MobileContentValueView(
                    value: component.value,
                    mediaStore: mediaStore,
                    mediaBehavior: component.presentation.media,
                    revealMode: component.presentation.reveal,
                    isAnswerRevealed: isAnswerRevealed
                )
                .accessibilitySortPriority(priority(for: region))
            }
        }
        .font(font)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func priority(for region: ComponentRegion) -> Double {
        let order = StudyStageGeometry.accessibilityRegions(
            for: effectiveLayout,
            answerRevealed: isAnswerRevealed
        )
        guard let index = order.firstIndex(of: region) else { return 0 }
        return Double(order.count - index)
    }
}
#endif
