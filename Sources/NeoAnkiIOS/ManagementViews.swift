#if os(iOS)
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiDeckBuilderCore
import NeoAnkiFeatures
import PoemDeckBuilder
import ProseDeckBuilder
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

private struct MobileImportPreview: Identifiable {
    let id = UUID()
    let url: URL
    let sourceName: String
    let bytes: Int64
    let payload: ImportPayload?
}

struct TransferToolsView: View {
    @Bindable var model: MobileAppModel
    @State private var isChoosingFile = false
    @State private var isWorking = false
    @State private var pendingImport: MobileImportPreview?
    @State private var stagedDirectory: URL?
    @State private var progressMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Import") {
                Button { isChoosingFile = true } label: { Label("Choose File", systemImage: "square.and.arrow.down") }
                Text("JSON, CSV, .neodeck, and .neoanki").font(.footnote).foregroundStyle(.secondary)
                if isWorking { ProgressView("Preparing preview…") }
                if let progressMessage { Label(progressMessage, systemImage: "checkmark.circle") }
            }
            Section("Export") {
                if model.decks.isEmpty { Text("Create a deck to export its items.").foregroundStyle(.secondary) }
                ForEach(model.decks) { deck in
                    NavigationLink { ExportDeckView(model: model, deck: deck) } label: { Label(deck.name, systemImage: "square.and.arrow.up") }
                }
            }
        }
        .disabled(isWorking)
        .navigationTitle("Transfer")
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.json, .commaSeparatedText, .neoDeck, .neoAnkiBundle]) { result in
            Task { await preparePreview(result) }
        }
        .sheet(item: $pendingImport, onDismiss: cleanupPreview) { preview in
            NavigationStack {
                List {
                    Section("Source") {
                        LabeledContent("File", value: preview.sourceName)
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file))
                        LabeledContent("Format", value: preview.url.pathExtension.uppercased())
                    }
                    if let payload = preview.payload {
                        Section("Preview") {
                            LabeledContent("Item Type", value: payload.itemTypeName)
                            LabeledContent("Items", value: payload.rows.count.formatted())
                            ForEach(Array(payload.rows.prefix(5).enumerated()), id: \.offset) { index, row in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Item \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                    ForEach(row.fieldValues.keys.sorted(), id: \.self) { key in
                                        Text(row.fieldValues[key] ?? "").lineLimit(3)
                                    }
                                }
                            }
                        }
                    } else {
                        Section { Text("This package includes its decks, item types, and media. It will be checked before importing into your library.") }
                    }
                    if isWorking { ProgressView("Importing…") }
                }
                .navigationTitle("Review Import").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cleanupPreview(); pendingImport = nil }.disabled(isWorking) }
                    ToolbarItem(placement: .confirmationAction) { Button("Import") { Task { await importPreview(preview) } }.disabled(isWorking) }
                }
                .interactiveDismissDisabled(isWorking)
            }
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please verify the file and try again.") }
        .task {
            let process = ProcessInfo.processInfo
            let scenario = process.environment["NEOANKI_TEST_SCENARIO"] ?? ""
            if process.arguments.contains("-NeoAnkiUITestingReset"), ["mobile-transfer", "mobile-transfer-error"].contains(scenario) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("Sample.json")
                do {
                    let source = scenario == "mobile-transfer-error" ? "invalid JSON" : #"{"itemType":"Basic","rows":[{"Front":"Imported question","Back":"Imported answer"}]}"#
                    try Data(source.utf8).write(to: file)
                    await preparePreview(.success(file))
                    try? FileManager.default.removeItem(at: file)
                } catch { errorMessage = MobileAppModel.message(for: error) }
            }
        }
    }

    private func preparePreview(_ result: Result<URL, Error>) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let source = try result.get()
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let staged = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: source, to: staged)
                let payload: ImportPayload?
                switch staged.pathExtension.lowercased() {
                case "json": payload = try JSONImportAdapter().parse(Data(contentsOf: staged))
                case "csv": payload = try CSVImportAdapter(itemTypeName: "Imported").parse(Data(contentsOf: staged))
                default: payload = nil
                }
                let size = Int64((try staged.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                stagedDirectory = folder
                pendingImport = MobileImportPreview(url: staged, sourceName: source.lastPathComponent, bytes: size, payload: payload)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        } catch { errorMessage = MobileAppModel.message(for: error) }
    }

    private func importPreview(_ preview: MobileImportPreview) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = preview.url
            let count: Int
            switch url.pathExtension.lowercased() {
            case "json": count = try await model.importJSON(Data(contentsOf: url), itemTypeID: nil, deckID: nil)
            case "csv": count = try await model.importCSV(Data(contentsOf: url), itemTypeID: nil, itemTypeName: "Imported", deckID: nil)
            case "neoanki": count = try await model.importAuthoredBundle(from: url).itemCount
            default: count = try await model.importPortableDeck(from: url, conflict: .useMatchingSchema).itemCount
            }
            progressMessage = "Imported \(count) \(count == 1 ? "item" : "items")"
            cleanupPreview(); pendingImport = nil
        } catch { cleanupPreview(); pendingImport = nil; errorMessage = MobileAppModel.message(for: error) }
    }

    private func cleanupPreview() {
        if let stagedDirectory { try? FileManager.default.removeItem(at: stagedDirectory) }
        stagedDirectory = nil
    }
}

