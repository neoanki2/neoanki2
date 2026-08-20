import Foundation
import NeoAnkiCore
import NeoAnkiSharedUI
import Testing

@Test("Every code-owned composition preset has deterministic responsive geometry")
func compositionPresetGeometry() {
    #expect(CardLayoutID.allCases == [.focus, .split, .mediaAside, .mediaHero, .actionStage])
    #expect(StudyStageGeometry.usesVerticalSplit(for: .mediaAside, width: 500))
    #expect(!StudyStageGeometry.usesVerticalSplit(for: .mediaAside, width: 900))
    #expect(StudyStageGeometry.usesVerticalSplit(for: .split, width: 420))
    #expect(!StudyStageGeometry.usesVerticalSplit(for: .split, width: 900))
    #expect(StudyStageGeometry.mediaFraction(for: .mediaHero, width: 320) == 0.58)
    #expect(StudyStageGeometry.mediaFraction(for: .mediaAside, width: 900) == 0.44)
}

@Test("Proportional layout metrics reserve the declared media fraction")
func cardWireframeProportionalGeometry() {
    let hero = CardWireframeLayoutMetrics.proportionalSections(
        total: 500,
        spacing: 16,
        trailingFraction: 0.58
    )
    #expect(hero.trailing == 290)
    #expect(hero.leading == 194)
    #expect(hero.leading + 16 + hero.trailing == 500)

    let aside = CardWireframeLayoutMetrics.proportionalSections(
        total: 900,
        spacing: 24,
        trailingFraction: 0.44
    )
    #expect(aside.trailing == 396)
    #expect(aside.leading == 480)
    #expect(aside.leading + 24 + aside.trailing == 900)
}

@Test("Compact Media Aside consumes its descriptor fraction in vertical layout metrics")
func compactMediaAsideUsesDescriptorFraction() throws {
    let descriptor = CardWireframeDescriptor.descriptor(for: .mediaAside)
    let allocation = try #require(CardWireframeLayoutMetrics.verticalMediaSections(
        total: 500,
        spacing: 16,
        geometry: descriptor.geometry
    ))

    #expect(allocation.trailing == 190)
    #expect(allocation.leading == 294)
    #expect(allocation.leading + 16 + allocation.trailing == 500)
}

@Test("Proportional layout metrics stay finite for constrained stages")
func cardWireframeProportionalGeometryClampsInputs() {
    #expect(CardWireframeLayoutMetrics.proportionalSections(
        total: 10,
        spacing: 24,
        trailingFraction: 0.58
    ) == .init(leading: 0, trailing: 0))
    #expect(CardWireframeLayoutMetrics.proportionalSections(
        total: 100,
        spacing: 10,
        trailingFraction: 2
    ) == .init(leading: 0, trailing: 90))
}

@Test("Every layout descriptor has one valid mapping for every named hole")
func cardWireframeDescriptorsAreComplete() {
    for layout in CardLayoutID.allCases {
        let descriptor = CardWireframeDescriptor.descriptor(for: layout)
        #expect(descriptor.layout == layout)
        #expect(descriptor.holes.map(\.hole) == CardWireframeHole.allCases)
        #expect(Set(descriptor.holes.map(\.region)) == Set(ComponentRegion.allCases))
        #expect(descriptor.accessibilityHoles.map(\.accessibilityOrder) == Array(0 ..< 5))
        #expect(descriptor.regionOrder.count == ComponentRegion.allCases.count)

        for hole in descriptor.holes {
            let frame = hole.thumbnailFrame
            #expect(frame.x >= 0 && frame.y >= 0)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(frame.x + frame.width <= 1)
            #expect(frame.y + frame.height <= 1)
        }
    }
}

@Test("Named holes expose deterministic canonical insertion metadata")
func cardWireframeCanonicalInsertion() {
    let descriptor = CardWireframeDescriptor.descriptor(for: .focus)
    #expect(descriptor.canonicalInsertion(for: .instruction) == .init(region: .label, purpose: .supporting))
    #expect(descriptor.canonicalInsertion(for: .question) == .init(region: .primary, purpose: .question))
    #expect(descriptor.canonicalInsertion(for: .media) == .init(region: .media, purpose: .question))
    #expect(descriptor.canonicalInsertion(for: .context) == .init(region: .supporting, purpose: .supporting))
    #expect(descriptor.canonicalInsertion(for: .answer) == .init(region: .secondary, purpose: .expectedAnswer))
}

