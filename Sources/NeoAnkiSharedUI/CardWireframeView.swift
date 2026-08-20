import NeoAnkiCore
import SwiftUI

/// The five semantic holes exposed by every code-owned card wireframe.
///
/// A hole is an authoring and rendering concept only. Persisted templates keep
/// using ``ComponentRegion`` and are never rewritten when a wireframe is shown.
public enum CardWireframeHole: String, CaseIterable, Identifiable, Sendable {
    case instruction
    case question
    case media
    case context
    case answer

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .instruction: "Instruction"
        case .question: "Question"
        case .media: "Media"
        case .context: "Context"
        case .answer: "Answer"
        }
    }
}

public enum CardWireframeRevealPhase: Int, CaseIterable, Sendable {
    case question
    case answer
}

/// A normalized frame used by layout thumbnails. Values are expressed in the
/// closed range 0...1 so the same metadata scales on macOS and iOS.
public struct CardWireframeThumbnailFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CardWireframeHoleDescriptor: Equatable, Identifiable, Sendable {
    public let hole: CardWireframeHole
    public let region: ComponentRegion
    public let accessibilityOrder: Int
    public let thumbnailFrame: CardWireframeThumbnailFrame

    public var id: CardWireframeHole { hole }

    public init(
        hole: CardWireframeHole,
        region: ComponentRegion,
        accessibilityOrder: Int,
        thumbnailFrame: CardWireframeThumbnailFrame
    ) {
        self.hole = hole
        self.region = region
        self.accessibilityOrder = accessibilityOrder
        self.thumbnailFrame = thumbnailFrame
    }
}

public struct CardWireframeInsertion: Equatable, Sendable {
    public let region: ComponentRegion
    public let purpose: ComponentPurpose

    public init(region: ComponentRegion, purpose: ComponentPurpose) {
        self.region = region
        self.purpose = purpose
    }
}

public enum CardWireframeGeometry: Equatable, Sendable {
    case focus
    case split(compactWidth: CGFloat)
    case mediaAside(compactWidth: CGFloat, compactMediaFraction: CGFloat, regularMediaFraction: CGFloat)
    case mediaHero(mediaFraction: CGFloat)
    case actionStage
}

/// Deterministic axis allocation shared by the custom layouts and headless
/// geometry tests. Fractions are measured against the complete stage axis;
/// spacing is then removed from the complementary section.
public struct CardWireframeAxisAllocation: Equatable, Sendable {
    public let leading: CGFloat
    public let trailing: CGFloat

    public init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }
}

public enum CardWireframeLayoutMetrics {
    public static func proportionalSections(
        total: CGFloat,
        spacing: CGFloat,
        trailingFraction: CGFloat
    ) -> CardWireframeAxisAllocation {
        let total = max(0, total)
        let spacing = min(max(0, spacing), total)
        let fraction = min(max(0, trailingFraction), 1)
        let trailing = min(total - spacing, total * fraction)
        return CardWireframeAxisAllocation(
            leading: max(0, total - spacing - trailing),
            trailing: trailing
        )
    }

    /// Resolves the media/content allocation for a vertically stacked media
    /// wireframe. Media Aside deliberately uses its compact fraction here,
    /// while Media Hero uses its single media fraction at every width.
    public static func verticalMediaSections(
        total: CGFloat,
        spacing: CGFloat,
        geometry: CardWireframeGeometry
    ) -> CardWireframeAxisAllocation? {
        let mediaFraction: CGFloat
        switch geometry {
        case let .mediaAside(_, compactMediaFraction, _):
            mediaFraction = compactMediaFraction
        case let .mediaHero(heroMediaFraction):
            mediaFraction = heroMediaFraction
        case .focus, .split, .actionStage:
            return nil
        }
        return proportionalSections(
            total: total,
            spacing: spacing,
            trailingFraction: mediaFraction
        )
    }
}

public struct CardWireframeRenderedComponent: Equatable, Identifiable, Sendable {
    public let component: ResolvedTemplateComponent
    public let hole: CardWireframeHole
    public let phase: CardWireframeRevealPhase
    public let authoredIndex: Int

    public var id: UUID { component.id }

    public init(
        component: ResolvedTemplateComponent,
        hole: CardWireframeHole,
        phase: CardWireframeRevealPhase,
        authoredIndex: Int
    ) {
        self.component = component
        self.hole = hole
        self.phase = phase
        self.authoredIndex = authoredIndex
    }
}

