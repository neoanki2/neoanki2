import NeoAnkiApplication
import NeoAnkiCore
import SwiftUI

/// Stable identifiers shared by the macOS and iOS Item Type Studio journeys.
public enum ItemTypeStudioAccessibilityID {
    public static let cardSetupList = "itemTypeStudio.cardSetups"
    public static let cardSetupListScroll = "itemTypeStudio.cardSetupListScroll"
    public static let addBasicCardSetup = "itemTypeStudio.addBasicCardSetup"
    public static let addCardSetupMenu = "itemTypeStudio.addCardSetupMenu"
    public static let undoCardSetupRemoval = "itemTypeStudio.undoCardSetupRemoval"
    public static let cardSetupEditor = "cardSetupEditor"
    public static let canvas = "cardSetupEditor.canvas"
    public static let inspector = "cardSetupEditor.inspector"
    public static let inspectorButton = "cardSetupEditor.inspectorButton"
    public static let inspectorDone = "cardSetupEditor.inspectorDone"
    public static let addContent = "cardSetupEditor.addContent"
    public static let cardSetupName = "cardSetupEditor.name"
    public static let answerMethod = "cardSetupEditor.answerMethod"
    public static let recipeQuestion = "cardSetupEditor.recipe.question"
    public static let recipeAnswer = "cardSetupEditor.recipe.answer"
    public static let showAnswer = "cardSetupEditor.showAnswer"
    public static let layoutPicker = "cardSetupEditor.layoutPicker"
    public static let advanced = "cardSetupEditor.advanced"
    public static let additionalContent = "cardSetupEditor.additionalContent"
    public static let availability = "cardSetupEditor.availability"
    public static let availabilityCombination = "cardSetupEditor.availabilityCombination"
    public static let learningRoute = "cardSetupEditor.learningRoute"
    public static let auditPreview = "cardSetupEditor.audit.preview"

    public static func cardSetup(_ id: UUID) -> String { "itemTypeStudio.cardSetup.\(id)" }
    public static func auditSection(_ section: CardSetupEditorAuditSection) -> String {
        "cardSetupEditor.auditSection.\(section.rawValue)"
    }
    public static func layout(_ layout: CardLayoutID) -> String {
        "cardSetupEditor.layout.\(layout.rawValue)"
    }
    public static func hole(_ hole: CardWireframeHole) -> String {
        "cardSetupEditor.hole.\(hole.rawValue)"
    }
    public static func component(_ id: UUID) -> String { "cardSetupEditor.component.\(id)" }
    public static func fixedText(_ id: UUID) -> String { "cardSetupEditor.fixedText.\(id)" }
    public static func reveal(_ id: UUID) -> String { "cardSetupEditor.reveal.\(id)" }
    public static func playback(_ id: UUID) -> String { "cardSetupEditor.playback.\(id)" }
    public static func additionalSource(_ id: UUID) -> String {
        "cardSetupEditor.additionalSource.\(id)"
    }
    public static func additionalMoveUp(_ id: UUID) -> String {
        "cardSetupEditor.additionalMoveUp.\(id)"
    }
    public static func additionalMoveDown(_ id: UUID) -> String {
        "cardSetupEditor.additionalMoveDown.\(id)"
    }
    public static func revealRepair(_ id: UUID) -> String {
        "cardSetupEditor.revealRepair.\(id)"
    }
    public static func sourcePicker(
        componentID: UUID?,
        hole: CardWireframeHole
    ) -> String {
        if let componentID {
            return "cardSetupEditor.sourcePicker.component.\(componentID)"
        }
        return "cardSetupEditor.sourcePicker.hole.\(hole.rawValue)"
    }
    public static func sourcePickerField(
        componentID: UUID?,
        hole: CardWireframeHole,
        fieldID: UUID
    ) -> String {
        "\(sourcePicker(componentID: componentID, hole: hole)).field.\(fieldID)"
    }
    public static func sourcePickerFixedText(
        componentID: UUID?,
        hole: CardWireframeHole
    ) -> String {
        "\(sourcePicker(componentID: componentID, hole: hole)).fixedText"
    }
    public static func sourcePickerCancel(
        componentID: UUID?,
        hole: CardWireframeHole
    ) -> String {
        "\(sourcePicker(componentID: componentID, hole: hole)).cancel"
    }
}

/// Test-host sections rendered through the shared editor. Production platform
/// shells never select one, so ordinary editor interaction and UI journeys
/// continue to use the complete, natively scrolling editor.
public enum CardSetupEditorAuditSection: String, CaseIterable, Sendable {
    case preview
    case additional
    case advanced
    case availability
    case learningRoute

    fileprivate var displayName: String {
        switch self {
        case .preview: "Preview"
        case .additional: "Additional content"
        case .advanced: "Advanced"
        case .availability: "Availability"
        case .learningRoute: "Learning route"
        }
    }
}

/// A deterministic authoring projection. It feeds the production wireframe and
/// identifies mappings that must remain lossless under Additional content.
public struct CardSetupEditorProjection: Equatable, Sendable {
    public let descriptor: CardWireframeDescriptor
    public let resolvedComponents: [ResolvedTemplateComponent]
    public let canonicalComponentIDs: Set<UUID>
    public let additionalComponentIDs: Set<UUID>
    private let fieldTypesByComponentID: [UUID: FieldType]

    public init(setup: CardSetupDraft, fields: [ItemTypeFieldDraft]) {
        let descriptor = CardWireframeDescriptor.descriptor(for: setup.layout)
        self.descriptor = descriptor
        let fieldsByID = Dictionary(fields.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        resolvedComponents = setup.components.map { component in
            ResolvedTemplateComponent(
                id: component.id,
                region: component.region,
                purpose: component.purpose,
                value: .text(Self.previewLabel(for: component.source, fieldsByID: fieldsByID)),
                presentation: Presentation(
                    reveal: component.reveal,
                    media: component.mediaBehavior
                )
            )
        }
        fieldTypesByComponentID = Dictionary(
            uniqueKeysWithValues: setup.components.compactMap { component in
                guard case let .field(fieldID?) = component.source,
                      let fieldType = fieldsByID[fieldID]?.type
                else { return nil }
                return (component.id, fieldType)
            }
        )
        canonicalComponentIDs = Set(setup.components.compactMap { component in
            let hole = descriptor.hole(for: component.region)
            let insertion = descriptor.canonicalInsertion(for: hole)
            return insertion.region == component.region && insertion.purpose == component.purpose
                ? component.id
                : nil
        })
        additionalComponentIDs = Set(setup.components.map(\.id)).subtracting(canonicalComponentIDs)
    }

    public func isAdditional(_ componentID: UUID) -> Bool {
        additionalComponentIDs.contains(componentID)
    }

    public func previewRendering(
        for component: ResolvedTemplateComponent,
        isAnswerRevealed: Bool
    ) -> CardSetupEditorPreviewRendering {
        CardSetupEditorPreviewPolicy.rendering(
            purpose: component.purpose,
            revealMode: component.presentation.reveal,
            fieldType: fieldTypesByComponentID[component.id],
            isAnswerRevealed: isAnswerRevealed
        )
    }

    private static func previewLabel(
        for source: CardSetupComponentSourceDraft,
        fieldsByID: [UUID: ItemTypeFieldDraft]
    ) -> String {
        switch source {
        case let .field(id):
            return id.flatMap { fieldsByID[$0]?.name } ?? "Choose content"
        case let .fixedText(text):
            return text.isEmpty ? "Fixed text" : text
        }
    }
}

/// The visible authoring state for one component. It mirrors production
/// reveal semantics without resolving real item data or media assets.
public enum CardSetupEditorPreviewRendering: Equatable, Sendable {
    case content
    case blurred
    case concealed
}

public enum CardSetupEditorPreviewPolicy {
    public static func rendering(
        purpose: ComponentPurpose,
        revealMode: RevealMode,
        fieldType: FieldType?,
        isAnswerRevealed: Bool
    ) -> CardSetupEditorPreviewRendering {
        if !isAnswerRevealed, purpose == .expectedAnswer { return .concealed }
        if isAnswerRevealed || revealMode == .always { return .content }

        // Production preserves the sentence around cloze blanks rather than
        // concealing the whole value.
        if fieldType == .cloze { return .content }

        switch revealMode {
        case .always:
            return .content
        case .hiddenUntilAnswer:
            return .concealed
        case .blurred:
            return fieldType == .image || fieldType == .gif ? .blurred : .concealed
        }
    }
}

/// Platform-neutral presentation derived from Core's study visibility policy.
/// Mobile study uses this projection directly so it cannot drift from the
/// desktop/shared semantics around Cloze, blurred visuals, or hidden media.
public struct SharedStudyContentVisibility: Equatable, Sendable {
    public let rendering: ContentVisibilityRendering
    public let accessibilityLabel: String?
    public let shouldResolveMedia: Bool

    public init(
        rendering: ContentVisibilityRendering,
        accessibilityLabel: String?,
        shouldResolveMedia: Bool
    ) {
        self.rendering = rendering
        self.accessibilityLabel = accessibilityLabel
        self.shouldResolveMedia = shouldResolveMedia
    }
}

public enum SharedStudyContentVisibilityPolicy {
    public static func decision(
        for value: ContentValue,
        revealMode: RevealMode,
        isAnswerRevealed: Bool
    ) -> SharedStudyContentVisibility {
        let decision = ContentVisibilityPolicy.decision(
            for: value,
            revealMode: revealMode,
            isAnswerRevealed: isAnswerRevealed
        )
        let label: String?
        switch decision.rendering {
        case .content:
            label = nil
        case .blurredMedia:
            label = "Blurred \(contentDescription(for: value).lowercased())"
        case .placeholder:
            let suffix = revealMode == .hiddenUntilAnswer
                ? "hidden until answer"
                : "concealed until answer"
            label = "\(contentDescription(for: value)) \(suffix)"
        }
        return SharedStudyContentVisibility(
            rendering: decision.rendering,
            accessibilityLabel: label,
            shouldResolveMedia: decision.shouldResolveMedia
        )
    }

