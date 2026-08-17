import Foundation

/// A declarative recipe for producing one card from an item. Templates store
/// semantic components and a code-owned layout preset rather than markup or an
/// unbounded prompt/answer document.
public struct Template: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var layout: CardLayoutID
    public var components: [TemplateComponent]
    public var interaction: Interaction
    public var skill: Skill
    public var generateWhen: SlotCondition?

    public init(
        id: UUID = UUID(),
        name: String,
        layout: CardLayoutID,
        components: [TemplateComponent],
        interaction: Interaction,
        skill: Skill,
        generateWhen: SlotCondition? = nil
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.components = components
        self.interaction = interaction
        self.skill = skill
        self.generateWhen = generateWhen
    }

    /// Source compatibility for authored builders and API v1 projections.
    /// New persisted definitions encode only `layout` and `components`.
    public init(
        id: UUID = UUID(),
        name: String,
        prompt: Side,
        answer: Side,
        interaction: Interaction,
        skill: Skill,
        generateWhen: SlotCondition? = nil
    ) {
        let composition = TemplateCompositionMigration.map(
            prompt: prompt,
            answer: answer,
            interaction: interaction,
            fields: []
        )
        self.init(
            id: id,
            name: name,
            layout: composition.layout,
            components: composition.components,
            interaction: interaction,
            skill: skill,
            generateWhen: generateWhen
        )
    }

    /// API/import projection. It is deliberately computed so the local
    /// database cannot silently persist the legacy document representation.
    public var prompt: Side {
        get {
            Side(slots: components.compactMap { component in
                guard component.purpose != .expectedAnswer else { return nil }
                return Slot(source: component.source, presentation: component.presentation)
            })
        }
        set {
            let answers = components.filter { $0.purpose == .expectedAnswer }
            let mapped = TemplateCompositionMigration.map(
                prompt: newValue,
                answer: Side(slots: answers.map {
                    Slot(source: $0.source, presentation: $0.presentation)
                }),
                interaction: interaction,
                fields: []
            )
            components = mapped.components
        }
    }

    public var answer: Side {
        get {
            Side(slots: components.compactMap { component in
                guard component.purpose == .expectedAnswer else { return nil }
                return Slot(source: component.source, presentation: component.presentation)
            })
        }
        set {
            let projectedPrompt = Side(slots: components.compactMap { component in
                guard component.purpose != .expectedAnswer else { return nil }
                return Slot(source: component.source, presentation: component.presentation)
            })
            let mapped = TemplateCompositionMigration.map(
                prompt: projectedPrompt,
                answer: newValue,
                interaction: interaction,
                fields: []
            )
            components = mapped.components
        }
    }
}

public enum CardLayoutID: String, Codable, CaseIterable, Sendable {
    case focus
    case split
    case mediaAside
    case mediaHero
    case actionStage
}

public enum ComponentRegion: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
    case media
    case supporting
    case label
}

public enum ComponentPurpose: String, Codable, CaseIterable, Sendable {
    case question
    case expectedAnswer
    case supporting
}

public struct TemplateComponent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var region: ComponentRegion
    public var purpose: ComponentPurpose
    public var source: SlotSource
    public var presentation: Presentation

    public init(
        id: UUID = UUID(),
        region: ComponentRegion,
        purpose: ComponentPurpose,
        source: SlotSource,
        presentation: Presentation = Presentation()
    ) {
        self.id = id
        self.region = region
        self.purpose = purpose
        self.source = source
        self.presentation = presentation
    }
}

public struct TemplateComposition: Equatable, Sendable {
    public let layout: CardLayoutID
    public let components: [TemplateComponent]

    public init(layout: CardLayoutID, components: [TemplateComponent]) {
        self.layout = layout
        self.components = components
    }
}

