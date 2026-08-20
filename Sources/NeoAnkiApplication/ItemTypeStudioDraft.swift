import Foundation
import NeoAnkiCore

/// An editable field definition that preserves the stable identity used by stored items.
public struct ItemTypeFieldDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var type: FieldType
    public var isRequired: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: FieldType = .text,
        isRequired: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isRequired = isRequired
    }

    public init(field: FieldDef) {
        id = field.id
        name = field.name
        type = field.type
        isRequired = field.isRequired
    }

    public var fieldDefinition: FieldDef {
        FieldDef(id: id, name: name, type: type, isRequired: isRequired)
    }
}

/// A visible, non-drag field-ordering action shared by every Studio shell.
public enum ItemTypeStudioFieldMoveDirection: Sendable {
    case up
    case down
}

/// A component source may temporarily be incomplete while a field is being chosen.
public enum CardSetupComponentSourceDraft: Equatable, Sendable {
    case field(UUID?)
    case fixedText(String)

    public init(source: SlotSource) {
        switch source {
        case let .field(id): self = .field(id)
        case let .literal(value): self = .fixedText(value)
        }
    }

    public var fieldID: UUID? {
        guard case let .field(id) = self else { return nil }
        return id
    }

    public var slotSource: SlotSource? {
        switch self {
        case let .field(id): id.map(SlotSource.field)
        case let .fixedText(value):
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : .literal(value)
        }
    }
}

/// An editable card component. Region, purpose, presentation, and identity are never
/// inferred again for existing definitions, which makes an untouched save lossless.
public struct CardSetupComponentDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public private(set) var source: CardSetupComponentSourceDraft
    public var region: ComponentRegion
    public var purpose: ComponentPurpose
    public var reveal: RevealMode
    public var mediaBehavior: MediaBehavior
    fileprivate var preservesPersistedLiteral: Bool

    public init(
        id: UUID = UUID(),
        source: CardSetupComponentSourceDraft = .field(nil),
        region: ComponentRegion = .primary,
        purpose: ComponentPurpose = .question,
        reveal: RevealMode = .always,
        mediaBehavior: MediaBehavior = .default
    ) {
        self.id = id
        self.source = source
        self.region = region
        self.purpose = purpose
        self.reveal = reveal
        self.mediaBehavior = mediaBehavior
        preservesPersistedLiteral = false
    }

    public init(component: TemplateComponent) {
        id = component.id
        source = CardSetupComponentSourceDraft(source: component.source)
        region = component.region
        purpose = component.purpose
        reveal = component.presentation.reveal
        mediaBehavior = component.presentation.media
        if case .literal = component.source {
            preservesPersistedLiteral = true
        } else {
            preservesPersistedLiteral = false
        }
    }

    public func templateComponent() throws -> TemplateComponent {
        guard let source = resolvedSlotSource else {
            throw ItemTypeStudioDraftError.incompleteComponent(id)
        }
        return TemplateComponent(
            id: id,
            region: region,
            purpose: purpose,
            source: source,
            presentation: Presentation(reveal: reveal, media: mediaBehavior)
        )
    }

    /// Records an explicit authoring choice. Unlike untouched persisted literals,
    /// newly selected blank fixed text remains incomplete until the user fills it.
    public mutating func setSource(_ source: CardSetupComponentSourceDraft) {
        self.source = source
        preservesPersistedLiteral = false
    }

    public mutating func setFixedText(_ value: String) {
        setSource(.fixedText(value))
    }

    fileprivate var resolvedSlotSource: SlotSource? {
        if preservesPersistedLiteral, case let .fixedText(value) = source {
            return .literal(value)
        }
        return source.slotSource
    }
}

/// Editable form of Template.generateWhen. Optional leaf identities allow a field
/// removal to clear only affected mappings while preserving the original tree.
public indirect enum CardSetupAvailabilityDraft: Equatable, Sendable {
    case fieldPresent(UUID?)
    case fieldAbsent(UUID?)
    case all([CardSetupAvailabilityDraft])
    case any([CardSetupAvailabilityDraft])

    public init(condition: SlotCondition) {
        switch condition {
        case let .fieldNotEmpty(id): self = .fieldPresent(id)
        case let .fieldEmpty(id): self = .fieldAbsent(id)
        case let .all(children): self = .all(children.map(Self.init))
        case let .any(children): self = .any(children.map(Self.init))
        }
    }

    public var condition: SlotCondition? {
        switch self {
        case let .fieldPresent(id): id.map(SlotCondition.fieldNotEmpty)
        case let .fieldAbsent(id): id.map(SlotCondition.fieldEmpty)
        case let .all(children):
            Self.resolve(children, wrapping: SlotCondition.all)
        case let .any(children):
            Self.resolve(children, wrapping: SlotCondition.any)
        }
    }

    private static func resolve(
        _ children: [CardSetupAvailabilityDraft],
        wrapping: ([SlotCondition]) -> SlotCondition
    ) -> SlotCondition? {
        var conditions: [SlotCondition] = []
        conditions.reserveCapacity(children.count)
        for child in children {
            guard let condition = child.condition else { return nil }
            conditions.append(condition)
        }
        return wrapping(conditions)
    }

    public var referencedFieldIDs: Set<UUID> {
        switch self {
        case let .fieldPresent(id), let .fieldAbsent(id): Set(id.map { [$0] } ?? [])
        case let .all(children), let .any(children):
            children.reduce(into: Set<UUID>()) { $0.formUnion($1.referencedFieldIDs) }
        }
    }

    @discardableResult
    mutating func clearReference(to fieldID: UUID) -> Bool {
        switch self {
        case let .fieldPresent(id):
            guard id == fieldID else { return false }
            self = .fieldPresent(nil)
            return true
        case let .fieldAbsent(id):
            guard id == fieldID else { return false }
            self = .fieldAbsent(nil)
            return true
        case var .all(children):
            var changed = false
            for index in children.indices {
                changed = children[index].clearReference(to: fieldID) || changed
            }
            self = .all(children)
            return changed
        case var .any(children):
            var changed = false
            for index in children.indices {
                changed = children[index].clearReference(to: fieldID) || changed
            }
            self = .any(children)
            return changed
        }
    }
}

