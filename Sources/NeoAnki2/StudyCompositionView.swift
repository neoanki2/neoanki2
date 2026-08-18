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
                .frame(maxWidth: 820, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
                .padding(.vertical, DesignSystem.Spacing.lg)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func composition(width: CGFloat) -> some View {
        switch effectiveLayout {
        case .focus:
            focusComposition
        case .split:
            if StudyStageGeometry.usesVerticalSplit(for: .split, width: width) {
                VStack(spacing: DesignSystem.Spacing.lg) { questionPanel; answerPanel }
            } else {
                HStack(spacing: DesignSystem.Spacing.lg) { questionPanel; answerPanel }
            }
        case .mediaAside:
            if StudyStageGeometry.usesVerticalSplit(for: .mediaAside, width: width) {
                VStack(spacing: DesignSystem.Spacing.md) { mediaPanel; questionPanel }
            } else {
                HStack(spacing: DesignSystem.Spacing.lg) {
                    questionPanel
                    mediaPanel
                        .frame(width: width * StudyStageGeometry.mediaFraction(for: .mediaAside, width: width))
                }
            }
        case .mediaHero:
            VStack(spacing: DesignSystem.Spacing.md) {
                mediaPanel
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                region(.primary, font: DesignSystem.Typography.cardPrompt)
                region(.supporting)
                if isAnswerRevealed { region(.secondary, font: DesignSystem.Typography.cardAnswer) }
            }
        case .actionStage:
            VStack(spacing: DesignSystem.Spacing.md) {
                Spacer(minLength: 0)
                region(.label)
                region(.primary, font: DesignSystem.Typography.cardPrompt)
                region(.supporting)
                if isAnswerRevealed { region(.secondary, font: DesignSystem.Typography.cardAnswer) }
                Spacer(minLength: 0)
            }
        }
    }

    private var focusComposition: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer(minLength: 0)
            if isAnswerRevealed {
                region(
                    .secondary,
                    font: DesignSystem.Typography.cardPrompt,
                    richTextPointSize: DesignSystem.Typography.cardPromptPointSize
                )
                region(
                    .primary,
                    font: DesignSystem.Typography.cardSecondary,
                    richTextPointSize: DesignSystem.Typography.cardSecondaryPointSize
                )
                .foregroundStyle(.secondary)
                region(
                    .supporting,
                    font: DesignSystem.Typography.uiBody,
                    purpose: .expectedAnswer,
                    richTextPointSize: DesignSystem.Typography.richTextPointSize
                )
            } else {
                region(.label)
                region(.primary, font: DesignSystem.Typography.cardPrompt)
                region(.supporting)
            }
            Spacer(minLength: 0)
        }
    }

    private var questionPanel: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            region(.label)
            region(.primary, font: DesignSystem.Typography.cardPrompt)
            region(.supporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var answerPanel: some View {
        Group {
            if isAnswerRevealed {
                region(.secondary, font: DesignSystem.Typography.cardAnswer)
            } else {
                Label("Answer concealed", systemImage: "eye.slash")
                    .font(DesignSystem.Typography.uiSecondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.md)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }

    private var mediaPanel: some View {
        region(.media)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func region(
        _ region: ComponentRegion,
        font: Font? = nil,
        purpose: ComponentPurpose? = nil,
        richTextPointSize: CGFloat? = nil
    ) -> some View {
        let matching = components.filter {
            $0.region == region && (purpose == nil || $0.purpose == purpose)
        }
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(matching) { component in
                ContentValueView(
                    value: component.value,
                    presentation: component.presentation,
                    isAnswerRevealed: isAnswerRevealed,
                    richTextPointSize: richTextPointSize ?? (region == .primary
                        ? DesignSystem.Typography.cardPromptPointSize
                        : DesignSystem.Typography.cardAnswerPointSize),
                    mediaStore: mediaStore,
                    clozeGroup: clozeGroup
                )
                .accessibilitySortPriority(accessibilityPriority(for: region))
            }
        }
        .font(font)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(region.accessibilityName)
    }

    private func accessibilityPriority(for region: ComponentRegion) -> Double {
        let order = StudyStageGeometry.accessibilityRegions(
            for: effectiveLayout,
            answerRevealed: isAnswerRevealed
        )
        guard let index = order.firstIndex(of: region) else { return 0 }
        return Double(order.count - index)
    }
}

private extension ComponentRegion {
    var accessibilityName: String {
        switch self {
        case .primary: "Question"
        case .secondary: "Answer"
        case .media: "Media"
        case .supporting: "Supporting content"
        case .label: "Label"
        }
    }
}