private struct ExportDeckView: View {
    @Bindable var model: MobileAppModel
    let deck: DeckSummary
    @State private var document: PortableDeckDocument?
    @State private var isExporting = false
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Deck") { LabeledContent("Name", value: deck.name); LabeledContent("Items", value: deck.itemCount.formatted()) }
            Section {
                Button("Prepare Export", systemImage: "square.and.arrow.up") { Task { await prepare() } }.disabled(isPreparing)
                if isPreparing { ProgressView("Preparing export…") }
            } footer: { Text("A portable .neodeck file includes item types, scheduling history, and media. Personal recordings stay on this device.") }
        }
        .navigationTitle("Export Deck")
        .fileExporter(isPresented: $isExporting, document: document, contentType: .neoDeck, defaultFilename: "\(deck.name).neodeck") { result in
            if case let .failure(error) = result { errorMessage = MobileAppModel.message(for: error) }
            document = nil
        }
        .alert("Export Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
    }

    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }
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
                DatePicker("New day begins", selection: Binding(
                    get: { Calendar.current.date(from: DateComponents(hour: rollover / 60, minute: rollover % 60)) ?? .now },
                    set: { let parts = Calendar.current.dateComponents([.hour, .minute], from: $0); rollover = (parts.hour ?? 4) * 60 + (parts.minute ?? 0) }
                ), displayedComponents: .hourAndMinute)
                Button("Save") {
                    Task {
                        do {
                            try await model.library.setStudyDayRolloverMinutes(rollover)
                            message = "Study day updated"
                            await model.refresh()
                        } catch { message = MobileAppModel.message(for: error) }
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Study Day")
        .task {
            rollover = (try? await model.library.studyDayRolloverMinutes()) ?? 240
        }
    }
}

struct SyncIssuesMobileView: View {
    @Bindable var model: MobileAppModel
    @State private var errorMessage: String?
    var body: some View {
        List {
        ForEach(model.syncIssues) { issue in
          Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.summary).font(.headline)
                Text(issue.resourceID).font(.caption.monospaced()).foregroundStyle(.secondary)
                if issue.conflictCopy?.isRestorable == true {
                    Label("A restorable conflict copy is preserved", systemImage: "doc.on.doc").font(.subheadline)
                }
            }.padding(.vertical, 5)
                if issue.conflictCopy?.isRestorable == true {
                    Button {
                        Task {
                            do { try await model.restoreSyncConflict(id: issue.id) }
                            catch { errorMessage = MobileAppModel.message(for: error) }
                        }
                    } label: { Text("Restore as New Copy").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                    .buttonStyle(.borderedProminent).neoAnkiMobilePrimaryActionTint()
                }
                Button { Task { await model.retrySyncIssue(id: issue.id) } } label: {
                    Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Button(role: .destructive) { Task { await model.dismissSyncIssue(id: issue.id) } } label: {
                    Label("Dismiss", systemImage: "xmark.circle").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
          }
        }
        }
        .buttonStyle(.borderless)
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
                ProseBuilderMobileHost(model: model)
            } label: {
                Label("Prose Deck", systemImage: "text.book.closed")
            }
            NavigationLink {
                VocabularyBuilderMobileHost(model: model, vocabularyLibrary: vocabularyLibrary)
            } label: {
                Label("Vocabulary Deck", systemImage: "character.book.closed")
            }
        }
        .navigationTitle("Deck Builders")

    }
}