/// A non-destructive suggestion derived from the current question and answer.
public struct CardSetupRecommendation: Equatable, Sendable {
    public let layout: CardLayoutID
    public let learningRoute: Skill

    public init(layout: CardLayoutID, learningRoute: Skill) {
        self.layout = layout
        self.learningRoute = learningRoute
    }

    public static func make(
        components: [CardSetupComponentDraft],
        interaction: Interaction,
        fields: [ItemTypeFieldDraft]
    ) -> CardSetupRecommendation {
        let fieldsByID = Dictionary(fields.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in
            first
        })
        let question = components.first { $0.purpose == .question }
        let answer = components.first { $0.purpose == .expectedAnswer }
        let questionField = question?.source.fieldID.flatMap { fieldsByID[$0] }
        let answerField = answer?.source.fieldID.flatMap { fieldsByID[$0] }

        let hasVisual = components.contains { component in
            guard component.region == .media else { return false }
            guard let field = component.source.fieldID.flatMap({ fieldsByID[$0] }) else {
                return false
            }
            return [.image, .gif, .video].contains(field.type)
        }
        let layout: CardLayoutID
        if hasVisual {
            layout = components.count <= 2 ? .mediaHero : .mediaAside
        } else if [.record, .audioSubmission, .choose, .arrange].contains(interaction) {
            layout = .actionStage
        } else if components.count > 2 {
            layout = .split
        } else {
            layout = .focus
        }

        let input = questionField.map { modality(for: $0.type) } ?? .text
        let response = responseRoute(
            for: interaction,
            question: questionField,
            answer: answerField,
            fields: fields
        )
        return CardSetupRecommendation(
            layout: layout,
            learningRoute: Skill(
                input: input,
                output: response.output,
                operation: response.operation
            )
        )
    }

    private static func responseRoute(
        for interaction: Interaction,
        question: ItemTypeFieldDraft?,
        answer: ItemTypeFieldDraft?,
        fields: [ItemTypeFieldDraft]
    ) -> (output: Modality, operation: NeoAnkiCore.Operation) {
        switch interaction {
        case .reveal:
            return (
                answer.map { modality(for: $0.type) } ?? .text,
                operation(question: question, answer: answer, fields: fields)
            )
        case .type, .cloze:
            return (.freeResponse, .recall)
        case .choose:
            return (.selection, .classify)
        case .arrange:
            return (.sequence, .order)
        case .record, .audioSubmission:
            return (.audio, .reproduce)
        }
    }

    private static func modality(for type: FieldType) -> Modality {
        switch type {
        case .text, .richText, .number, .cloze: .text
        case .audio: .audio
        case .image, .gif: .image
        case .video: .video
        }
    }

    private static func operation(
        question: ItemTypeFieldDraft?,
        answer: ItemTypeFieldDraft?,
        fields: [ItemTypeFieldDraft]
    ) -> NeoAnkiCore.Operation {
        guard let question, let answer,
              let questionIndex = fields.firstIndex(where: { $0.id == question.id }),
              let answerIndex = fields.firstIndex(where: { $0.id == answer.id }) else {
            return .recognize
        }
        return questionIndex > answerIndex ? .recall : .recognize
    }
}

private struct AudioSubmissionAnswerStash: Equatable, Sendable {
    let generationID: UUID
    let answers: [(offset: Int, component: CardSetupComponentDraft)]
    let interaction: Interaction
    let learningRoute: Skill

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generationID == rhs.generationID
            && lhs.answers.map(\.offset) == rhs.answers.map(\.offset)
            && lhs.answers.map(\.component) == rhs.answers.map(\.component)
            && lhs.interaction == rhs.interaction
            && lhs.learningRoute == rhs.learningRoute
    }
}

