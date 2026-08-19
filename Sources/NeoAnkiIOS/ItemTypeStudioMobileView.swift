#if os(iOS)
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI

struct ItemTypeStudioCatalogMobileView: View {
    @Bindable var model: ItemTypesFeatureModel
    let reloadLibrary: () async throws -> Void
    let prepareCatalog: () async -> Void

    @State private var presentsStudio = false
    @State private var errorMessage: String?

    init(
        model: ItemTypesFeatureModel,
        reloadLibrary: @escaping () async throws -> Void,
        prepareCatalog: @escaping () async -> Void = {}
    ) {
        self.model = model
        self.reloadLibrary = reloadLibrary
        self.prepareCatalog = prepareCatalog
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Loading item types…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(error):
                ContentUnavailableView {
                    Label("Item Types Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                        .neoAnkiTouchTarget()
                }
            case .ready:
                catalog
            }
        }
        .navigationTitle("Item Types")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Item Type", systemImage: "plus") {
                    // A deck-provided selection belongs to the catalog, not to
                    // the new draft. Clear it before authoring so read-only
                    // actions can never target or replace the new identity.
                    model.selectItemType(id: nil)
                    model.beginCreatingItemType()
                    presentsStudio = true
                }
                .neoAnkiTouchTarget()
                .accessibilityIdentifier("item-types.new")
            }
        }
        .navigationDestination(isPresented: $presentsStudio) {
            ItemTypeStudioMobileView(model: model, reloadLibrary: reloadLibrary)
        }
        .onChange(of: presentsStudio) { _, presented in
            if !presented {
                model.discardStudioDraft()
            }
        }
        .task {
            if case .loading = model.loadState {
                await prepareCatalog()
                await model.load()
            }
        }
        .alert("Could Not Update Item Types", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var catalog: some View {
        List {
            if !model.itemTypes.isEmpty {
                Section("My Item Types") {
                    ForEach(model.itemTypes) { itemType in
                        itemTypeButton(itemType, owner: nil)
                    }
                }
            }

            ForEach(model.includedItemTypeGroups) { group in
                Section {
                    ForEach(group.itemTypes) { itemType in
                        itemTypeButton(itemType, owner: group)
                    }
                } header: {
                    Text(group.deckPath)
                } footer: {
                    Text("Deck-provided item types are read-only until you unlock or duplicate them.")
                }
            }

            if !model.corruptedDefinitions.isEmpty {
                Section("Needs Repair") {
                    ForEach(model.corruptedDefinitions) { corruption in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(corruption.name, systemImage: "wrench.and.screwdriver")
                                .font(.headline)
                            Text("NeoAnki could not read this stored definition. Repair restores a safe editable version while preserving its identity when possible.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Repair Definition") {
                                Task { await repair(corruption) }
                            }
                            .buttonStyle(.bordered)
                            .neoAnkiTouchTarget()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if model.itemTypes.isEmpty && model.includedItemTypeGroups.isEmpty
                && model.corruptedDefinitions.isEmpty {
                ContentUnavailableView(
                    "No Item Types",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Create an item type to define fields and Card setups together.")
                )
            }
        }
        .refreshable { await model.load() }
    }

    private func itemTypeButton(
        _ itemType: ItemType,
        owner: IncludedItemTypeGroup?
    ) -> some View {
        Button {
            model.selectItemType(id: itemType.id)
            guard model.beginEditingSelectedItemType() else { return }
            presentsStudio = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(itemType.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(itemType.fields.count) fields · \(itemType.templates.count) Card setups")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if owner != nil {
                        Label("Read-only", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .neoAnkiTouchTarget()
        .accessibilityLabel(owner == nil
            ? itemType.name
            : "\(itemType.name), read-only")
        .accessibilityHint("Opens fields and Card setups")
        .accessibilityIdentifier("item-types.row.\(itemType.id.uuidString)")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func repair(_ corruption: QuarantinedItemTypeDefinition) async {
        do {
            _ = try await model.repairDefinition(corruption)
            try await reloadLibrary()
        } catch {
            errorMessage = MobileAppModel.message(for: error)
        }
    }
}

private struct ItemTypeStudioSetupRoute: Identifiable, Hashable {
    let id = UUID()
    let cardSetupID: UUID
}

private struct PendingFieldRemoval: Identifiable {
    let id: UUID
    let name: String
    let affectedCardSetupNames: [String]
}

private enum ItemTypeStudioTextFocus: Hashable {
    case name
    case field(UUID)
}

struct ItemTypeStudioMobileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.neoAnkiAccessibilityReduceMotionOverride) private var reduceMotionOverride
    @Bindable var model: ItemTypesFeatureModel
    let reloadLibrary: () async throws -> Void

    @FocusState private var textFocus: ItemTypeStudioTextFocus?
    @State private var validationFocus: ItemTypeStudioValidationTarget?
    @State private var setupRoute: ItemTypeStudioSetupRoute?
    @State private var selectedCardSetupID: UUID?
    @State private var pendingFieldRemoval: PendingFieldRemoval?
    @State private var pendingSave: ItemTypeStudioSavePreparation?
    @State private var unlockImpact: ItemTypeEditingImpact?
    @State private var pendingUnlockItemTypeID: UUID?
    @State private var confirmsDuplicate = false
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false
    @State private var isWorking = false
    @State private var errorTitle = "Could Not Save Item Type"
    @State private var errorMessage: String?
    @State private var pendingValidationRecovery: ItemTypeStudioValidationTarget?

    var body: some View {
        Group {
            if model.studioDraft != nil {
                studio
            } else {
                ContentUnavailableView(
                    "Item Type Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Return to Item Types and choose the definition again.")
                )
            }
        }
        .navigationTitle(studioTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar { studioToolbar }
        .interactiveDismissDisabled(hasUnsavedStudioChanges)
        .navigationDestination(item: $setupRoute) { route in
            if let draftBinding,
               draftBinding.wrappedValue.cardSetups.contains(where: { $0.id == route.cardSetupID }) {
                CardSetupEditorView(
                    draft: draftBinding,
                    cardSetupID: route.cardSetupID,
                    validationFocus: $validationFocus
                )
                .onDisappear {
                    if selectedCardSetupID == route.cardSetupID {
                        selectedCardSetupID = nil
                    }
                }
            } else {
                ContentUnavailableView("Card Setup Unavailable", systemImage: "rectangle.slash")
            }
        }
        .confirmationDialog(
            "Remove this field?",
            isPresented: Binding(
                get: { pendingFieldRemoval != nil },
                set: { if !$0 { pendingFieldRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Field", role: .destructive) { confirmFieldRemoval() }
            Button("Keep Field", role: .cancel) { pendingFieldRemoval = nil }
        } message: {
            if let pendingFieldRemoval {
                Text(fieldRemovalMessage(pendingFieldRemoval))
            }
        }
        .confirmationDialog(
            "Save these changes?",
            isPresented: Binding(
                get: { pendingSave != nil },
                set: { if !$0 { pendingSave = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save Changes", role: saveIsDestructive ? .destructive : nil) {
                guard let preparation = pendingSave else { return }
                pendingSave = nil
                Task { await commit(preparation) }
            }
            Button("Keep Editing", role: .cancel) { pendingSave = nil }
        } message: {
            if let pendingSave { Text(saveImpactMessage(pendingSave.impact)) }
        }
        .confirmationDialog(
            "Unlock this item type?",
            isPresented: Binding(
                get: { unlockImpact != nil },
                set: {
                    if !$0 {
                        unlockImpact = nil
                        pendingUnlockItemTypeID = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Unlock for Editing") { Task { await unlock() } }
            Button("Cancel", role: .cancel) {
                unlockImpact = nil
                pendingUnlockItemTypeID = nil
            }
        } message: {
            if let unlockImpact { Text(unlockImpactMessage(unlockImpact)) }
        }
        .confirmationDialog(
            "Duplicate this item type?",
            isPresented: $confirmsDuplicate,
            titleVisibility: .visible
        ) {
            Button("Duplicate") { Task { await duplicate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates an editable copy with independent Card setups.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmsDiscard) {
            Button("Discard", role: .destructive) { closeStudio() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Delete this item type?", isPresented: $confirmsDelete) {
            Button("Delete Item Type", role: .destructive) { Task { await deleteItemType() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Item types with existing items cannot be deleted.")
        }
        .alert(errorTitle, isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .onChange(of: errorMessage) { _, message in
            guard message == nil, let target = pendingValidationRecovery else { return }
            pendingValidationRecovery = nil
            recoverFocus(target)
        }
    }

    private var studio: some View {
        ScrollViewReader { proxy in
            Form {
                if isDraftReadOnly {
                    readOnlySection
                }
                identitySection
                    .disabled(isDraftReadOnly || isWorking)
                fieldsSection
                    .disabled(isDraftReadOnly || isWorking)
                if let draftBinding {
                    CardSetupCollectionView(
                        draft: draftBinding,
                        selection: Binding(
                            get: { selectedCardSetupID },
                            set: { cardSetupID in
                                selectedCardSetupID = cardSetupID
                                setupRoute = cardSetupID.map(
                                    ItemTypeStudioSetupRoute.init(cardSetupID:)
                                )
                            }
                        )
                    )
                    .disabled(isDraftReadOnly || isWorking)
                }
                if !isDraftReadOnly,
                   draftBinding?.wrappedValue.originalSnapshot != nil {
                    Section {
                        Button("Delete Item Type", role: .destructive) {
                            Task { await prepareDelete() }
                        }
                        .neoAnkiTouchTarget()
                        .disabled(isWorking)
                        .accessibilityIdentifier("item-type-studio.delete")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: validationFocus) { _, target in
                guard let target else { return }
                withOptionalMotion { proxy.scrollTo(target, anchor: .center) }
                focus(target)
            }
        }
    }

    private var readOnlySection: some View {
        Section {
            Label("Deck-provided · Read-only", systemImage: "lock")
                .foregroundStyle(.secondary)
            Button("Unlock for Editing…", systemImage: "lock.open") {
                Task { await prepareUnlock() }
            }
            .neoAnkiTouchTarget()
            .disabled(isWorking)
            Button("Duplicate as Item Type…", systemImage: "plus.square.on.square") {
                confirmsDuplicate = true
            }
            .neoAnkiTouchTarget()
            .disabled(isWorking)
        } footer: {
            Text("Unlock changes this shared definition. Duplicate makes an independent editable copy.")
        }
    }

    private var identitySection: some View {
        Section("Item Type") {
            if let draftBinding {
                TextField("Name", text: draftBinding.name)
                    .focused($textFocus, equals: .name)
                    .id(ItemTypeStudioValidationTarget.itemTypeName)
                    .accessibilityIdentifier("item-type-studio.name")
            }
        }
    }

    private var fieldsSection: some View {
        Section {
            if let draftBinding {
                ForEach(draftBinding.wrappedValue.fields) { field in
                    fieldRow(field, draft: draftBinding)
                        .id(ItemTypeStudioValidationTarget.field(field.id))
                }
                Button("Add Field", systemImage: "plus") {
                    var draft = draftBinding.wrappedValue
                    draft.fields.append(ItemTypeFieldDraft(name: "New Field"))
                    draftBinding.wrappedValue = draft
                }
                .neoAnkiTouchTarget()
                .accessibilityIdentifier("item-type-studio.add-field")
            }
        } header: {
            Text("Fields")
        } footer: {
            Text("Removing a used field clears its Card setup mappings and requires repair before Save.")
        }
    }

    private func fieldRow(
        _ field: ItemTypeFieldDraft,
        draft: Binding<ItemTypeStudioDraft>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Field name", text: fieldNameBinding(field.id, draft: draft))
                    .focused($textFocus, equals: .field(field.id))
                    .accessibilityIdentifier("item-type-studio.field.\(field.id.uuidString).name")
                Spacer(minLength: 4)
                Button("Remove \(field.name)", systemImage: "trash", role: .destructive) {
                    prepareFieldRemoval(field.id)
                }
                .labelStyle(.iconOnly)
                .neoAnkiTouchTarget()
                .accessibilityHint("Shows affected Card setups before removing the field")
                .accessibilityIdentifier("item-type-studio.field.\(field.id.uuidString).remove")
            }
            Picker("Type", selection: fieldTypeBinding(field.id, draft: draft)) {
                ForEach(FieldType.allCases, id: \.self) { type in
                    Text(fieldTypeName(type)).tag(type)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("item-type-studio.field.\(field.id.uuidString).type")
            Toggle("Required", isOn: fieldRequiredBinding(field.id, draft: draft))
                .neoAnkiTouchTarget()
            HStack(spacing: 8) {
                Button("Move Up", systemImage: "arrow.up") {
                    moveField(field.id, .up, draft: draft)
                }
                .frame(maxWidth: .infinity)
                .neoAnkiTouchTarget()
                .disabled(!canMoveField(field.id, .up, draft: draft.wrappedValue))
                .accessibilityLabel("Move \(field.name) up")
                .accessibilityIdentifier("item-type-studio.field.\(field.id.uuidString).move-up")

                Button("Move Down", systemImage: "arrow.down") {
                    moveField(field.id, .down, draft: draft)
                }
                .frame(maxWidth: .infinity)
                .neoAnkiTouchTarget()
                .disabled(!canMoveField(field.id, .down, draft: draft.wrappedValue))
                .accessibilityLabel("Move \(field.name) down")
                .accessibilityIdentifier("item-type-studio.field.\(field.id.uuidString).move-down")
            }
        }
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var studioToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { requestCancel() }
                .disabled(isWorking)
                .neoAnkiTouchTarget()
                .accessibilityIdentifier("item-type-studio.cancel")
        }
        if !isDraftReadOnly {
            ToolbarItem(placement: .confirmationAction) {
                Button(isWorking ? "Saving…" : "Save") {
                    Task { await prepareSave() }
                }
                .disabled(isWorking)
                .neoAnkiTouchTarget()
                .accessibilityIdentifier("item-type-studio.save")
            }
        }
    }

    private var studioTitle: String {
        let name = draftBinding?.wrappedValue.name
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "New Item Type" : name
    }

    private var draftBinding: Binding<ItemTypeStudioDraft>? {
        guard let fallback = model.studioDraft else { return nil }
        return Binding(
            get: { model.studioDraft ?? fallback },
            set: { draft in
                if model.studioDraft != nil {
                    model.studioDraft = draft
                }
            }
        )
    }

    /// Catalog selection can legitimately lag behind creation navigation. A
    /// draft is read-only only when it is the selected included definition's
    /// exact persisted identity; a new draft is always editable.
    private var isDraftReadOnly: Bool {
        guard let draft = model.studioDraft,
              draft.originalSnapshot != nil,
              model.selectedItemTypeID == draft.id
        else { return false }
        return model.isSelectedItemTypeReadOnly
    }

    /// A pristine creation draft is still unsaved work because dismissing it
    /// loses its new stable identity, fields, and prefilled Card setup.
    private var hasUnsavedStudioChanges: Bool {
        guard let draft = model.studioDraft else { return false }
        return draft.originalSnapshot == nil || draft.isDirty
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var saveIsDestructive: Bool {
        pendingSave?.impact.isDestructive == true
    }

    private func fieldNameBinding(
        _ id: UUID,
        draft: Binding<ItemTypeStudioDraft>
    ) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue.fields.first(where: { $0.id == id })?.name ?? "" },
            set: { value in
                var valueDraft = draft.wrappedValue
                guard let index = valueDraft.fields.firstIndex(where: { $0.id == id }) else { return }
                valueDraft.fields[index].name = value
                draft.wrappedValue = valueDraft
            }
        )
    }

    private func fieldTypeBinding(
        _ id: UUID,
        draft: Binding<ItemTypeStudioDraft>
    ) -> Binding<FieldType> {
        Binding(
            get: { draft.wrappedValue.fields.first(where: { $0.id == id })?.type ?? .text },
            set: { value in
                var valueDraft = draft.wrappedValue
                _ = ItemTypeStudioDraftReducer.changeFieldType(
                    fieldID: id,
                    to: value,
                    in: &valueDraft
                )
                draft.wrappedValue = valueDraft
            }
        )
    }

    private func fieldRequiredBinding(
        _ id: UUID,
        draft: Binding<ItemTypeStudioDraft>
    ) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.fields.first(where: { $0.id == id })?.isRequired ?? false },
            set: { value in
                var valueDraft = draft.wrappedValue
                guard let index = valueDraft.fields.firstIndex(where: { $0.id == id }) else { return }
                valueDraft.fields[index].isRequired = value
                draft.wrappedValue = valueDraft
            }
        )
    }

    private func canMoveField(
        _ id: UUID,
        _ direction: ItemTypeStudioFieldMoveDirection,
        draft: ItemTypeStudioDraft
    ) -> Bool {
        guard let index = draft.fields.firstIndex(where: { $0.id == id }) else { return false }
        switch direction {
        case .up: return index > draft.fields.startIndex
        case .down: return index < draft.fields.index(before: draft.fields.endIndex)
        }
    }

    private func moveField(
        _ id: UUID,
        _ direction: ItemTypeStudioFieldMoveDirection,
        draft: Binding<ItemTypeStudioDraft>
    ) {
        var value = draft.wrappedValue
        guard value.moveField(id: id, direction) else { return }
        draft.wrappedValue = value
    }

    private func prepareFieldRemoval(_ id: UUID) {
        guard let draft = model.studioDraft,
              let field = draft.fields.first(where: { $0.id == id }) else { return }
        var preview = draft
        let changes = preview.removeField(id: id)
        let names = draft.cardSetups.compactMap { setup in
            changes.affectedCardSetupIDs.contains(setup.id) ? setup.name : nil
        }
        pendingFieldRemoval = PendingFieldRemoval(
            id: id,
            name: field.name,
            affectedCardSetupNames: names
        )
    }

    private func confirmFieldRemoval() {
        guard let pendingFieldRemoval, var draft = model.studioDraft else { return }
        _ = draft.removeField(id: pendingFieldRemoval.id)
        model.studioDraft = draft
        self.pendingFieldRemoval = nil
        validationFocus = draft.validationIssues.first?.target
    }

    private func fieldRemovalMessage(_ removal: PendingFieldRemoval) -> String {
        guard !removal.affectedCardSetupNames.isEmpty else {
            return "\(removal.name) is not used by a Card setup."
        }
        return "This clears mappings in \(removal.affectedCardSetupNames.joined(separator: ", ")). Repair those Card setups before Save."
    }

    private func prepareSave() async {
        guard let draft = model.studioDraft else { return }
        if let issue = draft.validationIssues.first {
            recover(from: issue)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let preparation = try await model.prepareSave()
            if preparation.impact.requiresConfirmation {
                pendingSave = preparation
            } else {
                await commit(preparation)
            }
        } catch let ItemTypesFeatureError.invalidDraft(issues) {
            if let issue = issues.first { recover(from: issue) }
        } catch {
            present(error, title: "Could Not Prepare Save")
        }
    }

    private func commit(_ preparation: ItemTypeStudioSavePreparation) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let saved = try await model.commitSave(preparation)
            try await reloadLibrary()
            // Persistence can suspend while the user continues editing. The
            // feature model rebases those newer edits onto the saved snapshot;
            // close only the exact clean draft that was just saved.
            guard let activeDraft = model.studioDraft,
                  activeDraft.id == saved.id,
                  activeDraft.originalSnapshot == saved,
                  activeDraft.isDirty == false
            else { return }
            dismiss()
        } catch {
            present(error)
        }
    }

    private func recover(from issue: ItemTypeStudioValidationIssue) {
        pendingValidationRecovery = issue.target
        errorTitle = "Finish This Item Type"
        errorMessage = issue.message
    }

    private func recoverFocus(_ target: ItemTypeStudioValidationTarget) {
        switch target {
        case .itemTypeName:
            validationFocus = target
            textFocus = .name
        case let .field(id):
            validationFocus = target
            textFocus = .field(id)
        case let .cardSetup(id),
             let .component(cardSetupID: id, componentID: _),
             let .availability(cardSetupID: id),
             let .answerMethod(cardSetupID: id),
             let .layout(cardSetupID: id),
             let .recipe(cardSetupID: id, purpose: _):
            routeToSetup(id, focusing: target)
        }
    }

    /// Navigation and focus are two distinct state transitions. Publishing the
    /// validation target after the destination mounts ensures the shared editor
    /// observes it even when the invalid control lives in another Card setup.
    private func routeToSetup(_ id: UUID, focusing target: ItemTypeStudioValidationTarget) {
        validationFocus = nil
        // A manual Back can leave navigationDestination(item:) holding its
        // previous value. Give every programmatic push a fresh route identity
        // so validation can reopen the same Card setup without clearing the
        // binding first (which can pop the outer Studio on compact devices).
        selectedCardSetupID = id
        let route = ItemTypeStudioSetupRoute(cardSetupID: id)
        setupRoute = route
        Task { @MainActor in
            await Task.yield()
            guard setupRoute?.id == route.id else { return }
            validationFocus = target
        }
    }

    private func focus(_ target: ItemTypeStudioValidationTarget) {
        switch target {
        case .itemTypeName: textFocus = .name
        case let .field(id): textFocus = .field(id)
        case let .cardSetup(id),
             let .component(cardSetupID: id, componentID: _),
             let .availability(cardSetupID: id),
             let .answerMethod(cardSetupID: id),
             let .layout(cardSetupID: id),
             let .recipe(cardSetupID: id, purpose: _):
            guard setupRoute?.cardSetupID != id else { return }
            selectedCardSetupID = id
            setupRoute = .init(cardSetupID: id)
        }
    }

    private func saveImpactMessage(_ impact: ItemTypeStudioSaveImpact) -> String {
        var parts: [String] = []
        if !impact.removedFields.isEmpty {
            parts.append("Removes fields: \(impact.removedFields.map(\.name).joined(separator: ", ")).")
        }
        if !impact.changedFields.isEmpty {
            parts.append("Changes \(impact.changedFields.count) field \(impact.changedFields.count == 1 ? "definition" : "definitions").")
        }
        if !impact.removedCardSetups.isEmpty {
            parts.append("Removes Card setups: \(impact.removedCardSetups.map(\.name).joined(separator: ", ")).")
        }
        if impact.generatedCardRetirementCount > 0 {
            let count = impact.generatedCardRetirementCount
            parts.append("Retires \(count) generated card\(count == 1 ? "" : "s").")
        }
        if impact.persistentSpokenResponseCount > 0 {
            let count = impact.persistentSpokenResponseCount
            parts.append("Permanently deletes \(count) saved spoken \(count == 1 ? "response" : "responses").")
        }
        if impact.schemaChange.affectedItemCount > 0 {
            parts.append("Affects stored data on \(impact.schemaChange.affectedItemCount) existing \(impact.schemaChange.affectedItemCount == 1 ? "item" : "items").")
        }
        return parts.isEmpty ? "Save the complete item type and its Card setups together?" : parts.joined(separator: " ")
    }

    private func prepareUnlock() async {
        guard isDraftReadOnly,
              let requestedID = model.studioDraft?.id,
              model.selectedItemTypeID == requestedID
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let impact = try await model.editingImpactForIncludedItemType(id: requestedID)
            guard isDraftReadOnly,
                  model.studioDraft?.id == requestedID,
                  model.selectedItemTypeID == requestedID
            else { return }
            pendingUnlockItemTypeID = requestedID
            unlockImpact = impact
        } catch {
            present(error, title: "Could Not Unlock Item Type")
        }
    }

    private func unlock() async {
        guard let requestedID = pendingUnlockItemTypeID,
              model.studioDraft?.id == requestedID
        else {
            unlockImpact = nil
            pendingUnlockItemTypeID = nil
            return
        }
        unlockImpact = nil
        pendingUnlockItemTypeID = nil
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.unlockItemType(id: requestedID)
            _ = model.beginEditingSelectedItemType()
            try await reloadLibrary()
        } catch {
            present(error, title: "Could Not Unlock Item Type")
        }
    }

    private func duplicate() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let originalName = model.selectedItemType?.name ?? "Item Type"
            _ = try await model.duplicateSelectedIncludedItemType(name: "\(originalName) Copy")
            _ = model.beginEditingSelectedItemType()
            try await reloadLibrary()
        } catch {
            present(error, title: "Could Not Duplicate Item Type")
        }
    }

    private func prepareDelete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let itemCount = try await model.selectedItemTypeDeletionImpact()
            guard itemCount == 0 else {
                throw ItemTypesFeatureError.itemTypeHasItems(itemCount)
            }
            confirmsDelete = true
        } catch {
            present(error, title: "Could Not Delete Item Type")
        }
    }

    private func deleteItemType() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.deleteSelectedItemType()
            try await reloadLibrary()
            dismiss()
        } catch {
            present(error, title: "Could Not Delete Item Type")
        }
    }

    private func requestCancel() {
        guard hasUnsavedStudioChanges else {
            closeStudio()
            return
        }
        confirmsDiscard = true
    }

    private func closeStudio() {
        dismiss()
    }

    private func unlockImpactMessage(_ impact: ItemTypeEditingImpact) -> String {
        let items = impact.itemCount == 1 ? "1 item" : "\(impact.itemCount) items"
        let decks = impact.deckCount == 1 ? "1 deck" : "\(impact.deckCount) decks"
        return "This definition is used by \(items) across \(decks). Future edits affect all of them."
    }

    private func present(_ error: Error, title: String = "Could Not Save Item Type") {
        errorTitle = title
        errorMessage = MobileAppModel.message(for: error)
    }

    private func withOptionalMotion(_ operation: () -> Void) {
        if reduceMotionOverride ?? systemReduceMotion {
            operation()
        } else {
            withAnimation(.easeInOut(duration: 0.2), operation)
        }
    }

    private func fieldTypeName(_ type: FieldType) -> String {
        switch type {
        case .text: "Text"
        case .richText: "Rich text"
        case .number: "Number"
        case .audio: "Audio"
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        case .cloze: "Cloze"
        }
    }
}
#endif
