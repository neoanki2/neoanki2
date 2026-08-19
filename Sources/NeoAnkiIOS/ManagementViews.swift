#if os(iOS)
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiDeckBuilderCore
import NeoAnkiFeatures
import PoemDeckBuilder
import NeoAnkiSharedUI
import VocabularyDeckBuilder
import SwiftUI
import UniformTypeIdentifiers

struct ItemTypesMobileView: View {
    @Bindable var model: MobileAppModel
    @State private var studioModel: ItemTypesFeatureModel?

    init(model: MobileAppModel) {
        self.model = model
        _studioModel = State(initialValue: model.itemTypeStudioLibrary.map {
            ItemTypesFeatureModel(library: $0)
        })
    }

    var body: some View {
        if let studioModel {
            ItemTypeStudioCatalogMobileView(
                model: studioModel,
                reloadLibrary: { try await model.reload() },
                prepareCatalog: {
                    try? await MobileItemTypeStudioUITestSeeder.seedIfRequested(
                        library: model.library
                    )
                }
            )
        } else {
            ContentUnavailableView(
                "Item Type Studio Unavailable",
                systemImage: "square.stack.3d.up.slash",
                description: Text("This library does not support protected Item Type editing.")
            )
        }
    }
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
    @State private var health: LibrarySchedulingHealth?
    @State private var isWorking = false
    var body: some View {
        Form {
            Section("Study Day") {
                Stepper("Rollover: \(rollover / 60):\(String(format: "%02d", rollover % 60))", value: $rollover, in: 0...1439, step: 15)
                Button("Save") { Task { try? await model.library.setStudyDayRolloverMinutes(rollover); message = "Scheduling updated"; await model.refresh() } }
            }
            Section("FSRS") {
                if let health {
                    LabeledContent("Status") {
                        Label(
                            health.optimizerParityVerified
                                ? (health.usesPopulationDefaults ? "Population defaults" : "Personalized")
                                : "Personalization unavailable — verification pending",
                            systemImage: health.optimizerParityVerified
                                ? (health.usesPopulationDefaults ? "checkmark.shield" : "person.crop.circle.badge.checkmark")
                                : "exclamationmark.shield"
                        )
                    }
                    LabeledContent("Desired retention", value: health.desiredRetention.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("Maximum interval", value: "\(health.maximumIntervalDays) days")
                    LabeledContent("Automatic optimization", value: health.automaticOptimizationEnabled ? (health.optimizerParityVerified ? "On" : "On — activation blocked") : "Off")
                    LabeledContent("Optimizer status", value: health.optimizerStatus)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                        Text(health.modelIdentifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Parameter set", value: health.activeParameterSetID?.uuidString.lowercased() ?? "Unavailable")
                    LabeledContent("Migration", value: health.migrationStatus ?? "Unavailable")
                    LabeledContent("Legacy evidence", value: health.legacyParametersQuarantined ? "Quarantined" : "None reported")
                    if let decision = health.lastOptimizationDecision {
                        LabeledContent("Last optimization", value: decision)
                        if let completedAt = health.lastOptimizationCompletedAt {
                            LabeledContent("Completed", value: completedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let reason = health.lastOptimizationReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Restore Population Defaults") {
                        Task { await restoreDefaults() }
                    }
                    .disabled(!health.canRestoreDefaults || isWorking)
                    Button("Rollback to Previous Parameters") {
                        Task { await rollback() }
                    }
                    .disabled(!health.canRollback || isWorking)
                    if !health.canRestoreDefaults && !health.canRollback {
                        Text("Recovery becomes available after an immutable parameter history has been created.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Loading scheduler health…")
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Scheduling")
        .task {
            rollover = (try? await model.library.studyDayRolloverMinutes()) ?? 240
            health = try? await model.library.schedulingHealthSnapshot()
        }
    }

    private func restoreDefaults() async {
        isWorking = true
        defer { isWorking = false }
        do {
            health = try await model.library.restoreDefaultScheduling(now: .now)
            message = "Population defaults restored"
        } catch {
            message = MobileAppModel.message(for: error)
        }
    }

    private func rollback() async {
        isWorking = true
        defer { isWorking = false }
        do {
            health = try await model.library.rollbackScheduling(to: nil, now: .now)
            message = "Previous parameters restored"
        } catch {
            message = MobileAppModel.message(for: error)
        }
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
