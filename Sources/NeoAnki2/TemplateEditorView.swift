import NeoAnkiCore
import SwiftUI

struct TemplateEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: TemplatesModel
    var onDismiss: () -> Void = {}

    let itemType: ItemType
    let editingTemplate: Template?
    private let initialDraft: TemplateDraft

    @State private var draft: TemplateDraft
    @State private var isSaving = false
    @State private var showDiscardConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var affectedResponseCount = 0
    @State private var showClearAnswerConfirmation = false
    @State private var pendingInteraction: Interaction?
    @State private var showAdvanced: Bool

    init(
        model: TemplatesModel,
        itemType: ItemType,
        editingTemplate: Template? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onDismiss = onDismiss
        self.itemType = itemType
        self.editingTemplate = editingTemplate
        let draft = editingTemplate.map { TemplateDraft(template: $0, in: itemType) } ?? TemplateDraft()
        initialDraft = draft
        _draft = State(initialValue: draft)
        _showAdvanced = State(initialValue: draft.hasAdvancedSettings)
    }

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("templateNameField")

                Picker("Interaction", selection: interactionBinding) {
                    ForEach(Interaction.allCases, id: \.self) { interaction in
                        Text(interaction.label).tag(interaction)
                    }
                }
                .accessibilityIdentifier("templateInteractionPicker")

                if draft.interaction == .audioSubmission {
                    Label(
                        "Spoken responses are saved persistently on this device and are not included in cloud sync.",
                        systemImage: "lock.fill"
                    )
                    .font(DesignSystem.Typography.uiHint)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Privacy. Spoken responses are saved persistently on this device and are not included in cloud sync."
                    )
                }
            }

            Section("Prompt") {
                SlotListEditor(
                    slots: $draft.promptSlots,
                    fields: itemType.fields,
                    sideName: "Prompt",
                    clozeFieldsDefaultToHidden: draft.interaction == .cloze,
                    showAdvanced: showAdvanced
                )
            }

            if draft.interaction != .audioSubmission {
                Section("Answer") {
                    SlotListEditor(
                        slots: $draft.answerSlots,
                        fields: itemType.fields,
                        sideName: "Answer",
                        showAdvanced: showAdvanced
                    )
                }
            }

            Section {
                Button {
                    showAdvanced.toggle()
                } label: {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                            .animation(
                                reduceMotion || AppDatabase.isTesting
                                    ? nil
                                    : .easeOut(duration: 0.2),
                                value: showAdvanced
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                            Text("Advanced")
                            Text("Skill mapping, reveal behavior, media playback, and generation rules")
                                .font(DesignSystem.Typography.uiHint)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advanced settings")
                .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("templateAdvancedSettings")

                if showAdvanced {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Practice skill")
                            .font(DesignSystem.Typography.uiSecondary.weight(.semibold))
                        if draft.interaction != .audioSubmission {
                            Toggle("Derive from the first prompt and answer fields", isOn: $draft.usesAutomaticSkill)
                                .accessibilityIdentifier("templateAutomaticSkill")
                        }
                        if !draft.usesAutomaticSkill || draft.interaction == .audioSubmission {
                            Picker("Input", selection: $draft.skill.input) {
                                ForEach(Modality.allCases, id: \.self) { modality in
                                    Text(modality.label).tag(modality)
                                }
                            }
                            .accessibilityIdentifier("templateSkillInput")
                            if draft.interaction == .audioSubmission {
                                LabeledContent("Output", value: "Audio")
                                    .accessibilityIdentifier("templateSkillOutput")
                            } else {
                                Picker("Output", selection: $draft.skill.output) {
                                    ForEach(Modality.allCases, id: \.self) { modality in
                                        Text(modality.label).tag(modality)
                                    }
                                }
                                .accessibilityIdentifier("templateSkillOutput")
                            }
                            Picker("Operation", selection: $draft.skill.operation) {
                                ForEach(NeoAnkiCore.Operation.allCases, id: \.self) { operation in
                                    Text(operation.label).tag(operation)
                                }
                            }
                            .accessibilityIdentifier("templateSkillOperation")
                        }

                        Divider()

                        Text("Card generation")
                            .font(DesignSystem.Typography.uiSecondary.weight(.semibold))
                        Toggle(
                            "Only generate this card when…",
                            isOn: Binding(
                                get: { draft.generateWhen != nil },
                                set: { enabled in
                                    draft.generateWhen = enabled
                                        ? .fieldNotEmpty(itemType.fields.first?.id)
                                        : nil
                                }
                            )
                        )
                        .accessibilityIdentifier("templateGenerateCondition")
                        if draft.generateWhen != nil {
                            ConditionEditor(condition: generateWhenBinding, fields: itemType.fields)
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                }
            }
        }
        .accessibilityIdentifier("templateEditorForm")
        .formStyle(.grouped)
        .neoAnkiFormTypography()
        .navigationTitle(editingTemplate == nil ? "Add Template" : "Edit Template")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { requestDismissal() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelTemplateEditor")
            }
            if editingTemplate != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) {
                        prepareTemplateDeletion()
                    }
                    .accessibilityIdentifier("deleteTemplate")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !draft.isValid)
                .accessibilityIdentifier("saveTemplate")
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .confirmationDialog(
            "Discard template changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { onDismiss() }
                .accessibilityIdentifier("confirmDiscardTemplate")
            Button("Keep Editing", role: .cancel) {}
                .accessibilityIdentifier("cancelDiscardTemplate")
        } message: {
            Text("Your unsaved template changes will be lost.")
        }
        .confirmationDialog(
            "Delete this template?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Template", role: .destructive) {
                Task { await deleteTemplate() }
            }
            .accessibilityIdentifier("confirmDeleteTemplate")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelDeleteTemplate")
        } message: {
            if affectedResponseCount > 0 {
                Text("Cards generated by this template and \(affectedResponseCount) saved spoken \(affectedResponseCount == 1 ? "response" : "responses") will be permanently deleted.")
            } else {
                Text("Cards generated by this template may be removed. This action cannot be undone.")
            }
        }
        .confirmationDialog(
            "Clear the answer side?",
            isPresented: $showClearAnswerConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Answer and Continue", role: .destructive) {
                commitPendingAudioSubmission()
            }
            Button("Cancel", role: .cancel) { pendingInteraction = nil }
        } message: {
            Text("Audio Submission cards are prompt-only. Changing this template will permanently clear its answer side when you save.")
        }
    }

    private var interactionBinding: Binding<Interaction> {
        Binding(
            get: { draft.interaction },
            set: { requested in
                guard requested != draft.interaction else { return }
                if requested == .audioSubmission, !draft.answerSlots.isEmpty {
                    pendingInteraction = requested
                    showClearAnswerConfirmation = true
                } else {
                    setInteraction(requested)
                }
            }
        )
    }

    private var generateWhenBinding: Binding<ConditionDraft> {
        Binding(
            get: { draft.generateWhen ?? .fieldNotEmpty(itemType.fields.first?.id) },
            set: { draft.generateWhen = $0 }
        )
    }

    private func applyInteractionDefaults(_ interaction: Interaction) {
        if interaction == .audioSubmission {
            draft.answerSlots = []
            draft.usesAutomaticSkill = false
            draft.skill.output = .audio
            return
        }
        if draft.answerSlots.isEmpty {
            draft.answerSlots = [SlotDraft(fieldID: itemType.fields.dropFirst().first?.id)]
        }
        guard interaction == .cloze else { return }
        for index in draft.promptSlots.indices
            where draft.promptSlots[index].reveal == .always
                && draft.promptSlots[index].fieldID.flatMap(itemType.field)?.type == .cloze {
            draft.promptSlots[index].reveal = .hiddenUntilAnswer
        }
    }

    private func setInteraction(_ interaction: Interaction) {
        draft.interaction = interaction
        applyInteractionDefaults(interaction)
    }

    private func commitPendingAudioSubmission() {
        guard pendingInteraction == .audioSubmission else { return }
        pendingInteraction = nil
        setInteraction(.audioSubmission)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if await model.saveTemplate(draft, editingID: editingTemplate?.id) {
            onDismiss()
        }
    }

    private func deleteTemplate() async {
        guard let editingTemplate else { return }
        if await model.deleteTemplate(id: editingTemplate.id) {
            onDismiss()
        }
    }

    private func prepareTemplateDeletion() {
        guard let editingTemplate,
              EditorDecisionState.requiresTemplateDeletionConfirmation(templateExists: true)
        else { return }
        Task {
            affectedResponseCount = (try? await model.studyResponseCount(
                templateID: editingTemplate.id
            )) ?? 0
            showDeleteConfirmation = true
        }
    }

    private func requestDismissal() {
        switch EditorDecisionState.dismissalDecision(initial: initialDraft, current: draft) {
        case .dismiss:
            onDismiss()
        case .confirmDiscard:
            showDiscardConfirmation = true
        }
    }
}