@Test("Render plans preserve authored order and conceal answers by purpose in every region")
func cardWireframeRenderPlanPreservesAndConceals() {
    let components = ComponentRegion.allCases.enumerated().flatMap { index, region in
        [
            resolvedComponent(
                marker: "question-\(index)",
                region: region,
                purpose: .question
            ),
            resolvedComponent(
                marker: "answer-\(index)",
                region: region,
                purpose: .expectedAnswer
            ),
        ]
    }

    for layout in CardLayoutID.allCases {
        let descriptor = CardWireframeDescriptor.descriptor(for: layout)
        let concealed = descriptor.renderedComponents(from: components, answerRevealed: false)
        let revealed = descriptor.renderedComponents(from: components, answerRevealed: true)

        #expect(concealed.count == ComponentRegion.allCases.count)
        #expect(concealed.allSatisfy { $0.component.purpose != .expectedAnswer })
        #expect(concealed.map(\.authoredIndex) == concealed.map(\.authoredIndex).sorted())
        #expect(revealed.count == components.count)
        #expect(Set(revealed.map(\.id)).count == components.count)
        #expect(revealed.map(\.authoredIndex) == Array(components.indices))
        #expect(revealed.filter { $0.phase == .answer }.count == ComponentRegion.allCases.count)
    }
}

@Test("Media Aside includes its answer hole after reveal")
func mediaAsideRendersAnswer() {
    let answer = resolvedComponent(
        marker: "answer",
        region: .secondary,
        purpose: .expectedAnswer
    )
    let descriptor = CardWireframeDescriptor.descriptor(for: .mediaAside)

    #expect(descriptor.renderedComponents(from: [answer], answerRevealed: false).isEmpty)
    let revealed = descriptor.renderedComponents(from: [answer], answerRevealed: true)
    #expect(revealed.count == 1)
    #expect(revealed.first?.hole == .answer)
}

@Test("Split answer panel preserves visible noncanonical secondary content")
func splitAnswerPanelConcealsOnlyExpectedAnswers() {
    let secondaryQuestion = resolvedComponent(
        marker: "visible question",
        region: .secondary,
        purpose: .question
    )
    let secondarySupporting = resolvedComponent(
        marker: "visible context",
        region: .secondary,
        purpose: .supporting
    )
    let expectedAnswer = resolvedComponent(
        marker: "private answer",
        region: .secondary,
        purpose: .expectedAnswer
    )
    let components = [secondaryQuestion, expectedAnswer, secondarySupporting]
    let descriptor = CardWireframeDescriptor.descriptor(for: .split)

    let concealed = descriptor.answerPanelProjection(
        from: components,
        answerRevealed: false
    )
    #expect(concealed.visibleComponents.map(\.id) == [secondaryQuestion.id, secondarySupporting.id])
    #expect(concealed.visibleComponents.allSatisfy { $0.hole == .answer })
    #expect(concealed.hasConcealedExpectedAnswer)

    let revealed = descriptor.answerPanelProjection(
        from: components,
        answerRevealed: true
    )
    #expect(revealed.visibleComponents.map(\.id) == components.map(\.id))
    #expect(!revealed.hasConcealedExpectedAnswer)
}