/// One ordered, lossless editing representation of a persisted Template.
public struct CardSetupDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var layout: CardLayoutID
    public var interaction: Interaction
    public var learningRoute: Skill
    public var availability: CardSetupAvailabilityDraft?
    public var components: [CardSetupComponentDraft]
    public private(set) var recommendation: CardSetupRecommendation?
    public private(set) var isLayoutManuallySelected: Bool

    private var audioSubmissionAnswerStash: AudioSubmissionAnswerStash?

    public init(
        id: UUID = UUID(),
        name: String,
        layout: CardLayoutID,
        interaction: Interaction,
        learningRoute: Skill,
        availability: CardSetupAvailabilityDraft? = nil,
        components: [CardSetupComponentDraft],
        recommendation: CardSetupRecommendation? = nil,
        isLayoutManuallySelected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.interaction = interaction
        self.learningRoute = learningRoute
        self.availability = availability
        self.components = components
        self.recommendation = recommendation
        self.isLayoutManuallySelected = isLayoutManuallySelected
    }

    public init(template: Template) {
        id = template.id
        name = template.name
        layout = template.layout
        interaction = template.interaction
        learningRoute = template.skill
        availability = template.generateWhen.map(CardSetupAvailabilityDraft.init)
        components = template.components.map(CardSetupComponentDraft.init)
        recommendation = nil
        isLayoutManuallySelected = true
    }

    public mutating func chooseLayout(_ layout: CardLayoutID) {
        self.layout = layout
        isLayoutManuallySelected = true
    }

    /// Recomputes a suggestion without changing either stored layout or learning metadata.
    public mutating func refreshRecommendation(fields: [ItemTypeFieldDraft]) {
        recommendation = .make(components: components, interaction: interaction, fields: fields)
    }

    public mutating func useRecommendation() {
        guard let recommendation else { return }
        learningRoute = recommendation.learningRoute
    }

    mutating func discardTransientEditingHistory() {
        audioSubmissionAnswerStash = nil
    }

    var audioSubmissionAnswerStashGenerationID: UUID? {
        audioSubmissionAnswerStash?.generationID
    }

    mutating func discardAudioSubmissionAnswerStash(generations: Set<UUID>) {
        guard let generationID = audioSubmissionAnswerStash?.generationID,
              generations.contains(generationID) else { return }
        audioSubmissionAnswerStash = nil
    }

    var referencedFieldIDsIncludingStashedAnswers: Set<UUID> {
        var ids = Set(components.compactMap(\.source.fieldID))
        if let stash = audioSubmissionAnswerStash {
            ids.formUnion(stash.answers.compactMap(\.component.source.fieldID))
        }
        return ids
    }

    @discardableResult
    mutating func clearReferenceIncludingStashedAnswers(to fieldID: UUID) -> Set<UUID> {
        var cleared: Set<UUID> = []
        for index in components.indices where components[index].source.fieldID == fieldID {
            cleared.insert(components[index].id)
            components[index].setSource(.field(nil))
        }
        if var stash = audioSubmissionAnswerStash {
            stash = AudioSubmissionAnswerStash(
                generationID: stash.generationID,
                answers: stash.answers.map { saved in
                    var component = saved.component
                    if component.source.fieldID == fieldID {
                        cleared.insert(component.id)
                        component.setSource(.field(nil))
                    }
                    return (saved.offset, component)
                },
                interaction: stash.interaction,
                learningRoute: stash.learningRoute
            )
            audioSubmissionAnswerStash = stash
        }
        return cleared
    }

    mutating func stashUnsupportedMediaBehavior(
        referencing fieldID: UUID,
        for fieldType: FieldType
    ) -> [UUID: MediaBehavior] {
        var stashed: [UUID: MediaBehavior] = [:]
        for index in components.indices
            where components[index].source.fieldID == fieldID
                && !components[index].mediaBehavior.isSupported(for: fieldType.mediaKind) {
            stashed[components[index].id] = components[index].mediaBehavior
            components[index].mediaBehavior = .default
        }
        if var answerStash = audioSubmissionAnswerStash {
            answerStash = AudioSubmissionAnswerStash(
                generationID: answerStash.generationID,
                answers: answerStash.answers.map { saved in
                    var component = saved.component
                    if component.source.fieldID == fieldID,
                       !component.mediaBehavior.isSupported(for: fieldType.mediaKind) {
                        stashed[component.id] = component.mediaBehavior
                        component.mediaBehavior = .default
                    }
                    return (saved.offset, component)
                },
                interaction: answerStash.interaction,
                learningRoute: answerStash.learningRoute
            )
            audioSubmissionAnswerStash = answerStash
        }
        return stashed
    }

    mutating func restoreMediaBehavior(
        referencing fieldID: UUID,
        for fieldType: FieldType,
        from stashed: [UUID: MediaBehavior]
    ) -> Set<UUID> {
        var restored: Set<UUID> = []
        for index in components.indices {
            let componentID = components[index].id
            guard components[index].source.fieldID == fieldID,
                  let behavior = stashed[componentID],
                  behavior.isSupported(for: fieldType.mediaKind) else { continue }
            components[index].mediaBehavior = behavior
            restored.insert(componentID)
        }
        if var answerStash = audioSubmissionAnswerStash {
            answerStash = AudioSubmissionAnswerStash(
                generationID: answerStash.generationID,
                answers: answerStash.answers.map { saved in
                    var component = saved.component
                    if component.source.fieldID == fieldID,
                       let behavior = stashed[component.id],
                       behavior.isSupported(for: fieldType.mediaKind) {
                        component.mediaBehavior = behavior
                        restored.insert(component.id)
                    }
                    return (saved.offset, component)
                },
                interaction: answerStash.interaction,
                learningRoute: answerStash.learningRoute
            )
            audioSubmissionAnswerStash = answerStash
        }
        return restored
    }

    public var requiresAudioAnswerRemovalConfirmation: Bool {
        components.contains { $0.purpose == .expectedAnswer }
    }

    /// Returns false when confirmation is required and no mutation was performed.
    @discardableResult
    public mutating func setInteraction(
        _ newInteraction: Interaction,
        confirmAudioAnswerRemoval: Bool = false
    ) -> Bool {
        guard newInteraction != interaction else { return true }
        if newInteraction == .audioSubmission {
            let answers = components.enumerated().compactMap { offset, component in
                component.purpose == .expectedAnswer ? (offset, component) : nil
            }
            guard answers.isEmpty || confirmAudioAnswerRemoval else { return false }
            audioSubmissionAnswerStash = AudioSubmissionAnswerStash(
                generationID: UUID(),
                answers: answers,
                interaction: interaction,
                learningRoute: learningRoute
            )
            components.removeAll { $0.purpose == .expectedAnswer }
            interaction = .audioSubmission
            learningRoute.output = .audio
            learningRoute.operation = .reproduce
            return true
        }

        if interaction == .audioSubmission, let stash = audioSubmissionAnswerStash {
            for saved in stash.answers.sorted(by: { $0.offset < $1.offset }) {
                components.insert(saved.component, at: min(saved.offset, components.count))
            }
            interaction = newInteraction == stash.interaction ? stash.interaction : newInteraction
            learningRoute = stash.learningRoute
            audioSubmissionAnswerStash = nil
            return true
        }

        interaction = newInteraction
        return true
    }

    public func template() throws -> Template {
        Template(
            id: id,
            name: name,
            layout: layout,
            components: try components.map { try $0.templateComponent() },
            interaction: interaction,
            skill: learningRoute,
            generateWhen: try availability.map { availability in
                guard let condition = availability.condition else {
                    throw ItemTypeStudioDraftError.incompleteAvailability(id)
                }
                return condition
            }
        )
    }
}