    private static func contentDescription(for value: ContentValue) -> String {
        switch value {
        case .text, .rich: "Text"
        case .number: "Number"
        case .cloze: "Cloze"
        case let .media(reference):
            switch reference.kind {
            case .audio: "Audio"
            case .image: "Image"
            case .gif: "Animation"
            case .video: "Video"
            }
        case .empty: "Content"
        }
    }
}

public enum SharedStudyClozePresentation {
    /// The shared mobile projection deliberately delegates masking, group
    /// selection, hints, and malformed-span sanitization to Core—the same
    /// implementation used by the macOS study renderer.
    public static func displayText(
        from text: String,
        blanks: [ClozeSpan],
        isAnswerRevealed: Bool,
        group: Int?
    ) -> String {
        ClozeValidation.displayText(
            from: text,
            blanks: blanks,
            revealed: isAnswerRevealed,
            group: group
        )
    }
}

/// The reveal values the UI may offer for a component. Unsupported persisted
/// values are intentionally not rewritten; the editor instead exposes an
/// explicit repair action.
public enum CardSetupRevealControlPolicy {
    public static func allowedModes(
        purpose: ComponentPurpose,
        fieldType: FieldType?
    ) -> [RevealMode] {
        if purpose == .expectedAnswer {
            return [.hiddenUntilAnswer]
        }
        var modes: [RevealMode] = [.always, .hiddenUntilAnswer]
        if fieldType == .image || fieldType == .gif {
            modes.append(.blurred)
        }
        return modes
    }

    public static func isValid(
        _ mode: RevealMode,
        purpose: ComponentPurpose,
        fieldType: FieldType?
    ) -> Bool {
        allowedModes(purpose: purpose, fieldType: fieldType).contains(mode)
    }

    public static func repairMode(
        purpose: ComponentPurpose,
        fieldType: FieldType?
    ) -> RevealMode {
        purpose == .expectedAnswer ? .hiddenUntilAnswer : .always
    }
}

public enum CardSetupEditorMoveDirection: Int, Equatable, Sendable {
    case earlier = -1
    case later = 1
}

/// Headless-testable actions used by the shared macOS and iOS editor wiring.
public enum CardSetupEditorAction: Equatable, Sendable {
    case chooseLayout(CardLayoutID)
    case addComponent(source: CardSetupComponentSourceDraft, hole: CardWireframeHole)
    case changeSource(componentID: UUID, source: CardSetupComponentSourceDraft)
    case editFixedText(componentID: UUID, value: String)
    case duplicateComponent(UUID)
    case removeComponent(UUID)
    case moveComponent(UUID, CardSetupEditorMoveDirection)
    case moveAdditionalComponent(UUID, CardSetupEditorMoveDirection)
    case setReveal(componentID: UUID, RevealMode)
    case canonicalize(componentID: UUID, hole: CardWireframeHole)
    case setAvailability(CardSetupAvailabilityDraft?)
    case setInteraction(Interaction, confirmAudioAnswerRemoval: Bool)
    case useRecommendation
    case repairMediaBehavior(UUID)
}

public enum CardSetupEditorReducer {
    /// Returns false when the target no longer exists, a move is unavailable,
    /// or Audio Submission still needs destructive confirmation.
    @discardableResult
    public static func apply(
        _ action: CardSetupEditorAction,
        to draft: inout ItemTypeStudioDraft,
        cardSetupID: UUID
    ) -> Bool {
        guard let setupIndex = draft.cardSetups.firstIndex(where: { $0.id == cardSetupID }) else {
            return false
        }
        var setup = draft.cardSetups[setupIndex]
        let fields = draft.fields
        let descriptor = CardWireframeDescriptor.descriptor(for: setup.layout)

        switch action {
        case let .chooseLayout(layout):
            setup.chooseLayout(layout)

        case let .addComponent(source, hole):
            let insertion = descriptor.canonicalInsertion(for: hole)
            setup.components.append(CardSetupComponentDraft(
                source: source,
                region: insertion.region,
                purpose: insertion.purpose,
                reveal: insertion.purpose == .expectedAnswer ? .hiddenUntilAnswer : .always
            ))
            setup.refreshRecommendation(fields: fields)

        case let .changeSource(componentID, source):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            setup.components[index].setSource(source)
            normalizeMediaBehavior(of: &setup.components[index], fields: fields)
            setup.refreshRecommendation(fields: fields)

        case let .editFixedText(componentID, value):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }),
                  case .fixedText = setup.components[index].source
            else { return false }
            setup.components[index].setFixedText(value)

        case let .duplicateComponent(componentID):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            let component = setup.components[index]
            setup.components.insert(
                CardSetupComponentDraft(
                    source: component.source,
                    region: component.region,
                    purpose: component.purpose,
                    reveal: component.reveal,
                    mediaBehavior: component.mediaBehavior
                ),
                at: index + 1
            )
            setup.refreshRecommendation(fields: fields)

        case let .removeComponent(componentID):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            setup.components.remove(at: index)
            setup.refreshRecommendation(fields: fields)

        case let .moveComponent(componentID, direction):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            let siblings = placementSiblingIndices(for: index, setup: setup)
            guard let localIndex = siblings.firstIndex(of: index) else { return false }
            let destination = localIndex + direction.rawValue
            guard siblings.indices.contains(destination) else { return false }
            setup.components.swapAt(index, siblings[destination])

        case let .moveAdditionalComponent(componentID, direction):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            let siblings = additionalComponentIndices(setup: setup, descriptor: descriptor)
            guard let localIndex = siblings.firstIndex(of: index) else { return false }
            let destination = localIndex + direction.rawValue
            guard siblings.indices.contains(destination) else { return false }
            setup.components.swapAt(index, siblings[destination])

        case let .setReveal(componentID, mode):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            let component = setup.components[index]
            guard CardSetupRevealControlPolicy.isValid(
                mode,
                purpose: component.purpose,
                fieldType: fieldType(for: component.source, fields: fields)
            ) else { return false }
            setup.components[index].reveal = mode

        case let .canonicalize(componentID, hole):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }) else {
                return false
            }
            let insertion = descriptor.canonicalInsertion(for: hole)
            setup.components[index].region = insertion.region
            setup.components[index].purpose = insertion.purpose
            if insertion.purpose == .expectedAnswer {
                setup.components[index].reveal = .hiddenUntilAnswer
            }
            setup.refreshRecommendation(fields: fields)

        case let .setAvailability(availability):
            setup.availability = availability

        case let .setInteraction(interaction, confirmAudioAnswerRemoval):
            guard setup.setInteraction(
                interaction,
                confirmAudioAnswerRemoval: confirmAudioAnswerRemoval
            ) else { return false }
            setup.refreshRecommendation(fields: fields)

        case .useRecommendation:
            setup.useRecommendation()

        case let .repairMediaBehavior(componentID):
            guard let index = setup.components.firstIndex(where: { $0.id == componentID }),
                  !setup.components[index].mediaBehavior.isSupported(
                    for: mediaKind(for: setup.components[index].source, fields: fields)
                  )
            else { return false }
            setup.components[index].mediaBehavior = .default
        }

        draft.cardSetups[setupIndex] = setup
        return true
    }

    private static func normalizeMediaBehavior(
        of component: inout CardSetupComponentDraft,
        fields: [ItemTypeFieldDraft]
    ) {
        guard !component.mediaBehavior.isSupported(for: mediaKind(for: component.source, fields: fields)) else {
            return
        }
        component.mediaBehavior = .default
    }

    private static func mediaKind(
        for source: CardSetupComponentSourceDraft,
        fields: [ItemTypeFieldDraft]
    ) -> MediaKind? {
        guard case let .field(fieldID?) = source else { return nil }
        return fields.first(where: { $0.id == fieldID })?.type.mediaKind
    }

    private static func placementSiblingIndices(
        for index: Int,
        setup: CardSetupDraft
    ) -> [Int] {
        guard setup.components.indices.contains(index) else { return [] }
        let component = setup.components[index]
        return setup.components.indices.filter { candidateIndex in
            let candidate = setup.components[candidateIndex]
            return candidate.region == component.region && candidate.purpose == component.purpose
        }
    }

    private static func fieldType(
        for source: CardSetupComponentSourceDraft,
        fields: [ItemTypeFieldDraft]
    ) -> FieldType? {
        guard case let .field(fieldID?) = source else { return nil }
        return fields.first(where: { $0.id == fieldID })?.type
    }

    private static func additionalComponentIndices(
        setup: CardSetupDraft,
        descriptor: CardWireframeDescriptor
    ) -> [Int] {
        setup.components.indices.filter { index in
            let component = setup.components[index]
            let hole = descriptor.hole(for: component.region)
            let insertion = descriptor.canonicalInsertion(for: hole)
            return insertion.region != component.region || insertion.purpose != component.purpose
        }
    }
}

/// ID-scoped bindings used by lazy SwiftUI controls. SwiftUI may invoke a
/// binding while its row is disappearing; every setter therefore resolves the
/// stable setup/component identity again and becomes a no-op when that target
/// has already been removed.
private struct SendableWritableKeyPath<Root, Value>: @unchecked Sendable {
    let value: WritableKeyPath<Root, Value>
}

enum CardSetupEditorBindingFactory {
    static func setupValue<Value: Sendable>(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        keyPath: WritableKeyPath<CardSetupDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        let keyPath = SendableWritableKeyPath(value: keyPath)
        return Binding(
            get: {
                draft.wrappedValue.cardSetups
                    .first(where: { $0.id == cardSetupID })?[keyPath: keyPath.value]
                    ?? fallback
            },
            set: { value in
                var current = draft.wrappedValue
                guard let setupIndex = current.cardSetups.firstIndex(where: {
                    $0.id == cardSetupID
                }) else { return }
                current.cardSetups[setupIndex][keyPath: keyPath.value] = value
                draft.wrappedValue = current
            }
        )
    }

    static func componentValue<Value: Sendable>(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        componentID: UUID,
        keyPath: WritableKeyPath<CardSetupComponentDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        let keyPath = SendableWritableKeyPath(value: keyPath)
        return Binding(
            get: {
                guard let setup = draft.wrappedValue.cardSetups.first(where: {
                    $0.id == cardSetupID
                }) else { return fallback }
                return setup.components.first(where: { $0.id == componentID })?[keyPath: keyPath.value]
                    ?? fallback
            },
            set: { value in
                var current = draft.wrappedValue
                guard let setupIndex = current.cardSetups.firstIndex(where: {
                    $0.id == cardSetupID
                }),
                let componentIndex = current.cardSetups[setupIndex].components.firstIndex(where: {
                    $0.id == componentID
                }) else { return }
                current.cardSetups[setupIndex].components[componentIndex][keyPath: keyPath.value] = value
                draft.wrappedValue = current
            }
        )
    }

    static func fixedText(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        componentID: UUID,
        fallback: String
    ) -> Binding<String> {
        componentActionValue(
            draft: draft,
            cardSetupID: cardSetupID,
            componentID: componentID,
            fallback: fallback,
            value: { component in
                guard case let .fixedText(text) = component.source else { return nil }
                return text
            },
            action: { .editFixedText(componentID: componentID, value: $0) }
        )
    }

