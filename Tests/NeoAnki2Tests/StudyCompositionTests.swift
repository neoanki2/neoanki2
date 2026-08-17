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

@Test("Accessibility order is stable and conceals answer regions before reveal")
func compositionAccessibilityOrder() {
    let before = StudyStageGeometry.accessibilityRegions(
        for: .split,
        answerRevealed: false
    )
    let after = StudyStageGeometry.accessibilityRegions(
        for: .split,
        answerRevealed: true
    )
    #expect(!before.contains(.secondary))
    #expect(after.firstIndex(of: .primary)! < after.firstIndex(of: .secondary)!)
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