public enum CardSetupStarter: String, CaseIterable, Sendable {
    case basic
    case reverse
    case typeAnswer
    case visual
    case cloze
    case audioSubmission

    public func isApplicable(to fields: [ItemTypeFieldDraft]) -> Bool {
        switch self {
        case .basic, .reverse, .typeAnswer:
            fields.count >= 2
        case .audioSubmission:
            !fields.isEmpty
        case .visual:
            fields.contains { [.image, .gif, .video].contains($0.type) }
                && fields.contains { ![.image, .gif, .video].contains($0.type) }
        case .cloze:
            fields.contains { $0.type == .cloze }
        }
    }

    public func makeCardSetup(
        id: UUID = UUID(),
        fields: [ItemTypeFieldDraft]
    ) throws -> CardSetupDraft {
        guard isApplicable(to: fields) else {
            throw ItemTypeStudioDraftError.starterNotApplicable(self)
        }

        let first = fields[0]
        let second = fields.count > 1 ? fields[1] : first
        let question: ItemTypeFieldDraft
        let answer: ItemTypeFieldDraft?
        let name: String
        let interaction: Interaction
        var availability: CardSetupAvailabilityDraft?

        switch self {
        case .basic:
            (question, answer, name, interaction) = (first, second, "Basic", .reveal)
        case .reverse:
            (question, answer, name, interaction) = (second, first, "Reverse", .reveal)
        case .typeAnswer:
            (question, answer, name, interaction) = (first, second, "Type Answer", .type)
        case .visual:
            let visual = fields.first { [.image, .gif, .video].contains($0.type) }!
            let text = fields.first { ![.image, .gif, .video].contains($0.type) }!
            (question, answer, name, interaction) = (visual, text, "Visual", .reveal)
            availability = .fieldPresent(visual.id)
        case .cloze:
            let cloze = fields.first { $0.type == .cloze }!
            (question, answer, name, interaction) = (cloze, cloze, "Cloze", .cloze)
        case .audioSubmission:
            (question, answer, name, interaction) = (first, nil, "Audio Submission", .audioSubmission)
        }

        var components = [CardSetupComponentDraft(
            source: .field(question.id),
            region: [.image, .gif, .video].contains(question.type) ? .media : .primary,
            purpose: .question,
            reveal: interaction == .cloze ? .hiddenUntilAnswer : .always
        )]
        if let answer {
            components.append(CardSetupComponentDraft(
                source: .field(answer.id),
                region: .secondary,
                purpose: .expectedAnswer,
                reveal: .hiddenUntilAnswer
            ))
        }
        let recommendation = CardSetupRecommendation.make(
            components: components,
            interaction: interaction,
            fields: fields
        )
        return CardSetupDraft(
            id: id,
            name: name,
            layout: recommendation.layout,
            interaction: interaction,
            learningRoute: recommendation.learningRoute,
            availability: availability,
            components: components,
            recommendation: recommendation,
            isLayoutManuallySelected: false
        )
    }
}

public enum ItemTypeStudioValidationTarget: Hashable, Sendable {
    case itemTypeName
    case field(UUID)
    case cardSetup(UUID)
    case component(cardSetupID: UUID, componentID: UUID)
    case availability(cardSetupID: UUID)
    case answerMethod(cardSetupID: UUID)
    case layout(cardSetupID: UUID)
    case recipe(cardSetupID: UUID, purpose: ComponentPurpose)
}

