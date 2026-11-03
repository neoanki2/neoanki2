import NeoAnkiCore
import NeoAnkiSharedUI
import SwiftUI

struct StudyCompositionView: View {
    @State private var showsFullCard = false
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
        ViewThatFits(in: .vertical) {
            wireframe
                .cardWireframeIntrinsicSizing()
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("This card needs more room.")
                    .font(DesignSystem.Typography.uiBody)
                Button("Read Full Card") { showsFullCard = true }
                    .accessibilityIdentifier("readFullStudyCard")
            }
        }
        .frame(maxWidth: DesignSystem.readingColumnMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSystem.Spacing.studyHorizontal)
        .padding(.vertical, DesignSystem.Spacing.lg)
        .sheet(isPresented: $showsFullCard) {
            VStack(spacing: 0) {
                ScrollView {
                    wireframe
                        .cardWireframeIntrinsicSizing()
                        .padding(DesignSystem.Spacing.lg)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showsFullCard = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(DesignSystem.Spacing.md)
            }
            .frame(minWidth: 480, idealWidth: 640, minHeight: 360, idealHeight: 560)
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
            .font(component.purpose == .supporting
                  ? (hole == .instruction ? DesignSystem.Typography.uiCaption : DesignSystem.Typography.uiBody)
                  : nil)
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
