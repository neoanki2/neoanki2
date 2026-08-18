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
        case .reveal, .type, .cloze:
            return .focus
        }
    }

    public static func mediaFraction(for layout: CardLayoutID, width: CGFloat) -> CGFloat {
        switch layout {
        case .mediaAside: width < 680 ? 0.38 : 0.44
        case .mediaHero: 0.58
        case .focus, .split, .actionStage: 0
        }
    }

    public static func usesVerticalSplit(for layout: CardLayoutID, width: CGFloat) -> Bool {
        switch layout {
        case .mediaAside: width < 680
        case .split: width < 560
        case .focus, .mediaHero, .actionStage: true
        }
    }

    public static func accessibilityRegions(
        for layout: CardLayoutID,
        answerRevealed: Bool
    ) -> [ComponentRegion] {
        var result: [ComponentRegion]
        switch layout {
        case .mediaAside, .mediaHero:
            result = [.label, .primary, .media, .supporting]
        case .split:
            result = [.label, .primary, .secondary, .supporting, .media]
        case .focus:
            result = answerRevealed
                ? [.primary, .secondary, .supporting, .media, .label]
                : [.label, .primary, .supporting, .media]
        case .actionStage:
            result = [.label, .primary, .supporting, .media, .secondary]
        }
        if !answerRevealed { result.removeAll(where: { $0 == .secondary }) }
        return result
    }
}

private struct StudyStageMeasuredSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

/// A non-scrolling active study surface with a fixed footer. If Dynamic Type,
/// localization, or unusually long content cannot fit, the stage offers a
/// region-aware detail sheet instead of turning review into a scrolling page.
public struct AdaptiveStudyStage<Stage: View, Footer: View>: View {
    private let layout: CardLayoutID
    private let detailTitle: String
    private let stage: Stage
    private let footer: Footer
    @State private var measuredSize: CGSize = .zero
    @State private var availableSize: CGSize = .zero
    @State private var showsFullContent = false

    public init(
        layout: CardLayoutID,
        detailTitle: String = "Full card content",
        @ViewBuilder stage: () -> Stage,
        @ViewBuilder footer: () -> Footer
    ) {
        self.layout = layout
        self.detailTitle = detailTitle
        self.stage = stage()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background {
                        stage
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { measured in
                                Color.clear.preference(
                                    key: StudyStageMeasuredSizeKey.self,
                                    value: measured.size
                                )
                            })
                            .hidden()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if overflows {
                            Button("View full content", systemImage: "arrow.up.left.and.arrow.down.right") {
                                showsFullContent = true
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonStyle(.bordered)
                            .padding(12)
                            .accessibilityHint("Opens the complete card in a scrollable sheet")
                        }
                    }
                    .onAppear { availableSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in availableSize = size }
            }

            Divider()

            footer
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial)
        }
        .onPreferenceChange(StudyStageMeasuredSizeKey.self) { measuredSize = $0 }
        .sheet(isPresented: $showsFullContent) {
            NavigationStack {
                ScrollView {
                    stage
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
                .navigationTitle(detailTitle)
                .toolbar {
                    Button("Done") { showsFullContent = false }
                }
            }
            .frame(minWidth: 360, minHeight: 420)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layout.displayName) study layout")
    }

    private var overflows: Bool {
        guard availableSize.height > 0 else { return false }
        return measuredSize.height > availableSize.height + 1
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