public struct ItemTypeStudioValidationIssue: Identifiable, Equatable, Sendable {
    public let target: ItemTypeStudioValidationTarget
    public let message: String

    public var id: String { "\(target):\(message)" }

    public init(target: ItemTypeStudioValidationTarget, message: String) {
        self.target = target
        self.message = message
    }
}

public struct ItemTypeStudioFieldTypeChange: Equatable, Sendable {
    public let fieldID: UUID
    public let oldType: FieldType
    public let newType: FieldType

    public init(fieldID: UUID, oldType: FieldType, newType: FieldType) {
        self.fieldID = fieldID
        self.oldType = oldType
        self.newType = newType
    }
}

/// Describes draft-local consequences for a save confirmation without touching storage.
public struct ItemTypeStudioChangeSet: Equatable, Sendable {
    public var removedFieldIDs: Set<UUID>
    public var fieldTypeChanges: [ItemTypeStudioFieldTypeChange]
    public var affectedCardSetupIDs: Set<UUID>
    public var clearedComponentIDs: Set<UUID>
    public var clearedAvailabilityCardSetupIDs: Set<UUID>
    public var removedCardSetupIDs: Set<UUID>

    public init(
        removedFieldIDs: Set<UUID> = [],
        fieldTypeChanges: [ItemTypeStudioFieldTypeChange] = [],
        affectedCardSetupIDs: Set<UUID> = [],
        clearedComponentIDs: Set<UUID> = [],
        clearedAvailabilityCardSetupIDs: Set<UUID> = [],
        removedCardSetupIDs: Set<UUID> = []
    ) {
        self.removedFieldIDs = removedFieldIDs
        self.fieldTypeChanges = fieldTypeChanges
        self.affectedCardSetupIDs = affectedCardSetupIDs
        self.clearedComponentIDs = clearedComponentIDs
        self.clearedAvailabilityCardSetupIDs = clearedAvailabilityCardSetupIDs
        self.removedCardSetupIDs = removedCardSetupIDs
    }
}

public enum ItemTypeStudioDraftError: Error, Equatable, Sendable {
    case invalid([ItemTypeStudioValidationIssue])
    case incompleteComponent(UUID)
    case incompleteAvailability(UUID)
    case starterNotApplicable(CardSetupStarter)
}

private struct RemovedCardSetup: Equatable, Sendable {
    let offset: Int
    let setup: CardSetupDraft
}

private struct StashedMediaBehavior: Equatable, Sendable {
    let generationID: UUID
    let fieldID: UUID
    let behavior: MediaBehavior
}

/// Component identities are only required to be unique within a Template.
/// Include the owning setup so unrelated legacy Templates that reuse a UUID do
/// not overwrite one another's reversible playback history.
private struct CardSetupComponentKey: Hashable, Sendable {
    let cardSetupID: UUID
    let componentID: UUID
}

/// Only values that can be serialized into `Template`. Authoring hints and
/// reversible in-session history must not make the document appear modified.
private struct PersistedCardSetupComponentDraftState: Equatable, Sendable {
    let id: UUID
    let source: CardSetupComponentSourceDraft
    let region: ComponentRegion
    let purpose: ComponentPurpose
    let reveal: RevealMode
    let mediaBehavior: MediaBehavior

    init(_ component: CardSetupComponentDraft) {
        id = component.id
        source = component.source
        region = component.region
        purpose = component.purpose
        reveal = component.reveal
        mediaBehavior = component.mediaBehavior
    }
}

private struct PersistedCardSetupDraftState: Equatable, Sendable {
    let id: UUID
    let name: String
    let layout: CardLayoutID
    let interaction: Interaction
    let learningRoute: Skill
    let availability: CardSetupAvailabilityDraft?
    let components: [PersistedCardSetupComponentDraftState]

    init(_ draft: CardSetupDraft) {
        id = draft.id
        name = draft.name
        layout = draft.layout
        interaction = draft.interaction
        learningRoute = draft.learningRoute
        availability = draft.availability
        components = draft.components.map(PersistedCardSetupComponentDraftState.init)
    }
}

