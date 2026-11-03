import NeoAnkiCore
import SwiftUI

/// Stable geometry for the five code-owned study compositions. Template data
/// chooses a preset and assigns ingredients; it cannot inject arbitrary layout.
public enum StudyStageGeometry {
    /// Media presets describe the template's preferred geometry, but optional
    /// media can be empty on an individual item. In that case, collapse the
    /// unused media region instead of reserving a blank column or hero area.
    public static func effectiveLayout(for template: Template, item: Item) -> CardLayoutID {
        guard template.layout == .mediaAside || template.layout == .mediaHero else {
            return template.layout
        }
        let hasResolvedMedia = SideContent.resolvedComponents(for: template, from: item)
            .contains { $0.region == .media }
        guard !hasResolvedMedia else { return template.layout }

        switch template.interaction {
        case .record, .audioSubmission, .choose, .arrange:
            return .actionStage
        case .reveal, .type, .cloze, .imageOcclusion:
            return .focus
        }
    }

    public static func mediaFraction(for layout: CardLayoutID, width: CGFloat) -> CGFloat {
        switch CardWireframeDescriptor.descriptor(for: layout).geometry {
        case let .mediaAside(compactWidth, compact, regular):
            width < compactWidth ? compact : regular
        case let .mediaHero(fraction):
            fraction
        case .focus, .split, .actionStage:
            0
        }
    }

    public static func usesVerticalSplit(for layout: CardLayoutID, width: CGFloat) -> Bool {
        switch CardWireframeDescriptor.descriptor(for: layout).geometry {
        case let .mediaAside(compactWidth, _, _), let .split(compactWidth):
            width < compactWidth
        case .focus, .mediaHero, .actionStage:
            true
        }
    }

    public static func accessibilityRegions(
        for layout: CardLayoutID,
        answerRevealed: Bool
    ) -> [ComponentRegion] {
        _ = answerRevealed
        return CardWireframeDescriptor.descriptor(for: layout).regionOrder
    }
}

/// The fixed vertical regions inside every active study template. The card
/// composition is the only flexible region; response, status, and evaluation
/// content always keeps its intrinsic height.
public struct StudyStageContent<Composition: View, Response: View>: View {
    private let spacing: CGFloat
    private let composition: Composition
    private let response: Response

    public init(
        spacing: CGFloat,
        @ViewBuilder composition: () -> Composition,
        @ViewBuilder response: () -> Response
    ) {
        self.spacing = spacing
        self.composition = composition()
        self.response = response()
    }

    public var body: some View {
        // A flexible composition must accept the viewport's height instead of
        // contributing its ideal height to the window's minimum content size.
        StudyRegionLayout(spacing: spacing) {
            GeometryReader { viewport in
                composition.frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
            }

            response
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }
}

/// A fixed study surface whose stage receives only the space left after the
/// footer reserves its intrinsic height. Card templates own their internal
/// regions; this shell never scrolls, scales, or repositions their content.
public struct AdaptiveStudyStage<Stage: View, Footer: View>: View {
    private let layout: CardLayoutID
    private let stage: Stage
    private let footer: Footer

    public init(
        layout: CardLayoutID,
        @ViewBuilder stage: () -> Stage,
        @ViewBuilder footer: () -> Footer
    ) {
        self.layout = layout
        self.stage = stage()
        self.footer = footer()
    }

    public var body: some View {
        StudyRegionLayout(spacing: 0) {
            GeometryReader { viewport in
                stage.frame(width: viewport.size.width, height: viewport.size.height)
                    .clipped()
            }

            VStack(spacing: 0) {
                Divider()
                footer
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("studyFooter")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layout.displayName) study layout")
    }
}

/// The first child may consume only the space left by the second child. Using
/// an explicit allocation prevents oversized content from moving controls off
/// the bottom edge or increasing the enclosing window's minimum height.
private struct StudyRegionLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let fixed = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? fixed.width,
                      height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? fixed.height + spacing + 10)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let fixed = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let fixedHeight = min(bounds.height, fixed.height)
        let flexibleHeight = max(0, bounds.height - fixedHeight - spacing)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: flexibleHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - fixedHeight), anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: fixedHeight))
    }
}

public extension CardLayoutID {
    var displayName: String {
        switch self {
        case .focus: "Focus"
        case .split: "Split"
        case .mediaAside: "Media Aside"
        case .mediaHero: "Media Hero"
        case .actionStage: "Action Stage"
        }
    }

    var guidance: String {
        switch self {
        case .focus: "One clear question with a compact reveal."
        case .split: "Comparable question and answer regions."
        case .mediaAside: "Visual media beside supporting study content."
        case .mediaHero: "A single dominant visual with minimal text."
        case .actionStage: "A prompt organized around a learner action."
        }
    }
}