/// Shared deterministic conversion used by source-compatible initializers,
/// old portable/authored imports, and the one-shot local-library migrator.
public enum TemplateCompositionMigration {
    public static func map(
        prompt: Side,
        answer: Side,
        interaction: Interaction,
        fields: [FieldDef]
    ) -> TemplateComposition {
        let fieldsByID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        let allSlots = prompt.slots + answer.slots
        let visualCount = allSlots.filter { slot in
            visualSource(slot.source, fieldsByID: fieldsByID)
        }.count
        let dominantVisualPrompt = prompt.slots.count == 1 && visualCount == 1
        let actionHeavy = [Interaction.record, .audioSubmission, .choose, .arrange]
            .contains(interaction)
        let layout: CardLayoutID
        if visualCount > 0 {
            layout = dominantVisualPrompt ? .mediaHero : .mediaAside
        } else if actionHeavy {
            layout = .actionStage
        } else if prompt.slots.count > 1 || answer.slots.count > 1 {
            layout = .split
        } else {
            layout = .focus
        }

        var components: [TemplateComponent] = []
        let questionIndex = prompt.slots.firstIndex { slot in
            if case .field = slot.source { return true }
            return false
        } ?? prompt.slots.firstIndex { isUsableQuestion($0.source) }
        for (index, slot) in prompt.slots.enumerated() {
            let isVisual = visualSource(slot.source, fieldsByID: fieldsByID)
            let purpose: ComponentPurpose = index == questionIndex ? .question : .supporting
            components.append(TemplateComponent(
                region: isVisual ? .media : (purpose == .question ? .primary : .supporting),
                purpose: purpose,
                source: slot.source,
                presentation: slot.presentation
            ))
        }
        if questionIndex == nil, !components.isEmpty {
            components[0].purpose = .question
            if components[0].region != .media { components[0].region = .primary }
        }

        for (index, slot) in answer.slots.enumerated() {
            var presentation = slot.presentation
            if presentation.reveal == .always {
                presentation.reveal = .hiddenUntilAnswer
            }
            components.append(TemplateComponent(
                region: visualSource(slot.source, fieldsByID: fieldsByID)
                    ? .media
                    : (index == 0 ? .secondary : .supporting),
                purpose: .expectedAnswer,
                source: slot.source,
                presentation: presentation
            ))
        }
        return TemplateComposition(layout: layout, components: components)
    }

    private static func isUsableQuestion(_ source: SlotSource) -> Bool {
        switch source {
        case .field:
            true
        case let .literal(value):
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func visualSource(
        _ source: SlotSource,
        fieldsByID: [UUID: FieldDef]
    ) -> Bool {
        guard case let .field(id) = source,
              let kind = fieldsByID[id]?.type.mediaKind else { return false }
        return kind == .image || kind == .gif || kind == .video
    }
}

/// Legacy source projection used by API v1 and old import formats.
public struct Side: Codable, Equatable, Sendable {
    public var slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }
}

public struct Slot: Codable, Equatable, Sendable {
    public var source: SlotSource
    public var presentation: Presentation

    public init(source: SlotSource, presentation: Presentation = Presentation()) {
        self.source = source
        self.presentation = presentation
    }
}

public enum SlotSource: Codable, Equatable, Sendable {
    case field(UUID)
    case literal(String)
}

public struct Presentation: Codable, Equatable, Sendable {
    public var reveal: RevealMode
    public var media: MediaBehavior

    public init(reveal: RevealMode = .always, media: MediaBehavior = .default) {
        self.reveal = reveal
        self.media = media
    }
}

public enum RevealMode: String, Codable, CaseIterable, Sendable {
    case always
    case hiddenUntilAnswer
    case blurred
}

public enum MediaBehavior: String, Codable, CaseIterable, Sendable {
    case `default`
    case autoplay
    case playOnTap
    case loop

    public static func supported(for kind: MediaKind?) -> [MediaBehavior] {
        switch kind {
        case .audio, .gif, .video:
            allCases
        case .image, nil:
            [.default]
        }
    }

    public func isSupported(for kind: MediaKind?) -> Bool {
        Self.supported(for: kind).contains(self)
    }
}

public enum Interaction: String, Codable, CaseIterable, Sendable {
    case reveal
    case type
    case choose
    case record
    case audioSubmission
    case cloze
    case arrange
}

public indirect enum SlotCondition: Codable, Equatable, Sendable {
    case fieldNotEmpty(UUID)
    case fieldEmpty(UUID)
    case all([SlotCondition])
    case any([SlotCondition])
}
