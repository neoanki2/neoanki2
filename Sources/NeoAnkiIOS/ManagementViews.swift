#if os(iOS)
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiDeckBuilderCore
import NeoAnkiFeatures
import PoemDeckBuilder
import VocabularyDeckBuilder
import SwiftUI
import UniformTypeIdentifiers

struct ItemTypesMobileView: View {
    @Bindable var model: MobileAppModel
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(model.itemTypes) { type in
                NavigationLink {
                    ItemTypeDetailMobileView(model: model, itemType: type)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(type.name).font(.headline)
                        Text("\(type.fields.count) fields · \(type.templates.count) templates")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let owner = model.includedItemTypeOwner(id: type.id) {
                            Label("From \(owner.deckPath) · Read-only", systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    if model.includedItemTypeOwner(id: type.id) == nil {
                        Button("Delete", role: .destructive) { Task { await perform { try await model.deleteItemType(id: type.id) } } }
                    }
                    Button("Duplicate") { Task { await perform { try await model.duplicateItemType(id: type.id, name: "\(type.name) Copy") } } }.tint(.blue)
                }
            }
        }
        .navigationTitle("Item Types")
        .toolbar {
            Button("New Type", systemImage: "plus") { Task { await createBasicType() } }
        }
        .alert("Could Not Update Item Types", isPresented: errorBinding) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
    }

    private var errorBinding: Binding<Bool> { Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }) }
    private func createBasicType() async {
        await perform {
            let front = FieldDef(name: "Front", type: .richText, isRequired: true)
            let back = FieldDef(name: "Back", type: .richText, isRequired: true)
            try await model.createItemType(ItemTypeBuilder.makeItemType(name: "New Item Type", fields: [front, back]))
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch { errorMessage = MobileAppModel.message(for: error) }
    }
}