private struct VocabularyBuilderMobileHost: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        Group {
            if !vocabularyLibrary.builderOptions.isEmpty {
                VocabularyDeckBuilderView(
                    installedPacks: vocabularyLibrary.builderOptions,
                    rootDecks: model.decks.filter { $0.parentID == nil }.map {
                        DeckBuilderDeckOption(id: $0.id, name: $0.name)
                    },
                    onGenerated: { generated in
                        guard !isImporting else { generated.cleanup(); return }
                        isImporting = true
                        Task {
                            defer { generated.cleanup(); isImporting = false }
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
                        guard !isImporting else { generated.cleanup(); return }
                        isImporting = true
                        Task {
                            defer { generated.cleanup(); isImporting = false }
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
        .disabled(isImporting)
        .navigationBarBackButtonHidden(isImporting)
        .interactiveDismissDisabled(isImporting)
        .overlay {
            if isImporting {
                ProgressView("Importing deck…").padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
    @State private var isImporting = false

    var body: some View {
        PoemDeckBuilderView(
            rootDecks: model.decks.filter { $0.parentID == nil }.map {
                DeckBuilderDeckOption(id: $0.id, name: $0.name)
            },
            onGenerated: { generated in
                guard !isImporting else { generated.cleanup(); return }
                isImporting = true
                Task {
                    defer { generated.cleanup(); isImporting = false }
                    do {
                        let result = try await model.importAuthoredBundle(from: generated.bundleURL)
                        guard let parentID = generated.destinationDeckID,
                              let poemID = result.deckIDs.first,
                              let poem = model.decks.first(where: { $0.id == poemID })
                        else {
                            throw PoemDeckReconciliationError.brokenChain
                        }
                        try await model.updateDeck(
                            id: poemID,
                            name: poem.name,
                            parentID: parentID,
                            newCardsPerDay: poem.newCardsPerDay
                        )
                        dismiss()
                    } catch {
                        errorMessage = MobileAppModel.message(for: error)
                    }
                }
            },
            onCancel: { dismiss() }
        )
        .disabled(isImporting)
        .navigationBarBackButtonHidden(isImporting)
        .interactiveDismissDisabled(isImporting)
        .overlay {
            if isImporting {
                ProgressView("Importing deck…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("builderImportProgress")
            }
        }
        .alert("Could Not Add Deck", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Please try again.") }
    }
}

private struct ProseBuilderMobileHost: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        ProseDeckBuilderView(
            rootDecks: model.decks.filter { $0.parentID == nil }.map {
                DeckBuilderDeckOption(id: $0.id, name: $0.name)
            },
            onGenerated: { generated in
                guard !isImporting else { generated.cleanup(); return }
                isImporting = true
                Task {
                    defer { generated.cleanup(); isImporting = false }
                    do {
                        let result = try await model.importAuthoredBundle(from: generated.bundleURL)
                        guard let parentID = generated.destinationDeckID,
                              let proseID = result.deckIDs.first,
                              let prose = model.decks.first(where: { $0.id == proseID })
                        else {
                            throw ProseDeckEditError.mixedContent
                        }
                        try await model.updateDeck(
                            id: proseID,
                            name: prose.name,
                            parentID: parentID,
                            newCardsPerDay: prose.newCardsPerDay
                        )
                        dismiss()
                    } catch {
                        errorMessage = MobileAppModel.message(for: error)
                    }
                }
            },
            onCancel: { dismiss() }
        )
        .disabled(isImporting)
        .navigationBarBackButtonHidden(isImporting)
        .interactiveDismissDisabled(isImporting)
        .overlay {
            if isImporting {
                ProgressView("Importing deck…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("builderImportProgress")
            }
        }
        .alert("Could Not Add Deck", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
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
                        .buttonStyle(.borderedProminent).neoAnkiMobilePrimaryActionTint()
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