    static func reveal(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        componentID: UUID,
        fallback: RevealMode
    ) -> Binding<RevealMode> {
        componentActionValue(
            draft: draft,
            cardSetupID: cardSetupID,
            componentID: componentID,
            fallback: fallback,
            value: { $0.reveal },
            action: { .setReveal(componentID: componentID, $0) }
        )
    }

    static func availability(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        fallback: CardSetupAvailabilityDraft
    ) -> Binding<CardSetupAvailabilityDraft> {
        Binding(
            get: {
                draft.wrappedValue.cardSetups
                    .first(where: { $0.id == cardSetupID })?.availability
                    ?? fallback
            },
            set: { value in
                var current = draft.wrappedValue
                guard current.cardSetups.first(where: { $0.id == cardSetupID })?.availability != nil
                else { return }
                guard CardSetupEditorReducer.apply(
                    .setAvailability(value),
                    to: &current,
                    cardSetupID: cardSetupID
                ) else { return }
                draft.wrappedValue = current
            }
        )
    }

    private static func componentActionValue<Value: Sendable>(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        componentID: UUID,
        fallback: Value,
        value: @escaping @Sendable (CardSetupComponentDraft) -> Value?,
        action: @escaping @Sendable (Value) -> CardSetupEditorAction
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let setup = draft.wrappedValue.cardSetups.first(where: {
                    $0.id == cardSetupID
                }),
                let component = setup.components.first(where: { $0.id == componentID })
                else { return fallback }
                return value(component) ?? fallback
            },
            set: { newValue in
                var current = draft.wrappedValue
                guard CardSetupEditorReducer.apply(
                    action(newValue),
                    to: &current,
                    cardSetupID: cardSetupID
                ) else { return }
                draft.wrappedValue = current
            }
        )
    }
}

/// Shared Item Type Studio mutations that have cross-setup consequences.
/// Platform shells call these only in response to an explicit user edit, so
/// loading an unusual legacy definition remains a lossless operation.
public enum ItemTypeStudioDraftReducer {
    @discardableResult
    public static func changeFieldType(
        fieldID: UUID,
        to type: FieldType,
        in draft: inout ItemTypeStudioDraft
    ) -> ItemTypeStudioChangeSet {
        let changes = draft.changeFieldType(id: fieldID, to: type)
        for setupIndex in draft.cardSetups.indices
        where changes.affectedCardSetupIDs.contains(draft.cardSetups[setupIndex].id) {
            draft.cardSetups[setupIndex].refreshRecommendation(fields: draft.fields)
        }
        return changes
    }
}

public enum CardSetupEditorLayoutMetrics {
    public static let minimumTouchTarget: CGFloat = 44
    public static let maximumAvailabilityIndentation: CGFloat = 16
    public static let macSourcePickerMinimumDimension: CGFloat = 420
    public static let workspaceInspectorThreshold: CGFloat = 960

    /// The cumulative leading indentation at a recursive Availability depth.
    public static func availabilityIndentation(depth: Int) -> CGFloat {
        min(CGFloat(max(depth, 0)) * 8, maximumAvailabilityIndentation)
    }

    /// The padding contributed by one recursive level. Summing these increments
    /// can never exceed `maximumAvailabilityIndentation`.
    public static func availabilityIndentationIncrement(parentDepth: Int) -> CGFloat {
        availabilityIndentation(depth: parentDepth + 1)
            - availabilityIndentation(depth: parentDepth)
    }

    public static func usesVerticalAvailabilityControls(
        isAccessibilitySize: Bool,
        availableWidth: CGFloat?
    ) -> Bool {
        isAccessibilitySize || (availableWidth.map { $0 < 420 } ?? false)
    }
}

/// Ephemeral identities for recursive Availability rows. They are deliberately
/// editor-only so the persisted condition tree remains unchanged, while a row
/// being torn down cannot accidentally write through the index of its new
/// neighbor after a first/last removal.
public struct AvailabilityRuleEditorIdentityState: Equatable, Sendable {
    public private(set) var childIDs: [UUID]

    public init(childCount: Int) {
        childIDs = (0..<max(0, childCount)).map { _ in UUID() }
    }

    @discardableResult
    public mutating func appendChild() -> UUID {
        let id = UUID()
        childIDs.append(id)
        return id
    }

    @discardableResult
    public mutating func removeChild(id: UUID) -> Int? {
        guard let index = childIDs.firstIndex(of: id) else { return nil }
        childIDs.remove(at: index)
        return index
    }

    public mutating func reconcile(childCount: Int) {
        let count = max(0, childCount)
        if childIDs.count > count {
            childIDs.removeLast(childIDs.count - count)
        } else {
            while childIDs.count < count { _ = appendChild() }
        }
    }
}

public enum CardSetupEditorAdvancedPolicy {
    /// Advanced customization stays reachable for every recipe, but no starter
    /// requires opening it to produce a valid Card setup.
    public static let startsExpanded = false
}

public enum CardSetupEditorFocusPolicy {
    public struct DisclosureState: Equatable, Sendable {
        public let showsAdvanced: Bool
        public let showsAdditionalContent: Bool

        public init(showsAdvanced: Bool, showsAdditionalContent: Bool) {
            self.showsAdvanced = showsAdvanced
            self.showsAdditionalContent = showsAdditionalContent
        }
    }

    public static func target(
        for requestedTarget: ItemTypeStudioValidationTarget?,
        cardSetupID: UUID
    ) -> ItemTypeStudioValidationTarget? {
        guard let requestedTarget else { return nil }
        switch requestedTarget {
        case .itemTypeName, .field:
            return nil
        case let .cardSetup(id),
             let .availability(cardSetupID: id),
             let .answerMethod(cardSetupID: id),
             let .layout(cardSetupID: id),
             let .recipe(cardSetupID: id, purpose: _):
            return id == cardSetupID ? requestedTarget : nil
        case let .component(cardSetupID: id, componentID: _):
            return id == cardSetupID ? requestedTarget : nil
        }
    }

    public static func disclosures(
        for requestedTarget: ItemTypeStudioValidationTarget?,
        cardSetupID: UUID,
        additionalComponentIDs: Set<UUID>
    ) -> DisclosureState {
        guard let target = target(for: requestedTarget, cardSetupID: cardSetupID) else {
            return DisclosureState(showsAdvanced: false, showsAdditionalContent: false)
        }
        switch target {
        case .availability:
            return DisclosureState(showsAdvanced: true, showsAdditionalContent: false)
        case let .component(_, componentID):
            return DisclosureState(
                showsAdvanced: false,
                showsAdditionalContent: additionalComponentIDs.contains(componentID)
            )
        case .cardSetup, .answerMethod, .layout, .recipe, .itemTypeName, .field:
            return DisclosureState(showsAdvanced: false, showsAdditionalContent: false)
        }
    }
}

/// Shared Card setups section. Platform shells place it beside their shared
/// Fields editor in a `List` or `Form`; mutations stay on the same atomic draft.
public struct CardSetupCollectionView: View {
    @Binding private var draft: ItemTypeStudioDraft
    @Binding private var selection: UUID?

    public init(
        draft: Binding<ItemTypeStudioDraft>,
        selection: Binding<UUID?>
    ) {
        _draft = draft
        _selection = selection
    }

    public var body: some View {
        Section("Card setups") {
            ForEach(draft.cardSetups) { setup in
                HStack(spacing: 8) {
#if os(macOS)
                    setupSummary(setup)
#else
                    Button {
                        selection = setup.id
                    } label: {
                        setupSummary(setup)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel(setupAccessibilityLabel(setup))
                    .accessibilityAddTraits(selection == setup.id ? .isSelected : [])
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.cardSetup(setup.id))
                    .contextMenu {
                        Button("Remove Card Setup", role: .destructive) {
                            remove(setup.id)
                        }
                        .disabled(draft.cardSetups.count == 1)
                    }
#endif

                    Button("Remove Card Setup", systemImage: "trash", role: .destructive) {
                        remove(setup.id)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Remove \(setup.name) Card setup")
                    .disabled(draft.cardSetups.count == 1)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .tag(setup.id)
#if os(macOS)
                .contextMenu {
                    Button("Remove Card Setup", role: .destructive) {
                        remove(setup.id)
                    }
                    .disabled(draft.cardSetups.count == 1)
                }
#endif
            }

            HStack(spacing: 8) {
                Button("Add", systemImage: "plus") { add(.basic) }
                    .disabled(!CardSetupStarter.basic.isApplicable(to: draft.fields))
                    .accessibilityLabel("Add Card Setup")
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.addBasicCardSetup)
                    .frame(minHeight: 44)

                Menu("More", systemImage: "chevron.down") {
                    ForEach(applicableAlternativeStarters, id: \.rawValue) { starter in
                        Button(starter.editorDisplayName) { add(starter) }
                    }
                }
                .accessibilityLabel("More Card setup recipes")
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.addCardSetupMenu)
                .frame(minWidth: 44, minHeight: 44)
            }

            if !draft.pendingRemovedCardSetupIDs.isEmpty {
                Button("Undo Remove", systemImage: "arrow.uturn.backward") {
                    _ = draft.undoLastCardSetupRemoval()
                }
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.undoCardSetupRemoval)
                .frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.cardSetupList)
        .onChange(of: draft.cardSetups.map(\.id)) { _, ids in
            if let selected = selection, !ids.contains(selected) { selection = nil }
        }
    }

    private var applicableAlternativeStarters: [CardSetupStarter] {
        CardSetupStarter.allCases.filter {
            $0 != .basic && $0.isApplicable(to: draft.fields)
        }
    }

    private func setupSummary(_ setup: CardSetupDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(setup.name.isEmpty ? "Untitled Card setup" : setup.name)
#if os(macOS)
                    .accessibilityLabel(setupAccessibilityLabel(setup))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(selection == setup.id ? .isSelected : [])
                    .accessibilityAction { selection = setup.id }
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.cardSetup(setup.id))
#endif
                Spacer()
                if selection == setup.id {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .font(.body.weight(.medium))
            Text("\(setup.layout.displayName) · \(setup.interaction.editorDisplayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
#if os(macOS)
                .accessibilityHidden(true)
#endif
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func setupAccessibilityLabel(_ setup: CardSetupDraft) -> String {
        "\(setup.name.isEmpty ? "Untitled Card setup" : setup.name), "
            + "\(setup.layout.displayName) layout, "
            + setup.interaction.editorDisplayName
    }

    private func add(_ starter: CardSetupStarter) {
        guard let setup = try? starter.makeCardSetup(fields: draft.fields) else { return }
        draft.cardSetups.append(setup)
        selection = setup.id
    }

    private func remove(_ id: UUID) {
        guard draft.removeCardSetup(id: id) else { return }
        if selection == id { selection = nil }
    }
}

/// The shared editor keeps its existing scrolling form on iPhone and iPad,
/// while macOS can opt into a canvas-led workspace composition.
public enum CardSetupEditorPresentation: Equatable, Sendable {
    case stacked
    case workspace
}

/// The shared fillable Card setup editor used by both platform shells.
public struct CardSetupEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.neoAnkiAccessibilityReduceMotionOverride) private var reduceMotionOverride
    @Binding private var draft: ItemTypeStudioDraft
    private let cardSetupID: UUID
    @Binding private var validationFocus: ItemTypeStudioValidationTarget?
    private let auditSection: CardSetupEditorAuditSection?
    private let presentation: CardSetupEditorPresentation