private struct ItemTypeDetailMobileView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @State var itemType: ItemType
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false
    @State private var affectedResponseCount = 0
    @State private var confirmsResponseDeletion = false
    @State private var unlockImpact: ItemTypeEditingImpact?
    @State private var schemaImpact: ItemTypeSchemaChangeImpact?
    private let original: ItemType

    private var includedOwner: IncludedItemTypeGroup? {
        model.includedItemTypeOwner(id: itemType.id)
    }

    init(model: MobileAppModel, itemType: ItemType) {
        self.model = model
        _itemType = State(initialValue: itemType)
        original = itemType
    }

    var body: some View {
        Form {
            if let includedOwner {
                Section {
                    Label("From \(includedOwner.deckPath) · Read-only", systemImage: "lock")
                    Button("Unlock for Editing…", systemImage: "lock.open") {
                        Task { await prepareUnlock() }
                    }
                    .disabled(isSaving)
                    Button("Duplicate as Item Type…", systemImage: "plus.square.on.square") {
                        Task {
                            await perform {
                                try await model.duplicateItemType(
                                    id: itemType.id,
                                    name: "\(itemType.name) Copy"
                                )
                            }
                        }
                    }
                    .disabled(isSaving)
                } footer: {
                    Text("Unlock the original to change every item and deck that uses it, or duplicate it for an independent copy.")
                }
            }
            identitySection
                .disabled(includedOwner != nil)
            fieldsSection
                .disabled(includedOwner != nil)
            templatesSection
                .disabled(includedOwner != nil)
            if includedOwner == nil {
                Section {
                    Button("Repair Definition") { Task { await perform { try await model.repairItemType(id: itemType.id) } } }
                } footer: {
                    Text("Advanced slot, reveal, media, skill, and generation controls are shown progressively in each template.")
                }
            }
        }
        .navigationTitle(itemType.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if itemType == original { dismiss() } else { confirmsDiscard = true }
                }
            }
            if includedOwner == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await requestSave() } }
                        .disabled(isSaving || itemType.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmsDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete saved spoken responses?",
            isPresented: $confirmsResponseDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Responses and Save", role: .destructive) { Task { await save() } }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This template change removes cards with \(affectedResponseCount) saved spoken \(affectedResponseCount == 1 ? "response" : "responses"). The recordings will be permanently deleted.")
        }
        .confirmationDialog(
            "Unlock \(itemType.name) for editing?",
            isPresented: Binding(
                get: { unlockImpact != nil },
                set: { if !$0 { unlockImpact = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unlock for Editing") { Task { await unlock() } }
            Button("Cancel", role: .cancel) { unlockImpact = nil }
        } message: {
            if let unlockImpact { Text(unlockImpactMessage(unlockImpact)) }
        }
        .confirmationDialog(
            "Save potentially destructive changes?",
            isPresented: Binding(
                get: { schemaImpact != nil },
                set: { if !$0 { schemaImpact = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save Changes", role: .destructive) {
                schemaImpact = nil
                Task { await prepareResponseDeletionOrSave() }
            }
            Button("Keep Editing", role: .cancel) { schemaImpact = nil }
        } message: {
            if let schemaImpact { Text(schemaImpactMessage(schemaImpact)) }
        }
        .alert("Could Not Save Item Type", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func requestSave() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let impact = try await model.itemTypeSchemaChangeImpact(
                from: original,
                to: itemType
            )
            if impact.requiresConfirmation {
                schemaImpact = impact
                return
            }
            try await resolveResponseDeletionOrSave()
        } catch {
            errorMessage = MobileAppModel.message(for: error)
        }
    }

    private func prepareResponseDeletionOrSave() async {
        isSaving = true
        defer { isSaving = false }
        do { try await resolveResponseDeletionOrSave() }
        catch { errorMessage = MobileAppModel.message(for: error) }
    }

    private func resolveResponseDeletionOrSave() async throws {
        let currentTemplateIDs = Set(itemType.templates.map(\.id))
        let removedTemplateIDs = Set(original.templates.map(\.id)).subtracting(currentTemplateIDs)
        affectedResponseCount = try await model.studyResponseCount(templateIDs: removedTemplateIDs)
        if affectedResponseCount > 0 {
            confirmsResponseDeletion = true
        } else {
            try await model.updateItemType(itemType)
            dismiss()
        }
    }

    private func prepareUnlock() async {
        isSaving = true
        defer { isSaving = false }
        do { unlockImpact = try await model.itemTypeEditingImpact(id: itemType.id) }
        catch { errorMessage = MobileAppModel.message(for: error) }
    }

    private func unlock() async {
        unlockImpact = nil
        isSaving = true
        defer { isSaving = false }
        await perform { try await model.unlockItemType(id: itemType.id) }
    }

    private func save() async { isSaving = true; defer { isSaving = false }; await perform { try await model.updateItemType(itemType); dismiss() } }
    private func perform(_ operation: () async throws -> Void) async { do { try await operation() } catch { errorMessage = MobileAppModel.message(for: error) } }

    private func unlockImpactMessage(_ impact: ItemTypeEditingImpact) -> String {
        let usage: String
        if impact.itemCount == 0 {
            usage = "No existing items currently use it."
        } else {
            let items = impact.itemCount == 1 ? "1 existing item" : "\(impact.itemCount) existing items"
            let decks = impact.deckCount == 1 ? "1 deck" : "\(impact.deckCount) decks"
            if impact.deckCount == 0 {
                usage = "It is used by \(items), all currently unassigned."
            } else if impact.unassignedItemCount == 0 {
                usage = "It is used by \(items) across \(decks)."
            } else {
                let unassigned = impact.unassignedItemCount == 1
                    ? "1 item is unassigned"
                    : "\(impact.unassignedItemCount) items are unassigned"
                usage = "It is used by \(items) across \(decks); \(unassigned)."
            }
        }
        return "\(usage) Unlocking adds the same definition to Item Types without making a copy. Later changes affect every item and deck that uses it."
    }

    private func schemaImpactMessage(_ impact: ItemTypeSchemaChangeImpact) -> String {
        var changes: [String] = []
        if !impact.removedPopulatedFields.isEmpty {
            changes.append("Removed: \(impact.removedPopulatedFields.joined(separator: ", ")).")
        }
        if !impact.typeChangedPopulatedFields.isEmpty {
            changes.append("Type changed: \(impact.typeChangedPopulatedFields.joined(separator: ", ")).")
        }
        let items = impact.affectedItemCount == 1
            ? "1 existing item has stored content in these fields."
            : "\(impact.affectedItemCount) existing items have stored content in these fields."
        return "\(items) That content may no longer be usable after this edit. \(changes.joined(separator: " "))"
    }

    private var identitySection: some View {
        Section("Identity") { TextField("Name", text: $itemType.name) }
    }
    private var fieldsSection: some View {
        Section("Fields") {
            ForEach($itemType.fields) { field in fieldRow(field) }
                .onDelete { itemType.fields.remove(atOffsets: $0) }
            Button("Add Field", systemImage: "plus") { itemType.fields.append(FieldDef(name: "New Field", type: .text)) }
        }
    }
    private var templatesSection: some View {
        Section("Templates") {
            ForEach($itemType.templates) { template in templateRow(template) }
                .onDelete { itemType.templates.remove(atOffsets: $0) }
            Button("Add Template", systemImage: "plus") { addTemplate() }
        }
    }
    private func fieldRow(_ field: Binding<FieldDef>) -> some View {
        VStack(alignment: .leading) {
            TextField("Field name", text: field.name)
            Picker("Type", selection: field.type) {
                ForEach(FieldType.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
            }
            Toggle("Required", isOn: field.isRequired)
        }
        .padding(.vertical, 4)
    }
    private func templateRow(_ template: Binding<Template>) -> some View {
        NavigationLink {
            TemplateMobileEditor(template: template, fields: itemType.fields)
        } label: {
            VStack(alignment: .leading) {
                Text(template.wrappedValue.name)
                Text("\(template.wrappedValue.prompt.slots.count) prompt · \(template.wrappedValue.answer.slots.count) answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func addTemplate() {
        guard let first = itemType.fields.first else { return }
        itemType.templates.append(Template(
            name: "New Template",
            prompt: Side(slots: [Slot(source: .field(first.id))]),
            answer: Side(slots: [Slot(source: .field(first.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .freeResponse, operation: .recall)
        ))
    }
}

private struct TemplateMobileEditor: View {
    @Binding var template: Template
    let fields: [FieldDef]
    @State private var showClearAnswerConfirmation = false

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $template.name)
                Picker("Interaction", selection: interactionBinding) {
                    ForEach(Interaction.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                if template.interaction == .audioSubmission {
                    Label("Responses are persistent on this device and are not included in Cloud sync.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            slots(title: "Prompt", slots: $template.prompt.slots)
            if template.interaction != .audioSubmission {
                slots(title: "Answer", slots: $template.answer.slots)
            }
            Section("Skill") {
                Picker("Input", selection: $template.skill.input) {
                    ForEach(Modality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                if template.interaction == .audioSubmission {
                    LabeledContent("Output", value: "Audio")
                } else {
                    Picker("Output", selection: $template.skill.output) {
                        ForEach(Modality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Picker("Operation", selection: $template.skill.operation) {
                    ForEach(Operation.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Section("Generation") {
                Toggle("Require a field condition", isOn: Binding(
                    get: { template.generateWhen != nil },
                    set: { enabled in template.generateWhen = enabled ? fields.first.map { .fieldNotEmpty($0.id) } : nil }
                ))
                if template.generateWhen != nil, let first = fields.first {
                    Picker("Required field", selection: conditionFieldBinding(fallback: first.id)) {
                        ForEach(fields) { Text($0.name).tag($0.id) }
                    }
                    Picker("Condition", selection: conditionKindBinding) {
                        Text("Is not empty").tag(true)
                        Text("Is empty").tag(false)
                    }
                }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear the answer side?",
            isPresented: $showClearAnswerConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Answer and Continue", role: .destructive) {
                template.answer = Side(slots: [])
                template.interaction = .audioSubmission
                template.skill.output = .audio
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio Submission cards are prompt-only. Saving this item type will permanently clear this template's answer side.")
        }
    }

    private var interactionBinding: Binding<Interaction> {
        Binding(
            get: { template.interaction },
            set: { interaction in
                if interaction == .audioSubmission, !template.answer.slots.isEmpty {
                    showClearAnswerConfirmation = true
                    return
                }
                template.interaction = interaction
                if interaction == .audioSubmission {
                    template.answer = Side(slots: [])
                    template.skill.output = .audio
                } else if template.answer.slots.isEmpty, let first = fields.first {
                    template.answer = Side(slots: [Slot(source: .field(first.id))])
                }
            }
        )
    }

    private func slots(title: String, slots: Binding<[Slot]>) -> some View {
        Section(title) {
            ForEach(slots.wrappedValue.indices, id: \.self) { index in
                SlotMobileEditor(slot: slots[index], fields: fields)
            }
            .onDelete { slots.wrappedValue.remove(atOffsets: $0) }
            Button("Add Field Slot", systemImage: "plus") {
                if let first = fields.first { slots.wrappedValue.append(Slot(source: .field(first.id))) }
            }
            Button("Add Literal", systemImage: "text.badge.plus") { slots.wrappedValue.append(Slot(source: .literal("Label"))) }
        }
    }

    private func conditionFieldBinding(fallback: UUID) -> Binding<UUID> { Binding(
        get: {
            switch template.generateWhen { case let .fieldNotEmpty(id), let .fieldEmpty(id): id; default: fallback }
        },
        set: { id in template.generateWhen = conditionKindBinding.wrappedValue ? .fieldNotEmpty(id) : .fieldEmpty(id) }
    ) }
    private var conditionKindBinding: Binding<Bool> { Binding(
        get: { if case .fieldEmpty = template.generateWhen { false } else { true } },
        set: { nonempty in
            let id: UUID? = switch template.generateWhen { case let .fieldNotEmpty(id), let .fieldEmpty(id): id; default: fields.first?.id }
            if let id { template.generateWhen = nonempty ? .fieldNotEmpty(id) : .fieldEmpty(id) }
        }
    ) }
}

private struct SlotMobileEditor: View {
    @Binding var slot: Slot
    let fields: [FieldDef]
    private enum SourceKind: String, CaseIterable { case field, literal }

    var body: some View {
        DisclosureGroup(sourceSummary) {
            Picker("Source", selection: sourceKind) {
                Text("Field").tag(SourceKind.field)
                Text("Literal").tag(SourceKind.literal)
            }
            switch slot.source {
            case let .field(id):
                Picker("Field", selection: Binding(get: { id }, set: { slot.source = .field($0) })) {
                    ForEach(fields) { Text($0.name).tag($0.id) }
                }
            case let .literal(text):
                TextField("Literal text", text: Binding(get: { text }, set: { slot.source = .literal($0) }))
            }
            Picker("Reveal", selection: $slot.presentation.reveal) {
                ForEach(RevealMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Media", selection: $slot.presentation.media) {
                ForEach(MediaBehavior.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var sourceSummary: String {
        switch slot.source {
        case let .field(id): fields.first(where: { $0.id == id })?.name ?? "Missing field"
        case let .literal(text): text.isEmpty ? "Literal" : text
        }
    }
    private var sourceKind: Binding<SourceKind> { Binding(
        get: { if case .field = slot.source { .field } else { .literal } },
        set: { kind in
            switch kind {
            case .field: if let first = fields.first { slot.source = .field(first.id) }
            case .literal: slot.source = .literal("")
            }
        }
    ) }
}

struct TransferToolsView: View {
    @Bindable var model: MobileAppModel
    @State private var isImporting = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Import") {
                Button { isImporting = true } label: { Label("Choose JSON, CSV, .neodeck, or .neoanki", systemImage: "square.and.arrow.down") }
                if let progressMessage { Label(progressMessage, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            Section("Export") {
                ForEach(model.decks) { deck in
                    NavigationLink { ExportDeckView(model: model, deck: deck) } label: { Label(deck.name, systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Transfer")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .commaSeparatedText, .neoDeck, .neoAnkiBundle]) { result in
            Task { await importResult(result) }
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please verify the file and try again.") }
    }

    private func importResult(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            switch url.pathExtension.lowercased() {
            case "json": progressMessage = "Imported \(try await model.importJSON(Data(contentsOf: url), itemTypeID: nil, deckID: nil)) items"
            case "csv": progressMessage = "Imported \(try await model.importCSV(Data(contentsOf: url), itemTypeID: nil, itemTypeName: "Imported", deckID: nil)) items"
            case "neoanki": progressMessage = "Imported \(try await model.importAuthoredBundle(from: url).itemCount) items"
            default: progressMessage = "Imported \(try await model.importPortableDeck(from: url, conflict: .useMatchingSchema).itemCount) items"
            }
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }
}

private struct ExportDeckView: View {
    @Bindable var model: MobileAppModel
    let deck: DeckSummary
    @State private var document: PortableDeckDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        ContentUnavailableView {
            Label("Export \(deck.name)", systemImage: "archivebox")
        } description: {
            Text("Creates a portable .neodeck bundle including schemas, scheduling history, and media.")
        } actions: {
            Button("Prepare Export") { Task { await prepare() } }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .navigationTitle("Export Deck")
        .fileExporter(isPresented: $isExporting, document: document, contentType: .neoDeck, defaultFilename: "\(deck.name).neodeck") { result in
            if case let .failure(error) = result { errorMessage = MobileAppModel.message(for: error) }
            document = nil
        }
        .alert("Export Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func prepare() async {
        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("neodeck")
            try await model.exportDeck(id: deck.id, to: temporary)
            document = PortableDeckDocument(data: try Data(contentsOf: temporary))
            try? FileManager.default.removeItem(at: temporary)
            isExporting = true
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }
}

private struct PortableDeckDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.neoDeck] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SchedulingMobileView: View {
    @Bindable var model: MobileAppModel
    @State private var rollover = 240
    @State private var message: String?
    var body: some View {
        Form {
            Section("Study Day") {
                Stepper("Rollover: \(rollover / 60):\(String(format: "%02d", rollover % 60))", value: $rollover, in: 0...1439, step: 15)
                Button("Save") { Task { try? await model.library.setStudyDayRolloverMinutes(rollover); message = "Scheduling updated"; await model.refresh() } }
            }
            Section("FSRS") {
                Button("Optimize From Review History") { Task { let result = try? await model.library.optimizeSchedulingIfNeeded(asOf: .now); message = result == nil ? "More review history is needed" : "Parameters optimized" } }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Scheduling")
        .task { rollover = (try? await model.library.studyDayRolloverMinutes()) ?? 240 }
    }
}

struct SyncIssuesMobileView: View {
    @Bindable var model: MobileAppModel
    @State private var errorMessage: String?
    var body: some View {
        List(model.syncIssues) { issue in
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.summary).font(.headline)
                Text(issue.resourceID).font(.caption.monospaced()).foregroundStyle(.secondary)
                if issue.conflictCopy?.isRestorable == true {
                    Label("A restorable conflict copy is preserved", systemImage: "doc.on.doc").font(.subheadline)
                    Button("Restore as New Copy") {
                        Task {
                            do { try await model.restoreSyncConflict(id: issue.id) }
                            catch { errorMessage = MobileAppModel.message(for: error) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack {
                    Button("Retry") { Task { await model.retrySyncIssue(id: issue.id) } }
                    Button("Dismiss", role: .destructive) { Task { await model.dismissSyncIssue(id: issue.id) } }
                }
            }.padding(.vertical, 5)
        }
        .overlay { if model.syncIssues.isEmpty { ContentUnavailableView("No Sync Issues", systemImage: "checkmark.icloud") } }
        .navigationTitle("Sync Issues")
        .alert("Could Not Restore Copy", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Please try again.") }
    }
}

struct BuilderToolsView: View {
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    var body: some View {
        List {
            NavigationLink {
                PoemBuilderMobileHost(model: model)
            } label: {
                Label("Poem Deck", systemImage: "text.quote")
            }
            NavigationLink {
                VocabularyBuilderMobileHost(model: model, vocabularyLibrary: vocabularyLibrary)
            } label: {
                Label("Vocabulary Deck", systemImage: "character.book.closed")
            }
        }
        .navigationTitle("Deck Builders")
        .safeAreaInset(edge: .bottom) {
            Text("Builders validate a preview before importing the generated authored bundle.")
                .font(.footnote).foregroundStyle(.secondary).padding()
        }
    }
}

private struct VocabularyBuilderMobileHost: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !vocabularyLibrary.builderOptions.isEmpty {
                VocabularyDeckBuilderView(
                    installedPacks: vocabularyLibrary.builderOptions,
                    rootDecks: model.decks.filter { $0.parentID == nil }.map {
                        DeckBuilderDeckOption(id: $0.id, name: $0.name)
                    },
                    onGenerated: { generated in
                        Task {
                            defer { generated.cleanup() }
                            do {
                                _ = try await model.importAuthoredBundle(from: generated.bundleURL)
                                dismiss()
                            } catch { errorMessage = MobileAppModel.message(for: error) }
                        }
                    },
                    onCancel: { dismiss() }
                )
            } else {
                VocabularyDeckBuilderView(
                    rootDecks: model.decks.filter { $0.parentID == nil }.map {
                        DeckBuilderDeckOption(id: $0.id, name: $0.name)
                    },
                    onGenerated: { generated in
                        Task {
                            defer { generated.cleanup() }
                            do {
                                _ = try await model.importAuthoredBundle(from: generated.bundleURL)
                                dismiss()
                            } catch {
                                errorMessage = MobileAppModel.message(for: error)
                            }
                        }
                    },
                    onCancel: { dismiss() }
                )
            }
        }
        .task { await vocabularyLibrary.load() }
        .alert("Could Not Add Vocabulary", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Please try again.") }
    }
}

private struct PoemBuilderMobileHost: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @State private var errorMessage: String?

    var body: some View {
        PoemDeckBuilderView(
            rootDecks: model.decks.filter { $0.parentID == nil }.map {
                DeckBuilderDeckOption(id: $0.id, name: $0.name)
            },
            onGenerated: { generated in
                Task {
                    defer { generated.cleanup() }
                    do {
                        _ = try await model.importAuthoredBundle(from: generated.bundleURL)
                        dismiss()
                    } catch {
                        errorMessage = MobileAppModel.message(for: error)
                    }
                }
            },
            onCancel: { dismiss() }
        )
        .alert("Could Not Add Deck", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Please try again.") }
    }
}

struct VocabularyToolsView: View {
    @Bindable var model: MobileVocabularyLibraryModel
    @State private var isImporting = false

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading installed packs…")
            } else if model.installedPacks.isEmpty {
                ContentUnavailableView {
                    Label("No Vocabulary Packs", systemImage: "books.vertical")
                } description: {
                    Text("Install a .neovocab package once, then search it and generate cards entirely offline.")
                } actions: {
                    Button("Install Pack…") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.installedPacks) { pack in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pack.title).font(.headline)
                            Text("\(pack.languages.joined(separator: ", ")) · \(pack.entryCount.formatted()) entries")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { offsets in
                        for index in offsets { Task { await model.remove(id: model.installedPacks[index].id) } }
                    }
                }
            }
        }
        .navigationTitle("Vocabulary Packs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Install Pack", systemImage: "plus") { isImporting = true }
                    .disabled(model.isImporting)
            }
        }
        .overlay { if model.isImporting { ProgressView("Copying and validating…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .task { await model.load() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.neoVocabularyPack],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first { Task { await model.install(from: url) } }
        }
        .alert("Could Not Update Vocabulary Packs", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "Please try again.") }
    }
}

private extension UTType {
    static let neoDeck = UTType(exportedAs: "com.neoanki2.neodeck", conformingTo: .package)
    static let neoAnkiBundle = UTType(exportedAs: "com.neoanki2.neoanki", conformingTo: .package)
    static let neoVocabularyPack = UTType(exportedAs: "com.neoanki2.neovocab", conformingTo: .package)
}
#endif