private struct SlotListEditor: View {
    @Binding var slots: [SlotDraft]
    let fields: [FieldDef]
    let sideName: String
    var clozeFieldsDefaultToHidden = false
    let showAdvanced: Bool

    var body: some View {
        ForEach($slots) { $slot in
            let mediaKind = slot.fieldID
                .flatMap { id in fields.first { $0.id == id } }?
                .type.mediaKind
            let mediaBehaviors = slot.sourceKind == .field
                ? MediaBehavior.supported(for: mediaKind)
                : [.default]
            let position = (slots.firstIndex { $0.id == slot.id } ?? 0) + 1
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                if showAdvanced || slots.count > 1 {
                    HStack {
                        if showAdvanced {
                            Picker("Source", selection: $slot.sourceKind) {
                                Text("Field").tag(SlotDraft.SourceKind.field)
                                Text("Literal text").tag(SlotDraft.SourceKind.literal)
                            }
                            .accessibilityIdentifier("\(sideName.lowercased())SlotSource")
                            .onChange(of: slot.sourceKind) { _, _ in
                                slot.media = .default
                            }
                        }
                        Spacer()
                        if slots.count > 1 {
                            Button("Move Up", systemImage: "arrow.up") {
                                move(slot.id, by: -1)
                            }
                            .accessibilityIdentifier("\(sideName.lowercased())SlotMoveUp")
                            .accessibilityLabel("Move \(sideName.lowercased()) slot \(position) up")
                            .labelStyle(.iconOnly)
                            .disabled(slots.first?.id == slot.id)
                            .help("Move slot up")
                            Button("Move Down", systemImage: "arrow.down") {
                                move(slot.id, by: 1)
                            }
                            .accessibilityIdentifier("\(sideName.lowercased())SlotMoveDown")
                            .accessibilityLabel("Move \(sideName.lowercased()) slot \(position) down")
                            .labelStyle(.iconOnly)
                            .disabled(slots.last?.id == slot.id)
                            .help("Move slot down")
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                slots.removeAll { $0.id == slot.id }
                            }
                            .accessibilityIdentifier("\(sideName.lowercased())SlotRemove")
                            .accessibilityLabel("Remove \(sideName.lowercased()) slot \(position)")
                            .labelStyle(.iconOnly)
                            .help("Remove slot")
                        }
                    }
                }

                if slot.sourceKind == .field {
                    Picker("Field", selection: $slot.fieldID) {
                        Text("Choose field").tag(UUID?.none)
                        ForEach(fields) { field in
                            Text(field.name).tag(Optional(field.id))
                        }
                    }
                    .accessibilityIdentifier(
                        sideName == "Prompt" ? "templatePromptField" : "templateAnswerField"
                    )
                    .onChange(of: slot.fieldID) { _, fieldID in
                        let field = fieldID.flatMap { id in fields.first { $0.id == id } }
                        if !slot.media.isSupported(for: field?.type.mediaKind) {
                            slot.media = .default
                        }
                        if clozeFieldsDefaultToHidden,
                           field?.type == .cloze,
                           slot.reveal == .always {
                            slot.reveal = .hiddenUntilAnswer
                        }
                    }
                } else {
                    TextField("Literal text", text: $slot.literal)
                        .accessibilityIdentifier("\(sideName.lowercased())SlotLiteral")
                }

                if showAdvanced {
                    HStack {
                        Picker("Reveal", selection: $slot.reveal) {
                            ForEach(RevealMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("\(sideName.lowercased())SlotReveal")
                        if mediaBehaviors.count > 1 {
                            Picker("Media", selection: $slot.media) {
                                ForEach(mediaBehaviors, id: \.self) { behavior in
                                    Text(behavior.label).tag(behavior)
                                }
                            }
                            .accessibilityIdentifier("\(sideName.lowercased())SlotMedia")
                        }
                    }
                }
            }
            .padding(.vertical, DesignSystem.Spacing.xs)
        }

        Button("Add \(sideName) Slot", systemImage: "plus") {
            slots.append(SlotDraft())
        }
        .accessibilityIdentifier("\(sideName.lowercased())SlotAdd")
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let source = slots.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard slots.indices.contains(destination) else { return }
        slots.swapAt(source, destination)
    }
}