/// The atomic authoring unit: fields and every Card setup produce one complete ItemType.
public struct ItemTypeStudioDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public private(set) var originalSnapshot: ItemType?
    public var name: String
    public var fields: [ItemTypeFieldDraft]
    public var cardSetups: [CardSetupDraft]

    private var initialName: String
    private var initialFields: [ItemTypeFieldDraft]
    private var initialCardSetups: [CardSetupDraft]
    private var removedCardSetupUndoStack: [RemovedCardSetup] = []
    private var mediaBehaviorStash: [CardSetupComponentKey: StashedMediaBehavior] = [:]

    public init(itemType: ItemType) {
        id = itemType.id
        originalSnapshot = itemType
        name = itemType.name
        fields = itemType.fields.map(ItemTypeFieldDraft.init)
        cardSetups = itemType.templates.map(CardSetupDraft.init)
        initialName = name
        initialFields = fields
        initialCardSetups = cardSetups
    }

    private init(id: UUID, name: String, fields: [ItemTypeFieldDraft], setups: [CardSetupDraft]) {
        self.id = id
        originalSnapshot = nil
        self.name = name
        self.fields = fields
        cardSetups = setups
        initialName = name
        initialFields = fields
        initialCardSetups = setups
    }

    public static func new(id: UUID = UUID()) -> ItemTypeStudioDraft {
        let fields = [
            ItemTypeFieldDraft(name: "Front", type: .text, isRequired: true),
            ItemTypeFieldDraft(name: "Back", type: .text, isRequired: true),
        ]
        let question = CardSetupComponentDraft(
            source: .field(fields[0].id),
            region: .primary,
            purpose: .question
        )
        let answer = CardSetupComponentDraft(
            source: .field(fields[1].id),
            region: .secondary,
            purpose: .expectedAnswer,
            reveal: .hiddenUntilAnswer
        )
        let recommendation = CardSetupRecommendation.make(
            components: [question, answer],
            interaction: .reveal,
            fields: fields
        )
        let setup = CardSetupDraft(
            name: "Basic",
            layout: recommendation.layout,
            interaction: .reveal,
            learningRoute: recommendation.learningRoute,
            components: [question, answer],
            recommendation: recommendation,
            isLayoutManuallySelected: false
        )
        return ItemTypeStudioDraft(id: id, name: "", fields: fields, setups: [setup])
    }

    public var isDirty: Bool {
        name != initialName
            || fields != initialFields
            || cardSetups.map(PersistedCardSetupDraftState.init)
                != initialCardSetups.map(PersistedCardSetupDraftState.init)
    }

    public var validationIssues: [ItemTypeStudioValidationIssue] {
        Self.validationIssues(name: name, fields: fields, cardSetups: cardSetups)
    }

    public var isValid: Bool { validationIssues.isEmpty }

    public func candidateItemType() throws -> ItemType {
        let issues = validationIssues
        guard issues.isEmpty else { throw ItemTypeStudioDraftError.invalid(issues) }
        let itemType = ItemType(
            id: id,
            name: name,
            fields: fields.map(\.fieldDefinition),
            templates: try cardSetups.map { try $0.template() }
        )
        try ItemTypeValidation.validate(itemType)
        return itemType
    }

    @discardableResult
    public mutating func removeCardSetup(id: UUID) -> Bool {
        removeCardSetupChangeSet(id: id) != nil
    }

    /// Removes a setup in the draft and describes the eventual persistence impact.
    /// A nil result means the setup was not found or it is the protected final setup.
    public mutating func removeCardSetupChangeSet(id: UUID) -> ItemTypeStudioChangeSet? {
        guard cardSetups.count > 1,
              let offset = cardSetups.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = cardSetups.remove(at: offset)
        removedCardSetupUndoStack.append(RemovedCardSetup(offset: offset, setup: removed))
        return ItemTypeStudioChangeSet(
            affectedCardSetupIDs: [removed.id],
            removedCardSetupIDs: [removed.id]
        )
    }

    @discardableResult
    public mutating func undoLastCardSetupRemoval() -> Bool {
        guard let removed = removedCardSetupUndoStack.popLast() else { return false }
        cardSetups.insert(removed.setup, at: min(removed.offset, cardSetups.count))
        return true
    }

    public var pendingRemovedCardSetupIDs: Set<UUID> {
        Set(removedCardSetupUndoStack.map(\.setup.id))
    }

    @discardableResult
    public mutating func removeField(id fieldID: UUID) -> ItemTypeStudioChangeSet {
        guard let index = fields.firstIndex(where: { $0.id == fieldID }) else { return .init() }
        fields.remove(at: index)
        var changes = ItemTypeStudioChangeSet(removedFieldIDs: [fieldID])
        for setupIndex in cardSetups.indices {
            var affected = false
            let cleared = cardSetups[setupIndex]
                .clearReferenceIncludingStashedAnswers(to: fieldID)
            if !cleared.isEmpty {
                changes.clearedComponentIDs.formUnion(cleared)
                affected = true
            }
            if cardSetups[setupIndex].availability?.clearReference(to: fieldID) == true {
                changes.clearedAvailabilityCardSetupIDs.insert(cardSetups[setupIndex].id)
                affected = true
            }
            if affected { changes.affectedCardSetupIDs.insert(cardSetups[setupIndex].id) }
        }
        mediaBehaviorStash = mediaBehaviorStash.filter { $0.value.fieldID != fieldID }
        return changes
    }

    /// Moves one stable field identity by one position. Boundary and unknown-ID
    /// requests are no-ops. Recommendations follow the new field order, while
    /// the persisted Learning route remains authoritative until explicitly used.
    @discardableResult
    public mutating func moveField(
        id fieldID: UUID,
        _ direction: ItemTypeStudioFieldMoveDirection
    ) -> Bool {
        guard let source = fields.firstIndex(where: { $0.id == fieldID }) else {
            return false
        }
        let destination: Int
        switch direction {
        case .up: destination = source - 1
        case .down: destination = source + 1
        }
        guard fields.indices.contains(destination) else { return false }

        fields.swapAt(source, destination)
        for index in cardSetups.indices {
            cardSetups[index].refreshRecommendation(fields: fields)
        }
        return true
    }

    @discardableResult
    public mutating func changeFieldType(
        id fieldID: UUID,
        to newType: FieldType
    ) -> ItemTypeStudioChangeSet {
        guard let index = fields.firstIndex(where: { $0.id == fieldID }),
              fields[index].type != newType else { return .init() }
        let oldType = fields[index].type
        fields[index].type = newType
        let affected = Set(cardSetups.compactMap { setup in
            setup.referencedFieldIDsIncludingStashedAnswers.contains(fieldID)
                || setup.availability?.referencedFieldIDs.contains(fieldID) == true
                ? setup.id
                : nil
        })
        for setupIndex in cardSetups.indices {
            let cardSetupID = cardSetups[setupIndex].id
            let stashed = cardSetups[setupIndex].stashUnsupportedMediaBehavior(
                referencing: fieldID,
                for: newType
            )
            for (componentID, behavior) in stashed {
                let key = CardSetupComponentKey(
                    cardSetupID: cardSetupID,
                    componentID: componentID
                )
                mediaBehaviorStash[key] = StashedMediaBehavior(
                    generationID: UUID(),
                    fieldID: fieldID,
                    behavior: behavior
                )
            }
        }
        var restoredComponentKeys: Set<CardSetupComponentKey> = []
        for setupIndex in cardSetups.indices {
            let cardSetupID = cardSetups[setupIndex].id
            let behaviors = mediaBehaviorStash.reduce(into: [UUID: MediaBehavior]()) {
                result, element in
                guard element.key.cardSetupID == cardSetupID,
                      element.value.fieldID == fieldID else { return }
                result[element.key.componentID] = element.value.behavior
            }
            let restoredComponentIDs = cardSetups[setupIndex].restoreMediaBehavior(
                referencing: fieldID,
                for: newType,
                from: behaviors
            )
            restoredComponentKeys.formUnion(restoredComponentIDs.map {
                CardSetupComponentKey(cardSetupID: cardSetupID, componentID: $0)
            })
        }
        if !restoredComponentKeys.isEmpty {
            for key in restoredComponentKeys {
                mediaBehaviorStash[key] = nil
            }
        }
        return ItemTypeStudioChangeSet(
            fieldTypeChanges: [.init(fieldID: fieldID, oldType: oldType, newType: newType)],
            affectedCardSetupIDs: affected
        )
    }

    public mutating func markSaved(as itemType: ItemType) {
        originalSnapshot = itemType
        for index in cardSetups.indices {
            cardSetups[index].discardTransientEditingHistory()
        }
        initialName = name
        initialFields = fields
        initialCardSetups = cardSetups
        removedCardSetupUndoStack.removeAll()
        mediaBehaviorStash.removeAll()
    }

    /// Advances the persisted comparison point after an in-flight save while
    /// retaining edits made to this draft during that save.
    public mutating func rebaseOriginalSnapshot(to itemType: ItemType) {
        rebaseOriginalSnapshot(
            to: itemType,
            discardingMediaBehaviorGenerations: Set(
                mediaBehaviorStash.values.map(\.generationID)
            ),
            discardingAnswerStashGenerations: Set(
                cardSetups.compactMap(\.audioSubmissionAnswerStashGenerationID)
            )
        )
    }

    /// Rebases edits made while `committedDraft` was being saved. Only transient
    /// history already present in that committed copy crosses the save boundary;
    /// stash generations created by genuinely newer edits remain reversible.
    public mutating func rebaseOriginalSnapshot(
        to itemType: ItemType,
        discardingTransientStateFrom committedDraft: ItemTypeStudioDraft
    ) {
        guard committedDraft.id == id else { return }
        rebaseOriginalSnapshot(
            to: itemType,
            discardingMediaBehaviorGenerations: Set(
                committedDraft.mediaBehaviorStash.values.map(\.generationID)
            ),
            discardingAnswerStashGenerations: Set(
                committedDraft.cardSetups.compactMap(
                    \.audioSubmissionAnswerStashGenerationID
                )
            )
        )
    }

    private mutating func rebaseOriginalSnapshot(
        to itemType: ItemType,
        discardingMediaBehaviorGenerations: Set<UUID>,
        discardingAnswerStashGenerations: Set<UUID>
    ) {
        guard itemType.id == id else { return }
        mediaBehaviorStash = mediaBehaviorStash.filter {
            !discardingMediaBehaviorGenerations.contains($0.value.generationID)
        }
        for index in cardSetups.indices {
            cardSetups[index].discardAudioSubmissionAnswerStash(
                generations: discardingAnswerStashGenerations
            )
        }
        originalSnapshot = itemType
        initialName = itemType.name
        initialFields = itemType.fields.map(ItemTypeFieldDraft.init)
        initialCardSetups = itemType.templates.map(CardSetupDraft.init)
        let savedSetupIDs = Set(itemType.templates.map(\.id))
        removedCardSetupUndoStack.removeAll {
            !savedSetupIDs.contains($0.setup.id)
        }
    }

    private static func validationIssues(
        name: String,
        fields: [ItemTypeFieldDraft],
        cardSetups: [CardSetupDraft]
    ) -> [ItemTypeStudioValidationIssue] {
        var issues: [ItemTypeStudioValidationIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(target: .itemTypeName, message: "Item type name is required."))
        }
        if fields.isEmpty {
            issues.append(.init(target: .itemTypeName, message: "Add at least one field."))
        }
        var names: Set<String> = []
        var ids: Set<UUID> = []
        for field in fields {
            let trimmed = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append(.init(target: .field(field.id), message: "Field name is required."))
            } else if !names.insert(trimmed.lowercased()).inserted {
                issues.append(.init(target: .field(field.id), message: "Field names must be unique."))
            }
            if !ids.insert(field.id).inserted {
                issues.append(.init(target: .field(field.id), message: "Field identity must be unique."))
            }
        }
        if cardSetups.isEmpty {
            issues.append(.init(target: .itemTypeName, message: "Add at least one Card setup."))
        }
        let fieldByID = Dictionary(fields.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in
            first
        })
        var setupIDs: Set<UUID> = []
        for setup in cardSetups {
            if !setupIDs.insert(setup.id).inserted {
                issues.append(.init(
                    target: .cardSetup(setup.id),
                    message: "Card setup identity must be unique."
                ))
            }
            validate(setup: setup, fieldByID: fieldByID, into: &issues)
        }
        return issues
    }

    private static func validate(
        setup: CardSetupDraft,
        fieldByID: [UUID: ItemTypeFieldDraft],
        into issues: inout [ItemTypeStudioValidationIssue]
    ) {
        if setup.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(target: .cardSetup(setup.id), message: "Card setup name is required."))
        }
        if !setup.components.contains(where: { $0.purpose == .question }) {
            issues.append(.init(
                target: .recipe(cardSetupID: setup.id, purpose: .question),
                message: "Choose question content."
            ))
        }
        if setup.interaction != .audioSubmission,
           !setup.components.contains(where: { $0.purpose == .expectedAnswer }) {
            issues.append(.init(
                target: .recipe(cardSetupID: setup.id, purpose: .expectedAnswer),
                message: "Choose expected answer content."
            ))
        }
        if setup.interaction == .audioSubmission,
           setup.components.contains(where: { $0.purpose == .expectedAnswer }) {
            issues.append(.init(
                target: .answerMethod(cardSetupID: setup.id),
                message: "Audio Submission cannot reveal an expected answer."
            ))
        }
        if setup.interaction == .audioSubmission, setup.learningRoute.output != .audio {
            issues.append(.init(
                target: .answerMethod(cardSetupID: setup.id),
                message: "Audio Submission needs an audio learning route."
            ))
        }
        if (setup.layout == .mediaAside || setup.layout == .mediaHero),
           !setup.components.contains(where: { $0.region == .media }) {
            issues.append(.init(
                target: .layout(cardSetupID: setup.id),
                message: "This layout needs media content."
            ))
        }

        var componentIDs: Set<UUID> = []
        for component in setup.components {
            let target = ItemTypeStudioValidationTarget.component(
                cardSetupID: setup.id,
                componentID: component.id
            )
            if !componentIDs.insert(component.id).inserted {
                issues.append(.init(target: target, message: "Content identity must be unique."))
            }
            guard let source = component.resolvedSlotSource else {
                issues.append(.init(target: target, message: "Choose a field or enter fixed text."))
                continue
            }
            let field: ItemTypeFieldDraft?
            switch source {
            case let .field(id):
                field = fieldByID[id]
                if field == nil {
                    issues.append(.init(target: target, message: "Choose an existing field."))
                }
            case .literal:
                field = nil
            }
            if component.purpose == .expectedAnswer, component.reveal == .always {
                issues.append(.init(target: target, message: "Expected answers stay concealed until reveal."))
            }
            if !component.mediaBehavior.isSupported(for: field?.type.mediaKind) {
                issues.append(.init(target: target, message: "This playback behavior is not supported by the selected content."))
            }
            if component.region == .media,
               field.map({ [.image, .gif, .video].contains($0.type) }) != true {
                issues.append(.init(target: target, message: "The Media area accepts image, GIF, or video fields."))
            }
        }

        if let availability = setup.availability {
            if availability.condition == nil
                || !availability.referencedFieldIDs.isSubset(of: Set(fieldByID.keys)) {
                issues.append(.init(
                    target: .availability(cardSetupID: setup.id),
                    message: "Repair the Availability rule."
                ))
            }
        }
        if setup.interaction == .cloze {
            let clozeQuestionComponents = setup.components.filter { component in
                guard component.purpose == .question,
                      let id = component.source.fieldID,
                      fieldByID[id]?.type == .cloze else { return false }
                return true
            }
            let clozeFieldIDs = Set(clozeQuestionComponents.compactMap(\.source.fieldID))
            if clozeFieldIDs.isEmpty {
                issues.append(.init(
                    target: .recipe(cardSetupID: setup.id, purpose: .question),
                    message: "Cloze needs exactly one Cloze question field."
                ))
            } else if clozeFieldIDs.count > 1 {
                let firstFieldID = clozeQuestionComponents.first?.source.fieldID
                let extra = clozeQuestionComponents.first {
                    $0.source.fieldID != firstFieldID
                }
                if let extra {
                    issues.append(.init(
                        target: .component(cardSetupID: setup.id, componentID: extra.id),
                        message: "Cloze needs exactly one Cloze question field."
                    ))
                }
            }
        }
    }
}