public struct CardWireframeAnswerPanelProjection: Equatable, Sendable {
    public let visibleComponents: [CardWireframeRenderedComponent]
    public let hasConcealedExpectedAnswer: Bool

    public init(
        visibleComponents: [CardWireframeRenderedComponent],
        hasConcealedExpectedAnswer: Bool
    ) {
        self.visibleComponents = visibleComponents
        self.hasConcealedExpectedAnswer = hasConcealedExpectedAnswer
    }
}

/// Complete, deterministic metadata for one of the five static card layouts.
public struct CardWireframeDescriptor: Equatable, Identifiable, Sendable {
    public let layout: CardLayoutID
    public let geometry: CardWireframeGeometry
    public let holes: [CardWireframeHoleDescriptor]

    public var id: CardLayoutID { layout }

    public var regionOrder: [ComponentRegion] {
        accessibilityHoles.map { descriptor in
            descriptor.region
        }
    }

    public var accessibilityHoles: [CardWireframeHoleDescriptor] {
        holes.sorted { lhs, rhs in
            lhs.accessibilityOrder < rhs.accessibilityOrder
        }
    }

    public static func descriptor(for layout: CardLayoutID) -> Self {
        switch layout {
        case .focus:
            Self(
                layout: layout,
                geometry: .focus,
                frames: [
                    .instruction: .init(x: 0.20, y: 0.08, width: 0.60, height: 0.10),
                    .question: .init(x: 0.12, y: 0.22, width: 0.76, height: 0.23),
                    .media: .init(x: 0.28, y: 0.48, width: 0.44, height: 0.15),
                    .context: .init(x: 0.20, y: 0.66, width: 0.60, height: 0.09),
                    .answer: .init(x: 0.12, y: 0.79, width: 0.76, height: 0.13),
                ]
            )
        case .split:
            Self(
                layout: layout,
                geometry: .split(compactWidth: 560),
                frames: [
                    .instruction: .init(x: 0.06, y: 0.10, width: 0.40, height: 0.10),
                    .question: .init(x: 0.06, y: 0.25, width: 0.40, height: 0.25),
                    .media: .init(x: 0.06, y: 0.54, width: 0.18, height: 0.18),
                    .context: .init(x: 0.27, y: 0.56, width: 0.19, height: 0.14),
                    .answer: .init(x: 0.54, y: 0.10, width: 0.40, height: 0.62),
                ]
            )
        case .mediaAside:
            Self(
                layout: layout,
                geometry: .mediaAside(
                    compactWidth: 680,
                    compactMediaFraction: 0.38,
                    regularMediaFraction: 0.44
                ),
                frames: [
                    .instruction: .init(x: 0.05, y: 0.10, width: 0.48, height: 0.10),
                    .question: .init(x: 0.05, y: 0.25, width: 0.48, height: 0.22),
                    .media: .init(x: 0.60, y: 0.10, width: 0.35, height: 0.62),
                    .context: .init(x: 0.05, y: 0.51, width: 0.48, height: 0.09),
                    .answer: .init(x: 0.05, y: 0.64, width: 0.48, height: 0.13),
                ]
            )
        case .mediaHero:
            Self(
                layout: layout,
                geometry: .mediaHero(mediaFraction: 0.58),
                frames: [
                    .instruction: .init(x: 0.18, y: 0.60, width: 0.64, height: 0.07),
                    .question: .init(x: 0.12, y: 0.69, width: 0.76, height: 0.10),
                    .media: .init(x: 0.10, y: 0.07, width: 0.80, height: 0.49),
                    .context: .init(x: 0.18, y: 0.81, width: 0.64, height: 0.06),
                    .answer: .init(x: 0.12, y: 0.89, width: 0.76, height: 0.08),
                ]
            )
        case .actionStage:
            Self(
                layout: layout,
                geometry: .actionStage,
                frames: [
                    .instruction: .init(x: 0.20, y: 0.12, width: 0.60, height: 0.10),
                    .question: .init(x: 0.12, y: 0.26, width: 0.76, height: 0.20),
                    .media: .init(x: 0.30, y: 0.49, width: 0.40, height: 0.15),
                    .context: .init(x: 0.20, y: 0.67, width: 0.60, height: 0.09),
                    .answer: .init(x: 0.12, y: 0.80, width: 0.76, height: 0.13),
                ]
            )
        }
    }

