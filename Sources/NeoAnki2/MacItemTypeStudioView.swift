import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI

private struct PendingFieldRemoval {
    let id: UUID
    let name: String
    let affectedSetupNames: [String]
}

/// Builds confirmation content through the same mutation that will be applied
/// after confirmation. This includes references held in reversible editing
/// state, such as an Audio Submission setup's stashed expected answers.
enum MacItemTypeStudioFieldRemovalPolicy {
    static func affectedSetupNames(
        removing fieldID: UUID,
        from draft: ItemTypeStudioDraft
    ) -> [String] {
        var preview = draft
        let changes = preview.removeField(id: fieldID)
        return draft.cardSetups.compactMap { setup in
            changes.affectedCardSetupIDs.contains(setup.id) ? setup.name : nil
        }
    }
}

/// macOS shell for the shared Item Type Studio authoring state and Card setup
/// editor. The shell owns document-level actions and confirmations only.
struct MacItemTypeStudioView: View {
    @Bindable var model: ItemTypesFeatureModel
    var onSaved: () async -> Void = {}

    @State private var selectedCardSetupID: UUID?
    @State private var validationFocus: ItemTypeStudioValidationTarget?
    @State private var pendingSave: ItemTypeStudioSavePreparation?
    @State private var pendingFieldRemoval: PendingFieldRemoval?
    @State private var showDiscardConfirmation = false
    @State private var errorMessage: String?
    @State private var repairMessage: String?
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool
    @FocusState private var focusedFieldID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            studioToolbar
            Divider()

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .accessibilityIdentifier("itemTypeStudioValidationSummary")
            }
            if let repairMessage {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(repairMessage)
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .accessibilityIdentifier("itemTypeStudioRepairRequired")
            }

            if model.studioDraft != nil {
                HSplitView {
                    studioOutline
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
                    editor
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.detailBackground)
        .onAppear { selectFirstCardSetupIfNeeded() }
        .onChange(of: model.studioDraft?.cardSetups.map(\.id)) { _, _ in
            selectFirstCardSetupIfNeeded()
        }
        .confirmationDialog(
            "Discard Item Type Studio changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { model.discardStudioDraft() }
                .accessibilityIdentifier("confirmDiscardItemTypeStudio")
            Button("Keep Editing", role: .cancel) {}
                .accessibilityIdentifier("cancelDiscardItemTypeStudio")
        } message: {
            Text("Unsaved field and Card setup changes will be lost together.")
        }
        .confirmationDialog(
            "Save Item Type changes?",
            isPresented: Binding(
                get: { pendingSave != nil },
                set: { if !$0 { pendingSave = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save Changes") {
                guard let preparation = pendingSave else { return }
                pendingSave = nil
                Task { await commit(preparation) }
            }
            .accessibilityIdentifier("confirmItemTypeStudioSaveImpact")
            Button("Review Changes", role: .cancel) { pendingSave = nil }
                .accessibilityIdentifier("cancelItemTypeStudioSaveImpact")
        } message: {
            if let impact = pendingSave?.impact { Text(saveImpactMessage(impact)) }
        }
        .confirmationDialog(
            "Remove \(pendingFieldRemoval?.name ?? "field")?",
            isPresented: Binding(
                get: { pendingFieldRemoval != nil },
                set: { if !$0 { pendingFieldRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Field", role: .destructive) { confirmFieldRemoval() }
                .accessibilityIdentifier("confirmRemoveStudioField")
            Button("Cancel", role: .cancel) { pendingFieldRemoval = nil }
                .accessibilityIdentifier("cancelRemoveStudioField")
        } message: {
            if let removal = pendingFieldRemoval {
                if removal.affectedSetupNames.isEmpty {
                    Text("The field is not currently used by a Card setup.")
                } else {
                    Text("Mappings will be cleared in \(removal.affectedSetupNames.joined(separator: ", ")). Repair those Card setups before saving.")
                }
            }
        }
    }

    private var draft: Binding<ItemTypeStudioDraft> {
        Binding(
            get: {
                guard let draft = model.studioDraft else {
                    preconditionFailure("Studio draft binding used after dismissal")
                }
                return draft
            },
            set: { model.studioDraft = $0 }
        )
    }

    private var studioToolbar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.studioDraft?.originalSnapshot == nil ? "New Item Type" : "Item Type Studio")
                    .font(DesignSystem.Typography.uiSection)
                Text("Edit fields and Card setups, then save them as one change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving") }
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .accessibilityIdentifier("cancelItemTypeStudio")
            Button("Save") { Task { await prepareSave() } }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .accessibilityHint("Validates and saves all fields and Card setups together")
                .accessibilityIdentifier("saveItemTypeStudio")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var studioOutline: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Item Type Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Item Type Name", text: draft.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                            .accessibilityIdentifier("itemTypeStudioName")
                    }

                    HStack {
                        Text("Fields").font(DesignSystem.Typography.uiTitle)
                        Spacer()
                        Button("Add Field", systemImage: "plus") { addField() }
                            .keyboardShortcut("f", modifiers: [.command, .shift])
                            .accessibilityIdentifier("addStudioField")
                    }

                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(draft.wrappedValue.fields) { field in
                            fieldEditor(field)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
            .frame(minHeight: 220, idealHeight: 300)

            Divider()

            List {
                CardSetupCollectionView(draft: draft, selection: $selectedCardSetupID)
            }
            .listStyle(.sidebar)
            .frame(minHeight: 260, maxHeight: .infinity)
        }
        .background(DesignSystem.sidebarBackground)
        .accessibilityIdentifier("itemTypeStudioOutline")
    }

    private func fieldEditor(_ field: ItemTypeFieldDraft) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                TextField("Field name", text: fieldNameBinding(field.id))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedFieldID, equals: field.id)
                    .accessibilityIdentifier("studioFieldName-\(field.id.uuidString)")
                Button("Remove", systemImage: "trash", role: .destructive) {
                    prepareFieldRemoval(field)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Remove \(field.name)")
                .accessibilityIdentifier("removeStudioField-\(field.id.uuidString)")
            }
            HStack {
                Picker("Type", selection: fieldTypeBinding(field.id)) {
                    ForEach(FieldType.allCases, id: \.self) { type in
                        Text(type.studioDisplayName).tag(type)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("\(field.name) field type")
                .accessibilityIdentifier("studioFieldType-\(field.id.uuidString)")
                Toggle("Required", isOn: fieldRequiredBinding(field.id))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("studioFieldRequired-\(field.id.uuidString)")
                Spacer()
                Button("Move Up", systemImage: "arrow.up") {
                    moveField(field.id, .up)
                }
                .labelStyle(.iconOnly)
                .disabled(!canMoveField(field.id, .up))
                .help("Move \(field.name) up")
                .accessibilityLabel("Move \(field.name) up")
                .accessibilityIdentifier("moveStudioFieldUp-\(field.id.uuidString)")
                Button("Move Down", systemImage: "arrow.down") {
                    moveField(field.id, .down)
                }
                .labelStyle(.iconOnly)
                .disabled(!canMoveField(field.id, .down))
                .help("Move \(field.name) down")
                .accessibilityLabel("Move \(field.name) down")
                .accessibilityIdentifier("moveStudioFieldDown-\(field.id.uuidString)")
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studioFieldRow-\(field.id.uuidString)")
    }

    @ViewBuilder
    private var editor: some View {
        if let selectedCardSetupID,
           draft.wrappedValue.cardSetups.contains(where: { $0.id == selectedCardSetupID }) {
            CardSetupEditorView(
                draft: draft,
                cardSetupID: selectedCardSetupID,
                validationFocus: $validationFocus
            )
            .accessibilityIdentifier("itemTypeStudioCardSetupEditor")
        } else {
            ContentUnavailableView {
                Label("Select a Card setup", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("Choose a Card setup to fill its static wireframe.")
            }
        }
    }

    private func fieldNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.studioDraft?.fields.first(where: { $0.id == id })?.name ?? "" },
            set: { value in
                guard var current = model.studioDraft,
                      let index = current.fields.firstIndex(where: { $0.id == id }) else { return }
                current.fields[index].name = value
                model.studioDraft = current
            }
        )
    }

    private func fieldTypeBinding(_ id: UUID) -> Binding<FieldType> {
        Binding(
            get: { model.studioDraft?.fields.first(where: { $0.id == id })?.type ?? .text },
            set: { value in
                guard var current = model.studioDraft else { return }
                _ = ItemTypeStudioDraftReducer.changeFieldType(
                    fieldID: id,
                    to: value,
                    in: &current
                )
                model.studioDraft = current
            }
        )
    }

    private func fieldRequiredBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.studioDraft?.fields.first(where: { $0.id == id })?.isRequired ?? false },
            set: { value in
                guard var current = model.studioDraft,
                      let index = current.fields.firstIndex(where: { $0.id == id }) else { return }
                current.fields[index].isRequired = value
                model.studioDraft = current
            }
        )
    }

    private func addField() {
        guard var current = model.studioDraft else { return }
        let field = ItemTypeFieldDraft(
            name: "Field \(current.fields.count + 1)",
            type: .text,
            isRequired: false
        )
        current.fields.append(field)
        model.studioDraft = current
        focusedFieldID = field.id
    }

    private func canMoveField(
        _ id: UUID,
        _ direction: ItemTypeStudioFieldMoveDirection
    ) -> Bool {
        guard let fields = model.studioDraft?.fields,
              let index = fields.firstIndex(where: { $0.id == id }) else { return false }
        switch direction {
        case .up: return index > fields.startIndex
        case .down: return index < fields.index(before: fields.endIndex)
        }
    }

    private func moveField(
        _ id: UUID,
        _ direction: ItemTypeStudioFieldMoveDirection
    ) {
        guard var current = model.studioDraft,
              current.moveField(id: id, direction) else { return }
        model.studioDraft = current
    }

    private func prepareFieldRemoval(_ field: ItemTypeFieldDraft) {
        guard let current = model.studioDraft else { return }
        pendingFieldRemoval = PendingFieldRemoval(
            id: field.id,
            name: field.name,
            affectedSetupNames: MacItemTypeStudioFieldRemovalPolicy.affectedSetupNames(
                removing: field.id,
                from: current
            )
        )
    }

    private func confirmFieldRemoval() {
        guard let removal = pendingFieldRemoval, var current = model.studioDraft else { return }
        let change = current.removeField(id: removal.id)
        model.studioDraft = current
        pendingFieldRemoval = nil
        if let affectedID = change.affectedCardSetupIDs.first {
            selectedCardSetupID = affectedID
            validationFocus = .cardSetup(affectedID)
        }
        repairMessage = removal.affectedSetupNames.isEmpty
            ? nil
            : "Field mappings were cleared. Repair the affected Card setups before saving."
    }

    private func selectFirstCardSetupIfNeeded() {
        guard let setups = model.studioDraft?.cardSetups else {
            selectedCardSetupID = nil
            return
        }
        if let selectedCardSetupID, setups.contains(where: { $0.id == selectedCardSetupID }) {
            return
        }
        selectedCardSetupID = setups.first?.id
    }

    private func cancel() {
        if hasUnsavedStudioChanges {
            showDiscardConfirmation = true
        } else {
            model.discardStudioDraft()
        }
    }

    /// A pristine creation draft is still unsaved work: dismissing it loses
    /// the new stable identity, fields, and prefilled Card setup together.
    private var hasUnsavedStudioChanges: Bool {
        guard let draft = model.studioDraft else { return false }
        return draft.originalSnapshot == nil || draft.isDirty
    }

    private func prepareSave() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let preparation = try await model.prepareSave()
            errorMessage = nil
            repairMessage = nil
            if preparation.impact.requiresConfirmation {
                pendingSave = preparation
            } else {
                await commit(preparation)
            }
        } catch ItemTypesFeatureError.invalidDraft(let issues) {
            focusFirstIssue(issues)
        } catch ItemTypesFeatureError.finalCardSetupRequired {
            errorMessage = ItemTypesFeatureError.finalCardSetupRequired.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func focusFirstIssue(_ issues: [ItemTypeStudioValidationIssue]) {
        guard let first = issues.first else { return }
        errorMessage = first.message
        switch first.target {
        case .itemTypeName:
            validationFocus = first.target
            isNameFocused = true
        case let .field(id):
            validationFocus = first.target
            focusedFieldID = id
        case let .cardSetup(id),
             let .component(cardSetupID: id, componentID: _),
             let .availability(cardSetupID: id),
             let .answerMethod(cardSetupID: id),
             let .layout(cardSetupID: id),
             let .recipe(cardSetupID: id, purpose: _):
            // The target can belong to a different Card setup. Clear it first,
            // mount that editor, then publish the focus request so its
            // on-change handler observes a real nil-to-target transition.
            validationFocus = nil
            selectedCardSetupID = id
            Task { @MainActor in
                await Task.yield()
                guard selectedCardSetupID == id else { return }
                validationFocus = first.target
            }
        }
    }

    private func commit(_ preparation: ItemTypeStudioSavePreparation) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await model.commitSave(preparation)
            errorMessage = nil
            await onSaved()
            // commitSave rebases edits made while persistence was awaiting the
            // repository. Close only the clean saved draft; retain any newer
            // or different draft so a reentrant edit is never erased.
            if let activeDraft = model.studioDraft,
               activeDraft.id == saved.id,
               activeDraft.isDirty == false {
                model.discardStudioDraft()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveImpactMessage(_ impact: ItemTypeStudioSaveImpact) -> String {
        var messages: [String] = []
        if !impact.removedFields.isEmpty {
            messages.append("Remove \(impact.removedFields.map(\.name).joined(separator: ", ")).")
        }
        if !impact.changedFields.isEmpty {
            messages.append("Change \(impact.changedFields.count) field definition\(impact.changedFields.count == 1 ? "" : "s").")
        }
        if impact.schemaChange.affectedItemCount > 0 {
            messages.append("Affect \(impact.schemaChange.affectedItemCount) populated item\(impact.schemaChange.affectedItemCount == 1 ? "" : "s").")
        }
        if !impact.removedCardSetups.isEmpty {
            messages.append("Remove Card setups \(impact.removedCardSetups.map(\.name).joined(separator: ", ")).")
        }
        if impact.generatedCardRetirementCount > 0 {
            let count = impact.generatedCardRetirementCount
            messages.append("Retire \(count) generated card\(count == 1 ? "" : "s").")
        }
        if impact.persistentSpokenResponseCount > 0 {
            let count = impact.persistentSpokenResponseCount
            messages.append("Permanently delete \(count) saved spoken response\(count == 1 ? "" : "s").")
        }
        return messages.isEmpty
            ? "Save the complete item type and its Card setups together?"
            : messages.joined(separator: " ")
    }
}