private struct ConditionEditor: View {
    private enum Kind: String, CaseIterable {
        case fieldNotEmpty
        case fieldEmpty
        case all
        case any
    }

    @Binding var condition: ConditionDraft
    let fields: [FieldDef]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Picker("Rule", selection: kindBinding) {
                Text("Field is not empty").tag(Kind.fieldNotEmpty)
                Text("Field is empty").tag(Kind.fieldEmpty)
                Text("All rules match").tag(Kind.all)
                Text("Any rule matches").tag(Kind.any)
            }

            switch condition {
            case .fieldNotEmpty, .fieldEmpty:
                Picker("Field", selection: fieldBinding) {
                    Text("Choose field").tag(UUID?.none)
                    ForEach(fields) { field in
                        Text(field.name).tag(Optional(field.id))
                    }
                }
            case let .all(children), let .any(children):
                ForEach(children.indices, id: \.self) { index in
                    HStack(alignment: .top) {
                        ConditionEditor(condition: childBinding(index), fields: fields)
                        Button("Remove Rule", systemImage: "minus.circle", role: .destructive) {
                            removeChild(at: index)
                        }
                        .labelStyle(.iconOnly)
                        .help("Remove rule")
                    }
                    .padding(.leading, DesignSystem.Spacing.md)
                }
                Button("Add Rule", systemImage: "plus") {
                    addChild()
                }
            }
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(
            get: {
                switch condition {
                case .fieldNotEmpty: .fieldNotEmpty
                case .fieldEmpty: .fieldEmpty
                case .all: .all
                case .any: .any
                }
            },
            set: { kind in
                let firstID = fields.first?.id
                switch kind {
                case .fieldNotEmpty: condition = .fieldNotEmpty(firstID)
                case .fieldEmpty: condition = .fieldEmpty(firstID)
                case .all: condition = .all([.fieldNotEmpty(firstID)])
                case .any: condition = .any([.fieldNotEmpty(firstID)])
                }
            }
        )
    }

    private var fieldBinding: Binding<UUID?> {
        Binding(
            get: {
                switch condition {
                case let .fieldNotEmpty(id), let .fieldEmpty(id): id
                case .all, .any: nil
                }
            },
            set: { id in
                switch condition {
                case .fieldNotEmpty: condition = .fieldNotEmpty(id)
                case .fieldEmpty: condition = .fieldEmpty(id)
                case .all, .any: break
                }
            }
        )
    }

    private func childBinding(_ index: Int) -> Binding<ConditionDraft> {
        Binding(
            get: {
                switch condition {
                case let .all(children), let .any(children): children[index]
                default: .fieldNotEmpty(fields.first?.id)
                }
            },
            set: { child in
                switch condition {
                case .all(var children):
                    children[index] = child
                    condition = .all(children)
                case .any(var children):
                    children[index] = child
                    condition = .any(children)
                default:
                    break
                }
            }
        )
    }

    private func addChild() {
        let child = ConditionDraft.fieldNotEmpty(fields.first?.id)
        switch condition {
        case .all(var children):
            children.append(child)
            condition = .all(children)
        case .any(var children):
            children.append(child)
            condition = .any(children)
        default:
            break
        }
    }

    private func removeChild(at index: Int) {
        switch condition {
        case .all(var children):
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
            condition = .all(children)
        case .any(var children):
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
            condition = .any(children)
        default:
            break
        }
    }
}

private extension Interaction {
    var label: String {
        switch self {
        case .reveal: "Reveal"
        case .type: "Type answer"
        case .choose: "Choose"
        case .record: "Record"
        case .audioSubmission: "Audio Submission"
        case .cloze: "Cloze"
        case .arrange: "Arrange"
        }
    }
}

private extension Modality {
    var label: String {
        switch self {
        case .text: "Text"
        case .audio: "Audio"
        case .image: "Image"
        case .video: "Video"
        case .diagram: "Diagram"
        case .none: "None"
        case .freeResponse: "Free response"
        case .selection: "Selection"
        case .spatial: "Spatial"
        case .sequence: "Sequence"
        }
    }
}

private extension NeoAnkiCore.Operation {
    var label: String { rawValue.capitalized }
}

private extension RevealMode {
    var label: String {
        switch self {
        case .always: "Always visible"
        case .hiddenUntilAnswer: "Hidden until answer"
        case .blurred: "Blurred until answer"
        }
    }
}

private extension MediaBehavior {
    var label: String {
        switch self {
        case .default: "Default"
        case .autoplay: "Autoplay"
        case .playOnTap: "Play on tap"
        case .loop: "Loop"
        }
    }
}