    public func hole(for region: ComponentRegion) -> CardWireframeHole {
        holes.first(where: { $0.region == region })?.hole ?? .context
    }

    /// The canonical mapping used only when an author explicitly inserts or
    /// moves content into a named hole. Reading an existing template never
    /// applies this mapping and therefore never normalizes legacy content.
    public func canonicalInsertion(for hole: CardWireframeHole) -> CardWireframeInsertion {
        switch hole {
        case .instruction:
            .init(region: .label, purpose: .supporting)
        case .question:
            .init(region: .primary, purpose: .question)
        case .media:
            .init(region: .media, purpose: .question)
        case .context:
            .init(region: .supporting, purpose: .supporting)
        case .answer:
            .init(region: .secondary, purpose: .expectedAnswer)
        }
    }

    public func revealPhase(for purpose: ComponentPurpose) -> CardWireframeRevealPhase {
        purpose == .expectedAnswer ? .answer : .question
    }

    /// Produces a stable, lossless render plan. Authored order is retained
    /// within every region and each visible component occurs exactly once.
    public func renderedComponents(
        from components: [ResolvedTemplateComponent],
        answerRevealed: Bool
    ) -> [CardWireframeRenderedComponent] {
        components.enumerated().compactMap { index, component in
            let phase = revealPhase(for: component.purpose)
            guard answerRevealed || phase == .question else { return nil }
            return CardWireframeRenderedComponent(
                component: component,
                hole: hole(for: component.region),
                phase: phase,
                authoredIndex: index
            )
        }
    }

    /// Split's secondary region may contain unusual question/supporting
    /// components as well as expected answers. Only the expected-answer phase
    /// is concealed; visible authored content must remain in the panel.
    public func answerPanelProjection(
        from components: [ResolvedTemplateComponent],
        answerRevealed: Bool
    ) -> CardWireframeAnswerPanelProjection {
        let visible = renderedComponents(
            from: components,
            answerRevealed: answerRevealed
        ).filter { $0.hole == .answer }
        let hasConcealedExpectedAnswer = !answerRevealed && components.contains { component in
            hole(for: component.region) == .answer && component.purpose == .expectedAnswer
        }
        return CardWireframeAnswerPanelProjection(
            visibleComponents: visible,
            hasConcealedExpectedAnswer: hasConcealedExpectedAnswer
        )
    }

    private init(
        layout: CardLayoutID,
        geometry: CardWireframeGeometry,
        frames: [CardWireframeHole: CardWireframeThumbnailFrame]
    ) {
        self.layout = layout
        self.geometry = geometry
        let order: [CardWireframeHole] = [.instruction, .question, .media, .context, .answer]
        holes = order.enumerated().map { index, hole in
            guard let thumbnailFrame = frames[hole] else {
                preconditionFailure("Missing thumbnail frame for \(hole.rawValue)")
            }
            return CardWireframeHoleDescriptor(
                hole: hole,
                region: Self.region(for: hole),
                accessibilityOrder: index,
                thumbnailFrame: thumbnailFrame
            )
        }
    }

    private static func region(for hole: CardWireframeHole) -> ComponentRegion {
        switch hole {
        case .instruction: .label
        case .question: .primary
        case .media: .media
        case .context: .supporting
        case .answer: .secondary
        }
    }
}

/// The single responsive implementation used by study and authoring surfaces.
/// Platform shells provide content-value rendering while this view owns layout,
/// purpose-based reveal, hole order, and accessibility order.
public struct CardWireframeView<ComponentView: View>: View {
    @Environment(\.cardWireframeSizingMode) private var sizingMode

    private let descriptor: CardWireframeDescriptor
    private let components: [ResolvedTemplateComponent]
    private let isAnswerRevealed: Bool
    private let emptyHoleView: ((CardWireframeHole) -> AnyView?)?
    private let componentView: (ResolvedTemplateComponent, CardWireframeHole) -> ComponentView

    public init(
        layout: CardLayoutID,
        components: [ResolvedTemplateComponent],
        isAnswerRevealed: Bool,
        emptyHoleView: ((CardWireframeHole) -> AnyView?)? = nil,
        @ViewBuilder componentView: @escaping (
            ResolvedTemplateComponent,
            CardWireframeHole
        ) -> ComponentView
    ) {
        descriptor = .descriptor(for: layout)
        self.components = components
        self.isAnswerRevealed = isAnswerRevealed
        self.emptyHoleView = emptyHoleView
        self.componentView = componentView
    }