@Test("Media presets collapse when an item's optional media is empty")
func compositionPresetEmptyMediaFallback() {
    let text = FieldDef(name: "Text", type: .text, isRequired: true)
    let image = FieldDef(name: "Image", type: .image, isRequired: false)
    let mediaComponent = TemplateComponent(
        region: .media,
        purpose: .question,
        source: .field(image.id)
    )
    let textComponent = TemplateComponent(
        region: .primary,
        purpose: .question,
        source: .field(text.id)
    )
    let recordTemplate = Template(
        name: "Record with optional image",
        layout: .mediaAside,
        components: [mediaComponent, textComponent],
        interaction: .record,
        skill: Skill(input: .text, output: .audio, operation: .reproduce)
    )
    let revealTemplate = Template(
        name: "Reveal with optional image",
        layout: .mediaHero,
        components: [mediaComponent, textComponent],
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recall)
    )
    let itemWithoutImage = Item(
        itemTypeID: UUID(),
        fields: [
            FieldValue(fieldID: text.id, value: .text("Question")),
            FieldValue(fieldID: image.id, value: .empty),
        ]
    )
    let itemWithImage = Item(
        itemTypeID: UUID(),
        fields: [
            FieldValue(fieldID: text.id, value: .text("Question")),
            FieldValue(
                fieldID: image.id,
                value: .media(MediaRef(
                    kind: .image,
                    assetHash: String(repeating: "a", count: 64),
                    fileExtension: "jpg",
                    altText: "Diagram"
                ))
            ),
        ]
    )

    #expect(StudyStageGeometry.effectiveLayout(for: recordTemplate, item: itemWithoutImage) == .actionStage)
    #expect(StudyStageGeometry.effectiveLayout(for: revealTemplate, item: itemWithoutImage) == .focus)
    #expect(StudyStageGeometry.effectiveLayout(for: recordTemplate, item: itemWithImage) == .mediaAside)
    #expect(StudyStageGeometry.effectiveLayout(for: revealTemplate, item: itemWithImage) == .mediaHero)
}

@Test("Accessibility order is deterministic while reveal remains purpose-based")
func compositionAccessibilityOrder() {
    let before = StudyStageGeometry.accessibilityRegions(
        for: .split,
        answerRevealed: false
    )
    let after = StudyStageGeometry.accessibilityRegions(
        for: .split,
        answerRevealed: true
    )
    #expect(before == after)
    #expect(after.firstIndex(of: .primary)! < after.firstIndex(of: .secondary)!)

    let focusBefore = StudyStageGeometry.accessibilityRegions(
        for: .focus,
        answerRevealed: false
    )
    let focusAfter = StudyStageGeometry.accessibilityRegions(
        for: .focus,
        answerRevealed: true
    )
    #expect(focusBefore == [.label, .primary, .media, .supporting, .secondary])
    #expect(focusAfter == focusBefore)
}

@Test("Legacy definitions map to the five presets and protect expected answers")
func deterministicCompositionMapping() {
    let text = FieldDef(name: "Text", type: .text, isRequired: true)
    let other = FieldDef(name: "Other", type: .text, isRequired: false)
    let image = FieldDef(name: "Image", type: .image, isRequired: false)
    let answer = Side(slots: [Slot(source: .field(other.id))])

    let focus = TemplateCompositionMigration.map(
        prompt: Side(slots: [Slot(source: .field(text.id))]),
        answer: answer,
        interaction: .reveal,
        fields: [text, other, image]
    )
    #expect(focus.layout == .focus)

    let split = TemplateCompositionMigration.map(
        prompt: Side(slots: [Slot(source: .literal("Label")), Slot(source: .field(text.id))]),
        answer: answer,
        interaction: .reveal,
        fields: [text, other, image]
    )
    #expect(split.layout == .split)
    #expect(split.components.first?.purpose == .supporting)
    #expect(split.components[1].purpose == .question)

    let hero = TemplateCompositionMigration.map(
        prompt: Side(slots: [Slot(source: .field(image.id))]),
        answer: answer,
        interaction: .reveal,
        fields: [text, other, image]
    )
    #expect(hero.layout == .mediaHero)

    let aside = TemplateCompositionMigration.map(
        prompt: Side(slots: [Slot(source: .field(image.id)), Slot(source: .field(text.id))]),
        answer: answer,
        interaction: .reveal,
        fields: [text, other, image]
    )
    #expect(aside.layout == .mediaAside)

    let action = TemplateCompositionMigration.map(
        prompt: Side(slots: [Slot(source: .field(text.id))]),
        answer: answer,
        interaction: .record,
        fields: [text, other, image]
    )
    #expect(action.layout == .actionStage)
    #expect(action.components.filter { $0.purpose == .expectedAnswer }.allSatisfy {
        $0.presentation.reveal != .always
    })
}

private func resolvedComponent(
    marker: String,
    region: ComponentRegion,
    purpose: ComponentPurpose
) -> ResolvedTemplateComponent {
    ResolvedTemplateComponent(
        id: UUID(),
        region: region,
        purpose: purpose,
        value: .text(marker),
        presentation: Presentation()
    )
}