    @State private var isAnswerRevealed = false
    @State private var showsAdvanced = CardSetupEditorAdvancedPolicy.startsExpanded
    @State private var showsAdditionalContent = false
    @State private var pendingAudioSubmission = false
    @State private var sourceRequest: CardSetupSourceRequest?
    @State private var selectedComponentID: UUID?
    @State private var isInspectorPresented = false
    @State private var workspaceUsesInspectorSheet = false
    @FocusState private var focusedTarget: ItemTypeStudioValidationTarget?

    public init(
        draft: Binding<ItemTypeStudioDraft>,
        cardSetupID: UUID,
        validationFocus: Binding<ItemTypeStudioValidationTarget?> = .constant(nil),
        auditSection: CardSetupEditorAuditSection? = nil,
        presentation: CardSetupEditorPresentation = .stacked
    ) {
        _draft = draft
        self.cardSetupID = cardSetupID
        _validationFocus = validationFocus
        self.auditSection = auditSection
        self.presentation = presentation
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    public var body: some View {
        Group {
            if let setupIndex {
                Group {
                    if presentation == .workspace, auditSection == nil {
                        workspaceEditor(setupIndex)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                if let auditSection {
                                    Group {
                                        auditEditorSection(auditSection, setupIndex: setupIndex)
                                        Divider()
                                    }
                                }
                                editorSections(setupIndex)
                            }
                            .frame(maxWidth: 860)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                        }
                        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.cardSetupEditor)
                    }
                }
                .tint(colorSchemeContrast == .increased ? .primary : .accentColor)
                .sheet(item: canvasSourceRequest) { request in
                    CardSetupSourcePicker(
                        fields: sourceFields(for: request),
                        allowsFixedText: request.hole != .media,
                        componentID: request.componentID,
                        hole: request.hole
                    ) { source in
                        apply(source: source, request: request, setupIndex: setupIndex)
                    }
                }
                .sheet(isPresented: $isInspectorPresented) {
                    workspaceInspectorSheet(setupIndex)
                }
                .confirmationDialog(
                    "Remove the expected answer?",
                    isPresented: $pendingAudioSubmission,
                    titleVisibility: .visible
                ) {
                    Button("Remove Answer and Continue", role: .destructive) {
                        apply(.setInteraction(
                            .audioSubmission,
                            confirmAudioAnswerRemoval: true
                        ))
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Audio Submission keeps no expected answer. It will be restored if you switch back before saving.")
                }
            } else {
                ContentUnavailableView(
                    "Card setup unavailable",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Select another Card setup.")
                )
            }
        }
        .onChange(of: validationFocus, initial: true) { _, target in
            applyValidationFocus(target)
        }
        .onChange(of: focusedTarget) { _, target in validationFocus = target }
        .onChange(of: cardSetupID) { _, _ in
            selectedComponentID = nil
            isAnswerRevealed = false
            isInspectorPresented = false
        }
        .onChange(of: selectedSetupComponentIDs) { _, ids in
            if let selectedComponentID, !ids.contains(selectedComponentID) {
                self.selectedComponentID = nil
            }
        }
    }

    private var selectedSetupComponentIDs: [UUID] {
        guard let setupIndex else { return [] }
        return draft.cardSetups[setupIndex].components.map(\.id)
    }

    private var canvasSourceRequest: Binding<CardSetupSourceRequest?> {
        Binding(
            get: { isInspectorPresented ? nil : sourceRequest },
            set: { sourceRequest = $0 }
        )
    }

    @ViewBuilder
    private func workspaceEditor(_ setupIndex: Int) -> some View {
        GeometryReader { geometry in
            let usesSheet = geometry.size.width
                < CardSetupEditorLayoutMetrics.workspaceInspectorThreshold

            HStack(spacing: 0) {
                workspaceCanvas(setupIndex, showsInspectorButton: usesSheet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !usesSheet {
                    Divider()
                    workspaceInspector(setupIndex)
                        .frame(width: 320)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { workspaceUsesInspectorSheet = usesSheet }
            .onChange(of: usesSheet) { _, newValue in
                workspaceUsesInspectorSheet = newValue
                if !newValue { isInspectorPresented = false }
            }
        }
    }

    private func workspaceCanvas(
        _ setupIndex: Int,
        showsInspectorButton: Bool
    ) -> some View {
        let setup = draft.cardSetups[setupIndex]
        let projection = CardSetupEditorProjection(setup: setup, fields: draft.fields)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.name.isEmpty ? "Untitled Card setup" : setup.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Card canvas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.canvas)
                }
                Spacer(minLength: 8)
                workspaceAddContentMenu(setup)
                workspaceLayoutMenu(setup)
                answerVisibilityButton
                if showsInspectorButton {
                    Button("Inspector", systemImage: "sidebar.right") {
                        isInspectorPresented = true
                    }
                    .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
                    .accessibilityHint("Opens setup and selected-content controls")
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.inspectorButton)
                }
            }

            CardWireframeView(
                layout: setup.layout,
                components: projection.resolvedComponents,
                isAnswerRevealed: isAnswerRevealed,
                emptyHoleView: { hole in
                    AnyView(emptyHole(hole, setupIndex: setupIndex))
                }
            ) { component, hole in
                previewComponent(
                    component,
                    hole: hole,
                    setupIndex: setupIndex,
                    rendering: projection.previewRendering(
                        for: component,
                        isAnswerRevealed: isAnswerRevealed
                    )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Card canvas")
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.auditPreview)
        }
        .padding(16)
    }

    private func workspaceLayoutMenu(_ setup: CardSetupDraft) -> some View {
        Menu {
            ForEach(CardLayoutID.allCases, id: \.self) { layout in
                Button {
                    apply(.chooseLayout(layout))
                } label: {
                    Label(
                        layout.displayName,
                        systemImage: setup.layout == layout ? "checkmark" : "rectangle"
                    )
                }
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.layout(layout))
            }
        } label: {
            Label(setup.layout.displayName, systemImage: "rectangle.3.group")
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.layoutPicker)
        }
        .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
        .focused($focusedTarget, equals: .layout(cardSetupID: cardSetupID))
        .accessibilityLabel("Layout, \(setup.layout.displayName)")
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.layoutPicker)
    }

    private func workspaceAddContentMenu(_ setup: CardSetupDraft) -> some View {
        let descriptor = CardWireframeDescriptor.descriptor(for: setup.layout)
        return Menu("Add content", systemImage: "plus") {
            ForEach(descriptor.accessibilityHoles) { holeDescriptor in
                Button(holeDescriptor.hole.displayName) {
                    sourceRequest = .init(componentID: nil, hole: holeDescriptor.hole)
                }
            }
        }
        .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.addContent)
    }

    private var answerVisibilityButton: some View {
        Button(
            isAnswerRevealed ? "Hide Answer" : "Show Answer",
            systemImage: isAnswerRevealed ? "eye.slash" : "eye"
        ) {
            if reduceMotion {
                isAnswerRevealed.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { isAnswerRevealed.toggle() }
            }
        }
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.showAnswer)
        .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
    }

    private func workspaceInspector(
        _ setupIndex: Int,
        showsTitle: Bool = true
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showsTitle {
                    Text("Inspector")
                        .font(.headline)
                        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.inspector)
                }
                identitySection(setupIndex)
                recipeSection(setupIndex)
                selectedContentSection(setupIndex)
                advancedSection(setupIndex)
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card setup inspector")
    }

    private func workspaceInspectorSheet(_ setupIndex: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.inspector)
                Spacer()
                Button("Done") { isInspectorPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.inspectorDone)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            workspaceInspector(setupIndex, showsTitle: false)
        }
        .frame(
            minWidth: CardSetupEditorLayoutMetrics.macSourcePickerMinimumDimension,
            minHeight: 520
        )
        .sheet(item: $sourceRequest) { request in
            CardSetupSourcePicker(
                fields: sourceFields(for: request),
                allowsFixedText: request.hole != .media,
                componentID: request.componentID,
                hole: request.hole
            ) { source in
                apply(source: source, request: request, setupIndex: setupIndex)
            }
        }
    }

    @ViewBuilder
    private func selectedContentSection(_ setupIndex: Int) -> some View {
        let setup = draft.cardSetups[setupIndex]
        let descriptor = CardWireframeDescriptor.descriptor(for: setup.layout)
        let projection = CardSetupEditorProjection(setup: setup, fields: draft.fields)
        if let selectedComponentID,
           let componentIndex = setup.components.firstIndex(where: {
               $0.id == selectedComponentID
           }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Selected content").font(.headline)
                    Spacer()
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        duplicateComponent(selectedComponentID, setupIndex: setupIndex)
                    }
                    .labelStyle(.iconOnly)
                    .frame(
                        minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                        minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
                    )
                    .accessibilityLabel("Duplicate selected content")
                }
                if projection.isAdditional(selectedComponentID) {
                    additionalContentRow(
                        componentIndex,
                        setupIndex: setupIndex,
                        descriptor: descriptor
                    )
                    Text("Legacy placement stays unchanged until you move it into a named hole.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    componentEditorRow(
                        componentIndex,
                        setupIndex: setupIndex,
                        descriptor: descriptor
                    )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Selected content").font(.headline)
                Label("Select content on the card to edit it here.", systemImage: "cursorarrow.click")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setupIndex: Int? {
        draft.cardSetups.firstIndex { $0.id == cardSetupID }
    }

    private func applyValidationFocus(_ requestedTarget: ItemTypeStudioValidationTarget?) {
        let target = CardSetupEditorFocusPolicy.target(
            for: requestedTarget,
            cardSetupID: cardSetupID
        )
        guard let target, let setupIndex else {
            focusedTarget = nil
            return
        }

        let projection = CardSetupEditorProjection(
            setup: draft.cardSetups[setupIndex],
            fields: draft.fields
        )
        let disclosures = CardSetupEditorFocusPolicy.disclosures(
            for: target,
            cardSetupID: cardSetupID,
            additionalComponentIDs: projection.additionalComponentIDs
        )
        if disclosures.showsAdvanced { showsAdvanced = true }
        if disclosures.showsAdditionalContent { showsAdditionalContent = true }

        if case let .component(_, componentID) = target {
            selectedComponentID = componentID
        }
        let needsInspectorMount = presentation == .workspace
            && workspaceUsesInspectorSheet
            && targetUsesWorkspaceInspector(target)
        if needsInspectorMount { isInspectorPresented = true }

        guard disclosures.showsAdvanced
                || disclosures.showsAdditionalContent
                || needsInspectorMount
        else {
            focusedTarget = target
            return
        }
        // Give DisclosureGroup one render pass to mount the requested control;
        // focus then performs the ScrollView's normal reveal behavior.
        Task { @MainActor in
            await Task.yield()
            if needsInspectorMount { await Task.yield() }
            guard validationFocus == requestedTarget else { return }
            focusedTarget = target
        }
    }

    private func targetUsesWorkspaceInspector(
        _ target: ItemTypeStudioValidationTarget
    ) -> Bool {
        switch target {
        case .layout, .itemTypeName, .field:
            return false
        case .cardSetup, .availability, .answerMethod, .recipe, .component:
            return true
        }
    }

    @ViewBuilder
    private func auditEditorSection(
        _ section: CardSetupEditorAuditSection,
        setupIndex: Int
    ) -> some View {
        switch section {
        case .preview:
            auditSectionMarker(section)
            previewSection(setupIndex)
        case .additional:
            let setup = draft.cardSetups[setupIndex]
            let descriptor = CardWireframeDescriptor.descriptor(for: setup.layout)
            let projection = CardSetupEditorProjection(setup: setup, fields: draft.fields)
            if let componentIndex = setup.components.firstIndex(where: {
                projection.isAdditional($0.id)
            }) {
                auditSectionMarker(section)
                additionalContentRow(
                    componentIndex,
                    setupIndex: setupIndex,
                    descriptor: descriptor
                )
            }
        case .advanced:
            auditSectionMarker(section)
            advancedSection(setupIndex)
        case .availability:
            auditSectionMarker(section)
            availabilityEditor(setupIndex)
        case .learningRoute:
            auditSectionMarker(section)
            learningRouteEditor(setupIndex)
        }
    }

    private func auditSectionMarker(_ section: CardSetupEditorAuditSection) -> some View {
        Text("Accessibility audit: \(section.displayName)")
            .font(.caption)
            .foregroundStyle(.primary)
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.auditSection(section))
    }

    @ViewBuilder
    private func editorSections(_ setupIndex: Int) -> some View {
        identitySection(setupIndex)
        recipeSection(setupIndex)
        layoutSection(setupIndex)
        previewSection(setupIndex)
        namedContentSection(setupIndex)
        advancedSection(setupIndex)
    }

    private func identitySection(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Card setup")
                .font(.headline)
            TextField("Name", text: setupBinding(index, \.name))
                .textFieldStyle(.roundedBorder)
                .focused($focusedTarget, equals: .cardSetup(cardSetupID))
                .accessibilityLabel("Card setup name")
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.cardSetupName)
                .frame(minHeight: 44)
            validationMessages(for: .cardSetup(cardSetupID))
        }
    }

    private func recipeSection(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipe")
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { recipeContents(index) }
                VStack(alignment: .leading, spacing: 12) { recipeContents(index) }
            }
            validationMessages(for: .recipe(cardSetupID: cardSetupID, purpose: .question))
            validationMessages(for: .answerMethod(cardSetupID: cardSetupID))
            validationMessages(for: .recipe(
                cardSetupID: cardSetupID,
                purpose: .expectedAnswer
            ))
        }
    }

    @ViewBuilder
    private func recipeContents(_ index: Int) -> some View {
        recipeSourceButton(title: "Question", purpose: .question, setupIndex: index)
        Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        Picker("Answer method", selection: interactionBinding(index)) {
            ForEach(Interaction.allCases, id: \.self) { interaction in
                Text(interaction.editorDisplayName).tag(interaction)
            }
        }
        .focused($focusedTarget, equals: .answerMethod(cardSetupID: cardSetupID))
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.answerMethod)
        .frame(minWidth: 160, minHeight: 44)
        Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        if draft.cardSetups[index].interaction == .audioSubmission {
            VStack(alignment: .leading, spacing: 2) {
                Label("Spoken response", systemImage: "waveform")
                Text("Responses remain private on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        } else {
            recipeSourceButton(title: "Answer", purpose: .expectedAnswer, setupIndex: index)
        }
    }

    private func recipeSourceButton(
        title: String,
        purpose: ComponentPurpose,
        setupIndex: Int
    ) -> some View {
        let setup = draft.cardSetups[setupIndex]
        let component = setup.components.first { $0.purpose == purpose }
        return Button {
            let hole: CardWireframeHole = purpose == .question ? .question : .answer
            sourceRequest = .init(componentID: component?.id, hole: hole)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(component.map { sourceLabel($0.source) } ?? "Choose content")
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Choose a field or fixed text")
        .accessibilityIdentifier(
            purpose == .question
                ? ItemTypeStudioAccessibilityID.recipeQuestion
                : ItemTypeStudioAccessibilityID.recipeAnswer
        )
        .focused(
            $focusedTarget,
            equals: .recipe(cardSetupID: cardSetupID, purpose: purpose)
        )
    }

    private func layoutSection(_ index: Int) -> some View {
        let setup = draft.cardSetups[index]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layout").font(.headline)
                Spacer()
                if let recommendation = setup.recommendation {
                    Label(
                        "Recommended: \(recommendation.layout.displayName)",
                        systemImage: "sparkles"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(CardLayoutID.allCases, id: \.self) { layout in
                    CardLayoutChoice(
                        layout: layout,
                        isSelected: setup.layout == layout,
                        isRecommended: setup.recommendation?.layout == layout
                    ) {
                        apply(.chooseLayout(layout))
                    }
                    .focused($focusedTarget, equals: .layout(cardSetupID: cardSetupID))
                }
            }
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.layoutPicker)
            Text(setup.layout.guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
            validationMessages(for: .layout(cardSetupID: cardSetupID))
        }
    }

    private func previewSection(_ index: Int) -> some View {
        let setup = draft.cardSetups[index]
        let projection = CardSetupEditorProjection(setup: setup, fields: draft.fields)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                answerVisibilityButton
            }

            CardWireframeView(
                layout: setup.layout,
                components: projection.resolvedComponents,
                isAnswerRevealed: isAnswerRevealed,
                emptyHoleView: { hole in
                    AnyView(emptyHole(hole, setupIndex: index))
                }
            ) { component, hole in
                previewComponent(
                    component,
                    hole: hole,
                    setupIndex: index,
                    rendering: projection.previewRendering(
                        for: component,
                        isAnswerRevealed: isAnswerRevealed
                    )
                )
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .padding(16)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.auditPreview)
    }

    @ViewBuilder
    private func emptyHole(_ hole: CardWireframeHole, setupIndex: Int) -> some View {
        let usesIncreasedContrast = colorSchemeContrast == .increased
        let foreground: Color = usesIncreasedContrast
            ? (colorScheme == .dark ? .black : .white)
            : .primary
        let background: Color = usesIncreasedContrast
            ? (colorScheme == .dark ? .white : .black)
            : Color.accentColor.opacity(0.12)
        let border: Color = usesIncreasedContrast
            ? foreground
            : Color.accentColor.opacity(0.5)

        Button {
            sourceRequest = .init(componentID: nil, hole: hole)
        } label: {
            Label("Add \(hole.displayName)", systemImage: "plus")
                .font(.callout)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(border, lineWidth: usesIncreasedContrast ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
#if !os(macOS)
        .accessibilityElement(children: .ignore)
#endif
        .accessibilityLabel("Add \(hole.displayName)")
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.hole(hole))
    }

    private func previewComponent(
        _ component: ResolvedTemplateComponent,
        hole: CardWireframeHole,
        setupIndex: Int,
        rendering: CardSetupEditorPreviewRendering
    ) -> some View {
        let isSelected = presentation == .workspace && selectedComponentID == component.id
        return Button {
            if presentation == .workspace {
                selectedComponentID = component.id
                if workspaceUsesInspectorSheet { isInspectorPresented = true }
            } else {
                sourceRequest = .init(componentID: component.id, hole: hole)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Label(
                    component.value.editorPreviewText,
                    systemImage: previewSymbol(for: component.id, setupIndex: setupIndex)
                )
                .lineLimit(3)
                .blur(radius: rendering == .blurred ? 8 : 0)
                .opacity(rendering == .concealed ? 0 : 1)

                if rendering != .content {
                    Label(
                        rendering == .blurred ? "Blurred until answer" : "Concealed until answer",
                        systemImage: "eye.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
            .padding(.horizontal, 10)
            .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
#if !os(macOS)
        .accessibilityElement(children: .ignore)
#endif
        .accessibilityLabel(previewAccessibilityLabel(component, rendering: rendering))
        .accessibilityHint(
            presentation == .workspace
                ? "Selects this content for editing"
                : "Edit this content source"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.component(component.id))
    }

    private func namedContentSection(_ index: Int) -> some View {
        let setup = draft.cardSetups[index]
        let descriptor = CardWireframeDescriptor.descriptor(for: setup.layout)
        let projection = CardSetupEditorProjection(setup: setup, fields: draft.fields)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Content").font(.headline)
            ForEach(descriptor.accessibilityHoles) { holeDescriptor in
                let componentIndices = setup.components.indices.filter { componentIndex in
                    let component = setup.components[componentIndex]
                    return descriptor.hole(for: component.region) == holeDescriptor.hole
                        && !projection.isAdditional(component.id)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(holeDescriptor.hole.displayName).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Add", systemImage: "plus") {
                            sourceRequest = .init(componentID: nil, hole: holeDescriptor.hole)
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Add \(holeDescriptor.hole.displayName) content")
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    if componentIndices.isEmpty {
                        Text("No content")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(componentIndices, id: \.self) { componentIndex in
                        componentEditorRow(componentIndex, setupIndex: index, descriptor: descriptor)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }

            if !projection.additionalComponentIDs.isEmpty {
                DisclosureGroup("Additional content", isExpanded: $showsAdditionalContent) {
                    VStack(spacing: 8) {
                        ForEach(setup.components.indices.filter {
                            projection.isAdditional(setup.components[$0].id)
                        }, id: \.self) { componentIndex in
                            additionalContentRow(componentIndex, setupIndex: index, descriptor: descriptor)
                        }
                    }
                    .padding(.top, 8)
                }
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.additionalContent)
                .frame(
                    maxWidth: .infinity,
                    minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                    alignment: .leading
                )
                Text("Legacy placement stays unchanged until you explicitly move it into a named hole.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func componentEditorRow(
        _ componentIndex: Int,
        setupIndex: Int,
        descriptor: CardWireframeDescriptor
    ) -> some View {
        let component = draft.cardSetups[setupIndex].components[componentIndex]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(sourceLabel(component.source)) {
                    sourceRequest = .init(
                        componentID: component.id,
                        hole: descriptor.hole(for: component.region)
                    )
                }
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .focused(
                    $focusedTarget,
                    equals: .component(cardSetupID: cardSetupID, componentID: component.id)
                )

                localMoveButtons(
                    componentIndex,
                    setupIndex: setupIndex,
                    descriptor: descriptor
                )

                Button("Remove", systemImage: "trash", role: .destructive) {
                    apply(.removeComponent(component.id))
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Remove \(sourceLabel(component.source))")
                .frame(minWidth: 44, minHeight: 44)
            }
            componentContextControls(componentIndex, setupIndex: setupIndex)
            validationMessages(for: .component(
                cardSetupID: cardSetupID,
                componentID: component.id
            ))
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func additionalContentRow(
        _ componentIndex: Int,
        setupIndex: Int,
        descriptor: CardWireframeDescriptor
    ) -> some View {
        let component = draft.cardSetups[setupIndex].components[componentIndex]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(sourceLabel(component.source)) {
                    sourceRequest = .init(
                        componentID: component.id,
                        hole: descriptor.hole(for: component.region)
                    )
                }
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel("Edit source, \(sourceLabel(component.source))")
                .accessibilityIdentifier(
                    ItemTypeStudioAccessibilityID.additionalSource(component.id)
                )

                placementMoveButtons(componentIndex, setupIndex: setupIndex)

                Button("Remove", systemImage: "trash", role: .destructive) {
                    apply(.removeComponent(component.id))
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Remove \(sourceLabel(component.source))")
                .frame(minWidth: 44, minHeight: 44)
            }
            Text("Stored as \(component.region.rawValue) / \(component.purpose.editorDisplayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu("Move into named hole", systemImage: "arrow.turn.down.right") {
                ForEach(descriptor.accessibilityHoles) { holeDescriptor in
                    Button(holeDescriptor.hole.displayName) {
                        apply(.canonicalize(componentID: component.id, hole: holeDescriptor.hole))
                    }
                }
            }
            .frame(
                minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
            )
            .focused(
                $focusedTarget,
                equals: .component(cardSetupID: cardSetupID, componentID: component.id)
            )
            componentContextControls(componentIndex, setupIndex: setupIndex)
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func componentContextControls(_ componentIndex: Int, setupIndex: Int) -> some View {
        let component = draft.cardSetups[setupIndex].components[componentIndex]
        if case .fixedText = component.source {
            TextField("Fixed text", text: fixedTextBinding(componentIndex, setupIndex: setupIndex), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.fixedText(component.id))
                .frame(minHeight: 44)
        }

        let selectedFieldType = fieldType(for: component.source)
        let allowedRevealModes = CardSetupRevealControlPolicy.allowedModes(
            purpose: component.purpose,
            fieldType: selectedFieldType
        )
        if allowedRevealModes.contains(component.reveal) {
            Picker("Reveal", selection: revealBinding(component.id, setupIndex: setupIndex)) {
                ForEach(allowedRevealModes, id: \.self) { mode in
                    Text(mode.editorDisplayName).tag(mode)
                }
            }
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.reveal(component.id))
            .frame(minHeight: 44)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Stored reveal “\(component.reveal.editorDisplayName)” is not valid for this content.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                let repair = CardSetupRevealControlPolicy.repairMode(
                    purpose: component.purpose,
                    fieldType: selectedFieldType
                )
                Button("Use \(repair.editorDisplayName)") {
                    apply(.setReveal(componentID: component.id, repair))
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier(
                    ItemTypeStudioAccessibilityID.revealRepair(component.id)
                )
            }
        }

        let supportedMedia = MediaBehavior.supported(for: mediaKind(for: component.source))
        if !component.mediaBehavior.isSupported(for: mediaKind(for: component.source)) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Stored playback is not compatible with this content.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button("Use Default Playback") {
                    apply(.repairMediaBehavior(component.id))
                }
                .frame(
                    minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                    minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
                )
            }
        } else if supportedMedia.count > 1 {
            Picker("Playback", selection: componentBinding(componentIndex, setupIndex, \.mediaBehavior)) {
                ForEach(supportedMedia, id: \.self) { behavior in
                    Text(behavior.editorDisplayName).tag(behavior)
                }
            }
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.playback(component.id))
            .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
        }
    }

    private func localMoveButtons(
        _ componentIndex: Int,
        setupIndex: Int,
        descriptor: CardWireframeDescriptor
    ) -> some View {
        let siblings = canonicalSiblingIndices(
            for: componentIndex,
            setupIndex: setupIndex,
            descriptor: descriptor
        )
        let localIndex = siblings.firstIndex(of: componentIndex)
        return HStack(spacing: 0) {
            Button("Move Up", systemImage: "chevron.up") {
                moveWithinHole(
                    componentIndex,
                    by: -1,
                    setupIndex: setupIndex,
                    descriptor: descriptor
                )
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Move content up")
            .disabled(localIndex == nil || localIndex == siblings.startIndex)
            .frame(minWidth: 44, minHeight: 44)
            Button("Move Down", systemImage: "chevron.down") {
                moveWithinHole(
                    componentIndex,
                    by: 1,
                    setupIndex: setupIndex,
                    descriptor: descriptor
                )
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Move content down")
            .disabled(localIndex == nil || localIndex == siblings.index(before: siblings.endIndex))
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    private func placementMoveButtons(
        _ componentIndex: Int,
        setupIndex: Int
    ) -> some View {
        let siblings = additionalComponentIndices(setupIndex: setupIndex)
        let localIndex = siblings.firstIndex(of: componentIndex)
        let componentID = draft.cardSetups[setupIndex].components[componentIndex].id
        return HStack(spacing: 0) {
            Button("Move Up", systemImage: "chevron.up") {
                apply(.moveAdditionalComponent(componentID, .earlier))
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Move content up")
            .accessibilityIdentifier(
                ItemTypeStudioAccessibilityID.additionalMoveUp(componentID)
            )
            .disabled(localIndex == nil || localIndex == siblings.startIndex)
            .frame(minWidth: 44, minHeight: 44)
            Button("Move Down", systemImage: "chevron.down") {
                apply(.moveAdditionalComponent(componentID, .later))
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Move content down")
            .accessibilityIdentifier(
                ItemTypeStudioAccessibilityID.additionalMoveDown(componentID)
            )
            .disabled(localIndex == nil || localIndex == siblings.index(before: siblings.endIndex))
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    private func advancedSection(_ index: Int) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                showsAdvanced.toggle()
            } label: {
                HStack {
                    Text("Advanced").font(.headline)
                    Spacer()
                    Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Optional Availability and Learning route settings")
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.advanced)
            .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
            .frame(
                maxWidth: .infinity,
                minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                alignment: .leading
            )

            if showsAdvanced {
                VStack(alignment: .leading, spacing: 20) {
                    availabilityEditor(index)
                    Divider()
                    learningRouteEditor(index)
                }
                .padding(.top, 12)
            }
        }
    }

    private func availabilityEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Availability rule", isOn: availabilityEnabledBinding(index))
                .neoAnkiTouchTarget()
                .focused($focusedTarget, equals: .availability(cardSetupID: cardSetupID))
                .accessibilityIdentifier(ItemTypeStudioAccessibilityID.availability)
            Text("Generate this Card setup only when its content is available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if draft.cardSetups[index].availability != nil {
                AvailabilityRuleEditor(
                    rule: availabilityBinding(index),
                    fields: draft.fields,
                    depth: 0
                )
                validationMessages(for: .availability(cardSetupID: cardSetupID))
            }
        }
    }

    private func learningRouteEditor(_ index: Int) -> some View {
        let setup = draft.cardSetups[index]
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Learning route").font(.subheadline.weight(.semibold))
                    Spacer()
                    recommendationButton(setup)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Learning route").font(.subheadline.weight(.semibold))
                    recommendationButton(setup)
                }
            }
            Picker("Input", selection: skillBinding(index, \.input)) {
                ForEach(Modality.allCases, id: \.self) { Text($0.editorDisplayName).tag($0) }
            }
            .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
            Picker("Output", selection: skillBinding(index, \.output)) {
                ForEach(Modality.allCases, id: \.self) { Text($0.editorDisplayName).tag($0) }
            }
            .disabled(setup.interaction == .audioSubmission)
            .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
            Picker("Operation", selection: skillBinding(index, \.operation)) {
                ForEach(NeoAnkiCore.Operation.allCases, id: \.self) {
                    Text($0.editorDisplayName).tag($0)
                }
            }
            .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
            Text("Using the recommendation changes only Input, Output, and Operation. Your selected Layout stays unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.learningRoute)
    }

    @ViewBuilder
    private func recommendationButton(_ setup: CardSetupDraft) -> some View {
        if setup.recommendation != nil {
            Button("Use recommended route") { apply(.useRecommendation) }
                .accessibilityHint("Updates the Learning route without changing Layout")
                .frame(
                    minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                    minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
                )
        }
    }

    @ViewBuilder
    private func validationMessages(for target: ItemTypeStudioValidationTarget) -> some View {
        ForEach(draft.validationIssues.filter { $0.target == target }) { issue in
            Label(issue.message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(issue.message)")
        }
    }

    private func interactionBinding(_ setupIndex: Int) -> Binding<Interaction> {
        let setup = draft.cardSetups[setupIndex]
        return Binding(
            get: {
                draft.cardSetups.first(where: { $0.id == setup.id })?.interaction
                    ?? setup.interaction
            },
            set: { interaction in
                guard let current = draft.cardSetups.first(where: { $0.id == setup.id }) else {
                    return
                }
                if interaction == .audioSubmission,
                   current.requiresAudioAnswerRemovalConfirmation {
                    pendingAudioSubmission = true
                    return
                }
                apply(.setInteraction(interaction, confirmAudioAnswerRemoval: false))
            }
        )
    }

    private func availabilityEnabledBinding(_ index: Int) -> Binding<Bool> {
        let setup = draft.cardSetups[index]
        return Binding(
            get: {
                draft.cardSetups.first(where: { $0.id == setup.id })?.availability != nil
            },
            set: { enabled in
                guard draft.cardSetups.contains(where: { $0.id == setup.id }) else { return }
                apply(.setAvailability(
                    enabled ? .fieldPresent(draft.fields.first?.id) : nil
                ))
            }
        )
    }

    private func availabilityBinding(_ index: Int) -> Binding<CardSetupAvailabilityDraft> {
        let setup = draft.cardSetups[index]
        return CardSetupEditorBindingFactory.availability(
            draft: $draft,
            cardSetupID: setup.id,
            fallback: setup.availability ?? .fieldPresent(nil)
        )
    }

    private func setupBinding<Value: Sendable>(
        _ index: Int,
        _ keyPath: WritableKeyPath<CardSetupDraft, Value>
    ) -> Binding<Value> {
        let setup = draft.cardSetups[index]
        return CardSetupEditorBindingFactory.setupValue(
            draft: $draft,
            cardSetupID: setup.id,
            keyPath: keyPath,
            fallback: setup[keyPath: keyPath]
        )
    }

    private func componentBinding<Value: Sendable>(
        _ componentIndex: Int,
        _ setupIndex: Int,
        _ keyPath: WritableKeyPath<CardSetupComponentDraft, Value>
    ) -> Binding<Value> {
        let component = draft.cardSetups[setupIndex].components[componentIndex]
        return CardSetupEditorBindingFactory.componentValue(
            draft: $draft,
            cardSetupID: cardSetupID,
            componentID: component.id,
            keyPath: keyPath,
            fallback: component[keyPath: keyPath]
        )
    }

    private func revealBinding(_ componentID: UUID, setupIndex: Int) -> Binding<RevealMode> {
        let fallback = draft.cardSetups[setupIndex].components
            .first(where: { $0.id == componentID })?.reveal ?? .hiddenUntilAnswer
        return CardSetupEditorBindingFactory.reveal(
            draft: $draft,
            cardSetupID: cardSetupID,
            componentID: componentID,
            fallback: fallback
        )
    }

    private func skillBinding<Value: Sendable>(
        _ setupIndex: Int,
        _ keyPath: WritableKeyPath<Skill, Value>
    ) -> Binding<Value> {
        let setup = draft.cardSetups[setupIndex]
        let fallback = setup.learningRoute[keyPath: keyPath]
        let keyPath = SendableWritableKeyPath(value: keyPath)
        return Binding(
            get: {
                draft.cardSetups.first(where: { $0.id == setup.id })?
                    .learningRoute[keyPath: keyPath.value] ?? fallback
            },
            set: { value in
                guard let index = draft.cardSetups.firstIndex(where: { $0.id == setup.id }) else {
                    return
                }
                draft.cardSetups[index].learningRoute[keyPath: keyPath.value] = value
            }
        )
    }

    private func fixedTextBinding(_ componentIndex: Int, setupIndex: Int) -> Binding<String> {
        let component = draft.cardSetups[setupIndex].components[componentIndex]
        let fallback: String
        if case let .fixedText(value) = component.source {
            fallback = value
        } else {
            fallback = ""
        }
        return CardSetupEditorBindingFactory.fixedText(
            draft: $draft,
            cardSetupID: cardSetupID,
            componentID: component.id,
            fallback: fallback
        )
    }

    private func apply(
        source: CardSetupComponentSourceDraft,
        request: CardSetupSourceRequest,
        setupIndex: Int
    ) {
        guard draft.cardSetups.indices.contains(setupIndex),
              draft.cardSetups[setupIndex].id == cardSetupID else { return }
        if let componentID = request.componentID,
           draft.cardSetups[setupIndex].components.contains(where: { $0.id == componentID }) {
            apply(.changeSource(componentID: componentID, source: source))
        } else {
            let existingIDs = Set(draft.cardSetups[setupIndex].components.map(\.id))
            if apply(.addComponent(source: source, hole: request.hole)),
               let added = draft.cardSetups[setupIndex].components.first(where: {
                   !existingIDs.contains($0.id)
               }) {
                selectedComponentID = added.id
                if presentation == .workspace && workspaceUsesInspectorSheet {
                    Task { @MainActor in
                        await Task.yield()
                        isInspectorPresented = true
                    }
                }
            }
        }
    }

    private func duplicateComponent(_ componentID: UUID, setupIndex: Int) {
        guard draft.cardSetups.indices.contains(setupIndex) else { return }
        let existingIDs = Set(draft.cardSetups[setupIndex].components.map(\.id))
        guard apply(.duplicateComponent(componentID)),
              let duplicate = draft.cardSetups[setupIndex].components.first(where: {
                  !existingIDs.contains($0.id)
              })
        else { return }
        selectedComponentID = duplicate.id
    }

    private func canonicalSiblingIndices(
        for index: Int,
        setupIndex: Int,
        descriptor: CardWireframeDescriptor
    ) -> [Int] {
        let components = draft.cardSetups[setupIndex].components
        guard components.indices.contains(index) else { return [] }
        let hole = descriptor.hole(for: components[index].region)
        let insertion = descriptor.canonicalInsertion(for: hole)
        return components.indices.filter { candidateIndex in
            let candidate = components[candidateIndex]
            return candidate.region == insertion.region && candidate.purpose == insertion.purpose
        }
    }

    private func additionalComponentIndices(setupIndex: Int) -> [Int] {
        let components = draft.cardSetups[setupIndex].components
        let descriptor = CardWireframeDescriptor.descriptor(
            for: draft.cardSetups[setupIndex].layout
        )
        return components.indices.filter { candidateIndex in
            let candidate = components[candidateIndex]
            let hole = descriptor.hole(for: candidate.region)
            let insertion = descriptor.canonicalInsertion(for: hole)
            return insertion.region != candidate.region || insertion.purpose != candidate.purpose
        }
    }

    private func moveWithinHole(
        _ index: Int,
        by offset: Int,
        setupIndex: Int,
        descriptor: CardWireframeDescriptor
    ) {
        let siblings = canonicalSiblingIndices(
            for: index,
            setupIndex: setupIndex,
            descriptor: descriptor
        )
        guard let localIndex = siblings.firstIndex(of: index) else { return }
        let destination = localIndex + offset
        guard siblings.indices.contains(destination) else { return }
        let id = draft.cardSetups[setupIndex].components[index].id
        apply(.moveComponent(
            id,
            offset < 0 ? .earlier : .later
        ))
    }

    @discardableResult
    private func apply(_ action: CardSetupEditorAction) -> Bool {
        CardSetupEditorReducer.apply(action, to: &draft, cardSetupID: cardSetupID)
    }

    private func sourceLabel(_ source: CardSetupComponentSourceDraft) -> String {
        switch source {
        case let .field(id):
            return id.flatMap { selected in draft.fields.first(where: { $0.id == selected })?.name }
                ?? "Choose content"
        case let .fixedText(text):
            return text.isEmpty ? "Fixed text" : text
        }
    }

    private func sourceFields(for request: CardSetupSourceRequest) -> [ItemTypeFieldDraft] {
        guard request.hole == .media else { return draft.fields }
        return draft.fields.filter { [.image, .gif, .video].contains($0.type) }
    }

    private func mediaKind(for source: CardSetupComponentSourceDraft) -> MediaKind? {
        guard let id = source.fieldID else { return nil }
        return draft.fields.first(where: { $0.id == id })?.type.mediaKind
    }

    private func fieldType(for source: CardSetupComponentSourceDraft) -> FieldType? {
        guard let id = source.fieldID else { return nil }
        return draft.fields.first(where: { $0.id == id })?.type
    }

    private func previewSymbol(for componentID: UUID, setupIndex: Int) -> String {
        guard let component = draft.cardSetups[setupIndex].components.first(where: { $0.id == componentID }) else {
            return "square.dashed"
        }
        if case .fixedText = component.source { return "text.quote" }
        switch mediaKind(for: component.source) {
        case .audio: return "waveform"
        case .image, .gif: return "photo"
        case .video: return "video"
        case nil: return "text.alignleft"
        }
    }

    private func previewAccessibilityLabel(
        _ component: ResolvedTemplateComponent,
        rendering: CardSetupEditorPreviewRendering
    ) -> String {
        let value = component.value.editorPreviewText
        switch rendering {
        case .content: return value
        case .blurred: return "\(value), blurred until answer"
        case .concealed: return "\(value), concealed until answer"
        }
    }
}

private struct CardSetupSourceRequest: Identifiable {
    let id = UUID()
    let componentID: UUID?
    let hole: CardWireframeHole
}

private struct CardSetupSourcePicker: View {
    @Environment(\.dismiss) private var dismiss
    let fields: [ItemTypeFieldDraft]
    let allowsFixedText: Bool
    let componentID: UUID?
    let hole: CardWireframeHole
    let onSelect: (CardSetupComponentSourceDraft) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Fields") {
                    ForEach(filteredFields) { field in
                        Button {
                            onSelect(.field(field.id))
                            dismiss()
                        } label: {
                            LabeledContent(field.name, value: field.type.editorDisplayName)
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.sourcePickerField(
                            componentID: componentID,
                            hole: hole,
                            fieldID: field.id
                        ))
                    }
                }
                if allowsFixedText {
                    Section("Other") {
                        Button("Fixed text", systemImage: "text.quote") {
                            onSelect(.fixedText(""))
                            dismiss()
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.sourcePickerFixedText(
                            componentID: componentID,
                            hole: hole
                        ))
                    }
                }
            }
            .searchable(text: $query, prompt: "Search fields")
            .navigationTitle("Choose content")
            .toolbar {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier(ItemTypeStudioAccessibilityID.sourcePickerCancel(
                        componentID: componentID,
                        hole: hole
                    ))
            }
        }
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.sourcePicker(
            componentID: componentID,
            hole: hole
        ))
#if os(macOS)
        .frame(
            minWidth: CardSetupEditorLayoutMetrics.macSourcePickerMinimumDimension,
            minHeight: CardSetupEditorLayoutMetrics.macSourcePickerMinimumDimension
        )
#endif
        .presentationDetents([.medium, .large])
    }

    private var filteredFields: [ItemTypeFieldDraft] {
        guard !query.isEmpty else { return fields }
        return fields.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct CardLayoutChoice: View {
    let layout: CardLayoutID
    let isSelected: Bool
    let isRecommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CardLayoutThumbnail(layout: layout)
                    .frame(height: 64)
                HStack(spacing: 4) {
                    Text(layout.displayName).font(.caption)
                    if isRecommended {
                        Image(systemName: "sparkles")
                            .accessibilityLabel("Recommended")
                    }
                }
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(6)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(layout.displayName) layout")
        .accessibilityValue(isSelected ? "Selected" : (isRecommended ? "Recommended" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(ItemTypeStudioAccessibilityID.layout(layout))
    }
}

private struct CardLayoutThumbnail: View {
    let layout: CardLayoutID

    var body: some View {
        GeometryReader { proxy in
            let descriptor = CardWireframeDescriptor.descriptor(for: layout)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.background)
                ForEach(descriptor.holes) { hole in
                    let frame = hole.thumbnailFrame
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hole.hole == .answer ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.32))
                        .frame(
                            width: proxy.size.width * frame.width,
                            height: proxy.size.height * frame.height
                        )
                        .offset(
                            x: proxy.size.width * frame.x,
                            y: proxy.size.height * frame.y
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AvailabilityRuleEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var rule: CardSetupAvailabilityDraft
    let fields: [ItemTypeFieldDraft]
    let depth: Int
    @State private var identityState: AvailabilityRuleEditorIdentityState

    private enum Combination: String, CaseIterable {
        case all, any
    }

    init(
        rule: Binding<CardSetupAvailabilityDraft>,
        fields: [ItemTypeFieldDraft],
        depth: Int
    ) {
        _rule = rule
        self.fields = fields
        self.depth = depth
        let childCount: Int = switch rule.wrappedValue {
        case let .all(children), let .any(children): children.count
        case .fieldPresent, .fieldAbsent: 0
        }
        _identityState = State(initialValue: .init(childCount: childCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch rule {
            case .fieldPresent, .fieldAbsent:
                leafEditor
                Button("Add another rule", systemImage: "plus") {
                    identityState = .init(childCount: 2)
                    rule = .all([rule, .fieldPresent(fields.first?.id)])
                }
                .frame(
                    minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                    minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
                )
            case let .all(children), let .any(children):
                combinationPicker
                ForEach(Array(zip(identityState.childIDs, children)), id: \.0) { childID, child in
                    VStack(alignment: .leading, spacing: 8) {
                        AnyView(AvailabilityRuleEditor(
                            rule: childBinding(childID, fallback: child),
                            fields: fields,
                            depth: depth + 1
                        ))
                        Button("Remove rule", systemImage: "minus.circle", role: .destructive) {
                            removeChild(childID)
                        }
                        .frame(
                            minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                            minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
                        )
                    }
                    .padding(
                        .leading,
                        CardSetupEditorLayoutMetrics.availabilityIndentationIncrement(
                            parentDepth: depth
                        )
                    )
                }
                Button("Add rule", systemImage: "plus") { appendChild() }
                    .frame(
                        minWidth: CardSetupEditorLayoutMetrics.minimumTouchTarget,
                        minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget
                    )
            }
        }
        .onChange(of: childCount, initial: true) { _, count in
            guard identityState.childIDs.count != count else { return }
            identityState.reconcile(childCount: count)
        }
    }

    private var childCount: Int {
        switch rule {
        case let .all(children), let .any(children): children.count
        case .fieldPresent, .fieldAbsent: 0
        }
    }

    @ViewBuilder
    private var combinationPicker: some View {
        if CardSetupEditorLayoutMetrics.usesVerticalAvailabilityControls(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            availableWidth: nil
        ) {
            Picker("Match", selection: combinationBinding) {
                Text("All rules").tag(Combination.all)
                Text("Any rule").tag(Combination.any)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.availabilityCombination)
            .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
        } else {
            Picker("Match", selection: combinationBinding) {
                Text("All rules").tag(Combination.all)
                Text("Any rule").tag(Combination.any)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(ItemTypeStudioAccessibilityID.availabilityCombination)
            .frame(minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget)
        }
    }

    private var leafEditor: some View {
        AvailabilityControlsLayout(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            spacing: 8
        ) {
            leafControls
        }
    }

    @ViewBuilder
    private var leafControls: some View {
        Picker("Field", selection: leafFieldBinding) {
            if fields.isEmpty { Text("Choose a field").tag(Optional<UUID>.none) }
            ForEach(fields) { Text($0.name).tag(Optional($0.id)) }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget,
            alignment: .leading
        )
        Picker("Condition", selection: leafPresenceBinding) {
            Text("Is present").tag(true)
            Text("Is absent").tag(false)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: CardSetupEditorLayoutMetrics.minimumTouchTarget,
            alignment: .leading
        )
    }

    private var leafFieldBinding: Binding<UUID?> {
        Binding(
            get: {
                switch rule {
                case let .fieldPresent(id), let .fieldAbsent(id): return id
                case .all, .any: return nil
                }
            },
            set: { id in
                let present = leafPresenceBinding.wrappedValue
                rule = present ? .fieldPresent(id) : .fieldAbsent(id)
            }
        )
    }

    private var leafPresenceBinding: Binding<Bool> {
        Binding(
            get: {
                if case .fieldAbsent = rule { return false }
                return true
            },
            set: { present in
                let id = leafFieldBinding.wrappedValue
                rule = present ? .fieldPresent(id) : .fieldAbsent(id)
            }
        )
    }

    private var combinationBinding: Binding<Combination> {
        Binding(
            get: {
                if case .any = rule { return .any }
                return .all
            },
            set: { combination in
                let children: [CardSetupAvailabilityDraft]
                switch rule {
                case let .all(values), let .any(values): children = values
                case .fieldPresent, .fieldAbsent: children = [rule]
                }
                rule = combination == .all ? .all(children) : .any(children)
            }
        )
    }

    private func childBinding(
        _ childID: UUID,
        fallback: CardSetupAvailabilityDraft
    ) -> Binding<CardSetupAvailabilityDraft> {
        Binding(
            get: {
                guard let index = identityState.childIDs.firstIndex(of: childID) else {
                    return fallback
                }
                switch rule {
                case let .all(children), let .any(children):
                    return children.indices.contains(index) ? children[index] : fallback
                case .fieldPresent, .fieldAbsent: return fallback
                }
            },
            set: { child in
                guard let index = identityState.childIDs.firstIndex(of: childID) else {
                    return
                }
                switch rule {
                case var .all(children):
                    guard children.indices.contains(index) else { return }
                    children[index] = child
                    rule = .all(children)
                case var .any(children):
                    guard children.indices.contains(index) else { return }
                    children[index] = child
                    rule = .any(children)
                case .fieldPresent, .fieldAbsent: return
                }
            }
        )
    }

    private func appendChild() {
        switch rule {
        case var .all(children):
            _ = identityState.appendChild()
            children.append(.fieldPresent(fields.first?.id))
            rule = .all(children)
        case var .any(children):
            _ = identityState.appendChild()
            children.append(.fieldPresent(fields.first?.id))
            rule = .any(children)
        case .fieldPresent, .fieldAbsent:
            identityState = .init(childCount: 2)
            rule = .all([rule, .fieldPresent(fields.first?.id)])
        }
    }

    private func removeChild(_ childID: UUID) {
        guard let index = identityState.removeChild(id: childID) else { return }
        switch rule {
        case var .all(children):
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
            rule = .all(children)
        case var .any(children):
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
            rule = .any(children)
        case .fieldPresent, .fieldAbsent:
            break
        }
    }
}

/// Places the two Availability leaf controls without constructing duplicate
/// bound Pickers. `ViewThatFits` evaluates both candidate branches, which can
/// keep AppKit picker projections invalidating AttributeGraph while a nested
/// rule is lazily mounted or scrolled. A custom layout keeps one semantic and
/// binding identity per control while retaining the same responsive geometry.
private struct AvailabilityControlsLayout: Layout {
    let isAccessibilitySize: Bool
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let horizontalIntrinsicWidth = intrinsicWidth(subviews: subviews, isVertical: false)
        let width = finiteWidth(proposal.width) ?? horizontalIntrinsicWidth
        let isVertical = usesVerticalLayout(availableWidth: width)

        if isVertical {
            let heights = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            }
            return CGSize(
                width: width,
                height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
            )
        }

        let childWidth = max(0, (width - spacing * CGFloat(max(0, subviews.count - 1)))
            / CGFloat(subviews.count))
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: childWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        if usesVerticalLayout(availableWidth: bounds.width) {
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: size.height)
                )
                y += size.height + spacing
            }
            return
        }

        let childWidth = max(0, (bounds.width - spacing * CGFloat(max(0, subviews.count - 1)))
            / CGFloat(subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index) * (childWidth + spacing),
                    y: bounds.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: childWidth, height: bounds.height)
            )
        }
    }

    private func usesVerticalLayout(availableWidth: CGFloat?) -> Bool {
        CardSetupEditorLayoutMetrics.usesVerticalAvailabilityControls(
            isAccessibilitySize: isAccessibilitySize,
            availableWidth: availableWidth
        )
    }

    private func finiteWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite else { return nil }
        return max(0, width)
    }

    private func intrinsicWidth(subviews: Subviews, isVertical: Bool) -> CGFloat {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        if isVertical { return widths.max() ?? 0 }
        return widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
    }
}

private extension ContentValue {
    var editorPreviewText: String {
        switch self {
        case let .text(text, _): text
        case let .rich(spans): spans.map(\.text).joined()
        case .media: "Media"
        case let .cloze(text, _): text
        case let .number(value): value.formatted()
        case .empty: "Choose content"
        }
    }
}

private extension FieldType {
    var editorDisplayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .audio: "Audio"
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        case .number: "Number"
        case .cloze: "Cloze"
        }
    }
}

private extension CardSetupStarter {
    var editorDisplayName: String {
        switch self {
        case .basic: "Basic"
        case .reverse: "Reverse"
        case .typeAnswer: "Type Answer"
        case .visual: "Visual"
        case .cloze: "Cloze"
        case .audioSubmission: "Audio Submission"
        }
    }
}

private extension Interaction {
    var editorDisplayName: String {
        switch self {
        case .reveal: "Reveal"
        case .type: "Type Answer"
        case .choose: "Choose"
        case .record: "Record"
        case .audioSubmission: "Audio Submission"
        case .cloze: "Cloze"
        case .arrange: "Arrange"
        }
    }
}

private extension ComponentPurpose {
    var editorDisplayName: String {
        switch self {
        case .question: "Question"
        case .expectedAnswer: "Expected answer"
        case .supporting: "Supporting"
        }
    }
}

private extension RevealMode {
    var editorDisplayName: String {
        switch self {
        case .always: "Always visible"
        case .hiddenUntilAnswer: "After reveal"
        case .blurred: "Blur until reveal"
        }
    }
}

private extension MediaBehavior {
    var editorDisplayName: String {
        switch self {
        case .default: "Default"
        case .autoplay: "Autoplay"
        case .playOnTap: "Play on tap"
        case .loop: "Loop"
        }
    }
}

private extension Modality {
    var editorDisplayName: String {
        rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

private extension NeoAnkiCore.Operation {
    var editorDisplayName: String { rawValue.capitalized }
}