    public var body: some View {
        composition
            .frame(
                maxWidth: .infinity,
                maxHeight: sizingMode.fillsAvailableHeight ? .infinity : nil
            )
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(descriptor.layout.displayName) card layout")
    }

    @ViewBuilder
    private var composition: some View {
        switch descriptor.geometry {
        case .focus:
            centeredContent(spacing: 24)
        case let .split(compactWidth):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { questionPanel; answerPanel }
                    .frame(minWidth: compactWidth)
                VStack(spacing: 24) { questionPanel; answerPanel }
            }
        case let .mediaAside(compactWidth, _, regularMediaFraction):
            ViewThatFits(in: .horizontal) {
                CardWireframeProportionalHStack(
                    trailingFraction: regularMediaFraction,
                    spacing: 24
                ) {
                    mediaAsideContent
                    mediaPanel
                }
                .frame(minWidth: compactWidth)
                CardWireframeVerticalMediaLayout(
                    geometry: descriptor.geometry,
                    spacing: 16,
                    sizingMode: sizingMode
                ) {
                    mediaPanel
                    mediaAsideContent
                }
            }
        case let .mediaHero(mediaFraction):
            CardWireframeVerticalMediaLayout(
                geometry: .mediaHero(mediaFraction: mediaFraction),
                spacing: 16,
                sizingMode: sizingMode
            ) {
                mediaPanel
                VStack(spacing: 16) {
                    hole(.instruction)
                    hole(.question)
                    hole(.context)
                    hole(.answer)
                }
            }
        case .actionStage:
            centeredContent(spacing: 16)
        }
    }

    private func centeredContent(spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            Spacer(minLength: 0)
            hole(.instruction)
            hole(.question)
            hole(.media)
            hole(.context)
            hole(.answer)
            Spacer(minLength: 0)
        }
    }

    private var questionPanel: some View {
        VStack(spacing: 16) {
            hole(.instruction)
            hole(.question)
            hole(.media)
            hole(.context)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var answerPanel: some View {
        let projection = descriptor.answerPanelProjection(
            from: components,
            answerRevealed: isAnswerRevealed
        )
        return VStack(spacing: 12) {
            hole(.answer)
            if projection.hasConcealedExpectedAnswer {
                Label("Answer concealed", systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Answer concealed")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }

    private var mediaAsideContent: some View {
        VStack(spacing: 16) {
            hole(.instruction)
            hole(.question)
            hole(.context)
            hole(.answer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mediaPanel: some View {
        hole(.media)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func hole(_ hole: CardWireframeHole) -> some View {
        let renderedComponents = visibleComponents(in: hole)
        let hasAuthoredContent = !authoredComponents(in: hole).isEmpty
        let emptyContent = emptyHoleView?(hole)
        VStack(spacing: 8) {
            if renderedComponents.isEmpty && !hasAuthoredContent {
                emptyContent
            } else {
                ForEach(renderedComponents) { rendered in
                    componentView(rendered.component, hole)
                }
            }
        }
        .font(font(for: hole))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hole.displayName)
        .accessibilityHidden(
            renderedComponents.isEmpty
                && (hasAuthoredContent || emptyContent == nil)
        )
        .accessibilitySortPriority(accessibilityPriority(for: hole))
    }

    private func visibleComponents(
        in hole: CardWireframeHole
    ) -> [CardWireframeRenderedComponent] {
        descriptor.renderedComponents(
            from: components,
            answerRevealed: isAnswerRevealed
        ).filter { $0.hole == hole }
    }

    private func authoredComponents(
        in hole: CardWireframeHole
    ) -> [CardWireframeRenderedComponent] {
        descriptor.renderedComponents(
            from: components,
            answerRevealed: true
        ).filter { $0.hole == hole }
    }

    private func accessibilityPriority(for hole: CardWireframeHole) -> Double {
        guard let index = descriptor.accessibilityHoles.firstIndex(where: { $0.hole == hole }) else {
            return 0
        }
        return Double(descriptor.holes.count - index)
    }

    private func font(for hole: CardWireframeHole) -> Font? {
        switch hole {
        case .instruction: .caption
        case .question: .largeTitle
        case .media: nil
        case .context: .body
        case .answer: .title
        }
    }
}

enum CardWireframeSizingMode: Equatable {
    case bounded
    case intrinsic(referenceHeight: CGFloat?)

    var fillsAvailableHeight: Bool {
        if case .bounded = self { return true }
        return false
    }

    var referenceHeight: CGFloat? {
        guard case let .intrinsic(referenceHeight) = self else { return nil }
        return referenceHeight
    }
}

private struct CardWireframeSizingModeKey: EnvironmentKey {
    static let defaultValue = CardWireframeSizingMode.bounded
}

extension EnvironmentValues {
    var cardWireframeSizingMode: CardWireframeSizingMode {
        get { self[CardWireframeSizingModeKey.self] }
        set { self[CardWireframeSizingModeKey.self] = newValue }
    }
}

private struct CardWireframeProportionalHStack: Layout {
    let trailingFraction: CGFloat
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let idealLeading = subviews[0].sizeThatFits(.unspecified)
        let idealTrailing = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width
            ?? idealLeading.width + spacing + idealTrailing.width
        let allocation = CardWireframeLayoutMetrics.proportionalSections(
            total: width,
            spacing: spacing,
            trailingFraction: trailingFraction
        )
        let leading = subviews[0].sizeThatFits(ProposedViewSize(
            width: allocation.leading,
            height: proposal.height
        ))
        let trailing = subviews[1].sizeThatFits(ProposedViewSize(
            width: allocation.trailing,
            height: proposal.height
        ))
        return CGSize(
            width: width,
            height: proposal.height ?? max(leading.height, trailing.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let allocation = CardWireframeLayoutMetrics.proportionalSections(
            total: bounds.width,
            spacing: spacing,
            trailingFraction: trailingFraction
        )
        let childHeight = proposal.height ?? bounds.height
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: allocation.leading, height: childHeight)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + allocation.leading + spacing, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: allocation.trailing, height: childHeight)
        )
    }
}

private struct CardWireframeVerticalMediaLayout: Layout {
    let geometry: CardWireframeGeometry
    let spacing: CGFloat
    let sizingMode: CardWireframeSizingMode

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? max(
            subviews[0].sizeThatFits(.unspecified).width,
            subviews[1].sizeThatFits(.unspecified).width
        )
        if let height = proposal.height, sizingMode.fillsAvailableHeight {
            return CGSize(width: width, height: height)
        }

        let mediaIntrinsic = subviews[0].sizeThatFits(ProposedViewSize(
            width: width,
            height: nil
        )).height
        let reservedMediaHeight = sizingMode.referenceHeight.map { referenceHeight in
            CardWireframeLayoutMetrics.verticalMediaSections(
                total: referenceHeight,
                spacing: spacing,
                geometry: geometry
            )?.trailing ?? 0
        } ?? 0
        let mediaHeight = max(mediaIntrinsic, reservedMediaHeight)
        let contentHeight = subviews[1].sizeThatFits(ProposedViewSize(
            width: width,
            height: nil
        )).height
        return CGSize(
            width: width,
            height: mediaHeight + (mediaHeight > 0 && contentHeight > 0 ? spacing : 0) + contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let mediaHeight: CGFloat
        let contentHeight: CGFloat
        if sizingMode.fillsAvailableHeight {
            let allocation = CardWireframeLayoutMetrics.verticalMediaSections(
                total: bounds.height,
                spacing: spacing,
                geometry: geometry
            ) ?? .init(leading: bounds.height, trailing: 0)
            mediaHeight = allocation.trailing
            contentHeight = allocation.leading
        } else {
            let mediaIntrinsic = subviews[0].sizeThatFits(ProposedViewSize(
                width: bounds.width,
                height: nil
            )).height
            let reservedMediaHeight = sizingMode.referenceHeight.map { referenceHeight in
                CardWireframeLayoutMetrics.verticalMediaSections(
                    total: referenceHeight,
                    spacing: spacing,
                    geometry: geometry
                )?.trailing ?? 0
            } ?? 0
            mediaHeight = max(mediaIntrinsic, reservedMediaHeight)
            contentHeight = subviews[1].sizeThatFits(ProposedViewSize(
                width: bounds.width,
                height: nil
            )).height
        }
        let interSectionSpacing = mediaHeight > 0 && contentHeight > 0 ? spacing : 0
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: mediaHeight)
        )
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX,
                y: bounds.minY + mediaHeight + interSectionSpacing
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: contentHeight)
        )
    }
}
