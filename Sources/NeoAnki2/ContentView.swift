import AppKit
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import NeoAnkiSharedUI
import SwiftUI
import UniformTypeIdentifiers
import VocabularyDeckBuilder

private struct ImportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var itemsModel: ItemsModel
    @Bindable var decksModel: DecksModel
    @Bindable var schedulingModel: SchedulingModel
    @Bindable var vocabularyLibraryModel: VocabularyLibraryModel
    @State private var appSession = AppSession()
    /// Persisted per user, not per browse session: whether you want to see
    /// answers is a standing preference, not something to rediscover.
    @AppStorage(AppPreferences.browseShowsAnswerColumn) private var browseShowsAnswerColumn = false
    @State private var studyModel: StudyModel?
    @State private var studyScope: StudyScope = .allDecks
    @State private var templatesModel: TemplatesModel?
    @State private var endSessionTrigger = false
    /// Lives here rather than in `StudyView` because the Study menu opens the
    /// card editor, and every study command has to stand down while it is open:
    /// the grade keys are unmodified, so they would otherwise land in a field.
    @State private var isEditingStudyCard = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var importModel: ImportModel?
    @State private var isChoosingImportFile = false
    @State private var importNotice: ImportNotice?
    @State private var portableDeckTransfer: PortableDeckTransferModel
    private let deckBuilderRegistry: DeckBuilderRegistry

    private var isAddingItem: Bool {
        get { appSession.route == .addItem }
        nonmutating set { updateRoute(active: newValue, route: .addItem) }
    }

    private var isManagingTemplates: Bool {
        get { appSession.route == .itemTypes }
        nonmutating set { updateRoute(active: newValue, route: .itemTypes) }
    }

    private var isStudying: Bool {
        get {
            if case .study = appSession.route { return true }
            return false
        }
        nonmutating set {
            updateRoute(active: newValue, route: .study(studyScope.filter), matchingStudy: true)
        }
    }

    private var isBrowsing: Bool {
        get { appSession.route == .browse }
        nonmutating set { updateRoute(active: newValue, route: .browse) }
    }

    private var selectedItemID: SavedItemSummary.ID? {
        get {
            if case let .itemDetail(id) = appSession.route { return id }
            return nil
        }
        nonmutating set {
            if let newValue {
                appSession.route = .itemDetail(newValue)
            } else if case .itemDetail = appSession.route {
                appSession.route = .scopeHome
            }
        }
    }

    private var isShowingImport: Bool {
        get { appSession.presentation == .importItems }
        nonmutating set { updatePresentation(active: newValue, presentation: .importItems) }
    }

    private var isShowingDeckBuilder: Bool {
        get { appSession.presentation == .deckBuilder }
        nonmutating set { updatePresentation(active: newValue, presentation: .deckBuilder) }
    }

    private var isShowingVocabularyPacks: Bool {
        get { appSession.presentation == .vocabularyPacks }
        nonmutating set { updatePresentation(active: newValue, presentation: .vocabularyPacks) }
    }

    private var isAddingFromVocabulary: Bool {
        get {
            if case .vocabularyBuilder = appSession.presentation { return true }
            return false
        }
        nonmutating set {
            if newValue, let deckID = decksModel.selectedDeckID {
                appSession.show(.vocabularyBuilder(deckID: deckID))
            } else if case .vocabularyBuilder = appSession.presentation {
                appSession.dismissPresentation()
            }
        }
    }

    private var importPresentation: Binding<Bool> {
        Binding(get: { isShowingImport }, set: { isShowingImport = $0 })
    }

    private var deckBuilderPresentation: Binding<Bool> {
        Binding(get: { isShowingDeckBuilder }, set: { isShowingDeckBuilder = $0 })
    }

    private var vocabularyPacksPresentation: Binding<Bool> {
        Binding(get: { isShowingVocabularyPacks }, set: { isShowingVocabularyPacks = $0 })
    }

    private var vocabularyBuilderPresentation: Binding<Bool> {
        Binding(get: { isAddingFromVocabulary }, set: { isAddingFromVocabulary = $0 })
    }

    private var syncIssuesPresentation: Binding<Bool> {
        Binding(
            get: { appSession.presentation == .syncIssues },
            set: { updatePresentation(active: $0, presentation: .syncIssues) }
        )
    }
#if DEBUG
    private let testingEnvironment: [String: String]
    private let testingInitialRoute: UITestRoute
#endif

#if DEBUG
    init(
        itemsModel: ItemsModel,
        decksModel: DecksModel,
        schedulingModel: SchedulingModel,
        vocabularyLibraryModel: VocabularyLibraryModel,
        deckBuilderRegistry: DeckBuilderRegistry,
        testingEnvironment: [String: String] = [:],
        testingInitialRoute: UITestRoute = .library
    ) {
        self.itemsModel = itemsModel
        self.decksModel = decksModel
        self.schedulingModel = schedulingModel
        self.vocabularyLibraryModel = vocabularyLibraryModel
        _portableDeckTransfer = State(
            initialValue: PortableDeckTransferModel(store: itemsModel.store)
        )
        self.deckBuilderRegistry = deckBuilderRegistry
        self.testingEnvironment = testingEnvironment
        self.testingInitialRoute = testingInitialRoute
    }
#else
    init(
        itemsModel: ItemsModel,
        decksModel: DecksModel,
        schedulingModel: SchedulingModel,
        vocabularyLibraryModel: VocabularyLibraryModel,
        deckBuilderRegistry: DeckBuilderRegistry
    ) {
        self.itemsModel = itemsModel
        self.decksModel = decksModel
        self.schedulingModel = schedulingModel
        self.vocabularyLibraryModel = vocabularyLibraryModel
        _portableDeckTransfer = State(
            initialValue: PortableDeckTransferModel(store: itemsModel.store)
        )
        self.deckBuilderRegistry = deckBuilderRegistry
    }
#endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DeckSidebarView(
                decksModel: decksModel,
                selection: $decksModel.selectedScope,
                onDeleteAllUnassigned: {
                    Task {
                        _ = await itemsModel.deleteAllUnassigned(scope: decksModel.studyScope)
                        await refreshLibrary(forceRefresh: true)
                    }
                },
                onDeckSettingsSaved: {
                    await refreshCounts()
                },
                onDeckProgressReset: {
                    await refreshLibrary(forceRefresh: true)
                }
            )
            .navigationSplitViewColumnWidth(
                min: DesignSystem.sidebarMin,
                ideal: DesignSystem.sidebarIdeal,
                max: DesignSystem.sidebarMax
            )
        } detail: {
            detail
        }
        .tint(DesignSystem.accent)
        .navigationTitle(windowTitle)
        .toolbar {
            if portableDeckTransfer.isBusy || testingForcePortableBusy {
                ToolbarItem(placement: .status) {
                    ProgressView("Transferring deck…")
                        .controlSize(.small)
                        .accessibilityIdentifier("portableDeckTransferBusy")
                }
            }
            if vocabularyLibraryModel.isImporting {
                ToolbarItem(placement: .status) {
                    ProgressView("Importing vocabulary pack…")
                        .controlSize(.small)
                        .accessibilityIdentifier("vocabularyPackImportBusy")
                }
            }
            if isManagingTemplates {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        closeItemTypes()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("templatesDone")
                }
            }
        }
        .onChange(of: isStudying) { _, studying in
            setStudyFocus(studying)
        }
        .onChange(of: isManagingTemplates) { _, managing in
            setTemplatesFocus(managing)
        }
        .onChange(of: isAddingItem) { _, adding in
            setAddItemFocus(adding)
        }
        .onChange(of: decksModel.selectedScope) { _, _ in
            selectedItemID = nil
            Task { await reloadScope() }
        }
        .onAppear {
            AppStartupTrace.mark("content_appeared")
            if !decksModel.needsInitialLoad, !itemsModel.needsInitialLoad {
                AppStartupTrace.mark("home_ready")
            }
        }
        .task {
            await refreshLibrary()
#if DEBUG
            await openTestingTransfersIfRequested()
            openTestingInitialRouteIfRequested()
#else
            if AppDatabase.isTesting,
               ProcessInfo.processInfo.environment["NEOANKI_TEST_INITIAL_ROUTE"] == "browse" {
                openBrowse()
            }
#endif
        }
        .task {
            await vocabularyLibraryModel.load()
        }
        .task {
            await trackDueCounts()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app can cross any amount of time, including a
            // study day rollover, so the counts are re-read before they are read.
            guard phase == .active else { return }
            Task { await refreshCounts() }
        }
        .fileImporter(
            isPresented: $isChoosingImportFile,
            allowedContentTypes: [.json, .commaSeparatedText],
            allowsMultipleSelection: false,
            onCompletion: handleImportFile
        )
        .sheet(isPresented: importPresentation) {
            if let importModel {
                ImportView(
                    model: importModel,
                    itemTypes: itemsModel.itemTypes,
                    scope: decksModel.studyScope,
                    onCancel: { isShowingImport = false },
                    onImported: finishImport
                )
            }
        }
        .sheet(isPresented: deckBuilderPresentation) {
            DeckBuilderSheet(
                registry: deckBuilderRegistry,
                context: deckBuilderContext,
                isImporting: portableDeckTransfer.isBusy,
                onGenerated: importGeneratedDeck,
                onCancel: { isShowingDeckBuilder = false }
            )
        }
        .sheet(isPresented: vocabularyPacksPresentation) {
            VocabularyPacksView(
                model: vocabularyLibraryModel,
                onImport: openVocabularyPackImport,
                onDone: { isShowingVocabularyPacks = false }
            )
        }
        .sheet(isPresented: vocabularyBuilderPresentation) {
            if let destination = selectedVocabularyDestination {
                VocabularyDeckBuilderView(
                    installedPacks: vocabularyLibraryModel.installedPacks,
                    destinationDeck: destination,
                    onImported: importGeneratedVocabulary,
                    onCancel: { isAddingFromVocabulary = false }
                )
                .frame(minWidth: 640, minHeight: 620)
            }
        }
        .sheet(isPresented: $schedulingModel.isShowingSettings) {
            SchedulingSettingsView(model: schedulingModel) {
                // A new rollover redraws the day's budget, which is a count
                // change across every scope and nothing more.
                await refreshCounts()
            }
        }
        .sheet(isPresented: syncIssuesPresentation) {
            NavigationStack {
                SyncIssuesView(issues: appSession.syncIssues)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { appSession.dismissPresentation(ifMatching: .syncIssues) }
                        }
                    }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .alert(item: $importNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $portableDeckTransfer.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $vocabularyLibraryModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Item Type Conflict",
            isPresented: Binding(
                get: { portableDeckTransfer.conflictingSource != nil },
                set: { if !$0 { portableDeckTransfer.cancelConflict() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use Matching Local Type") {
                resolvePortableDeckConflict(using: .useMatchingSchema)
            }
            .accessibilityIdentifier("portableDeckConflictUseLocal")
            Button("Import as New Type") {
                resolvePortableDeckConflict(using: .importAsDistinctRevision)
            }
            .accessibilityIdentifier("portableDeckConflictImportNew")
            Button("Cancel", role: .cancel) {
                portableDeckTransfer.cancelConflict()
            }
            .accessibilityIdentifier("portableDeckConflictCancel")
        } message: {
            Text(
                "This deck carries a different revision of an item type already in your library. "
                    + "You can reuse an identical local schema, keep both revisions, or cancel."
            )
        }
        .focusedSceneValue(\.studyCommandHandlers, studyCommandHandlers)
        .focusedSceneValue(\.libraryCommandHandlers, libraryCommandHandlers)
    }

    private var windowTitle: String {
        if isStudying { return "Study" }
        if isManagingTemplates { return "Item Types" }
        if isAddingItem { return "Add Item" }
        return "NeoAnki2"
    }

    private func updateRoute(
        active: Bool,
        route: AppRoute,
        matchingStudy: Bool = false
    ) {
        if active {
            appSession.route = route
            return
        }
        if matchingStudy {
            if case .study = appSession.route { appSession.route = .scopeHome }
        } else if appSession.route == route {
            appSession.route = .scopeHome
        }
    }

    private func updatePresentation(active: Bool, presentation: AppPresentation) {
        if active {
            appSession.show(presentation)
        } else {
            appSession.dismissPresentation(ifMatching: presentation)
        }
    }

    private var libraryCommandHandlers: LibraryCommandHandlers {
        LibraryCommandHandlers(
            openAddItem: { openAddItem() },
            openImport: { openImport() },
            openPortableDeckImport: openPortableDeckImport,
            openPortableDeckExport: { openPortableDeckExport() },
            openVocabularyPackImport: openVocabularyPackImport,
            openVocabularyPacks: { isShowingVocabularyPacks = true },
            openAddFromVocabulary: { isAddingFromVocabulary = true },
            openDeckBuilder: { isShowingDeckBuilder = true },
            openTemplates: { openTemplates() },
            openBrowse: { openBrowse() },
            toggleAnswerColumn: { browseShowsAnswerColumn.toggle() },
            showSidebar: { columnVisibility = .all },
            isAnswerColumnVisible: browseShowsAnswerColumn,
            canToggleAnswerColumn: isBrowsing,
            canAddItem: !itemsModel.itemTypes.isEmpty
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && !isShowingImport
                && !isShowingDeckBuilder
                && !isShowingVocabularyPacks
                && !isAddingFromVocabulary,
            canImport: !itemsModel.isLoading
                && !itemsModel.itemTypes.isEmpty
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && !isShowingImport
                && !isShowingDeckBuilder
                && !isShowingVocabularyPacks
                && !isAddingFromVocabulary,
            canImportPortableDeck: canTransferPortableDeck,
            canExportPortableDeck: canTransferPortableDeck && decksModel.selectedDeckID != nil,
            canImportVocabularyPack: canUseVocabularyUI,
            canOpenVocabularyPacks: canUseVocabularyUI,
            canAddFromVocabulary: canUseVocabularyUI
                && decksModel.selectedDeckID != nil
                && !vocabularyLibraryModel.installedPacks.isEmpty,
            canOpenDeckBuilder: canTransferPortableDeck && !deckBuilderRegistry.features.isEmpty,
            canOpenTemplates: !isStudying && !isManagingTemplates && !isAddingItem,
            canBrowse: !isBrowsing
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && itemsModel.scopeSummary.itemCount > 0
        )
    }

    private var canTransferPortableDeck: Bool {
        !portableDeckTransfer.isBusy
            && !testingForcePortableBusy
            && !itemsModel.isLoading
            && !decksModel.isLoading
            && !isStudying
            && !isManagingTemplates
            && !isAddingItem
            && !isShowingImport
            && !isShowingDeckBuilder
            && !isShowingVocabularyPacks
            && !isAddingFromVocabulary
    }

    private var canUseVocabularyUI: Bool {
        !vocabularyLibraryModel.isImporting
            && !itemsModel.isLoading
            && !decksModel.isLoading
            && !isStudying
            && !isManagingTemplates
            && !isAddingItem
            && !isShowingImport
            && !isShowingDeckBuilder
            && !isShowingVocabularyPacks
            && !isAddingFromVocabulary
    }

    private var selectedVocabularyDestination: DeckBuilderDeckOption? {
        guard let deckID = decksModel.selectedDeckID,
              let summary = decksModel.summaries.first(where: { $0.id == deckID })
        else { return nil }
        return DeckBuilderDeckOption(id: deckID, name: summary.name)
    }

    private var testingForcePortableBusy: Bool {
#if DEBUG
        portableDeckTransfer.testingForceBusy
            || (
                AppDatabase.isTesting
                    && testingEnvironment["NEOANKI_TEST_PORTABLE_BUSY"] == "1"
            )
#else
        portableDeckTransfer.testingForceBusy
#endif
    }

    private var deckBuilderContext: DeckBuilderHostContext {
        DeckBuilderHostContext(
            rootDecks: decksModel.summaries
                .filter { $0.parentID == nil }
                .map { DeckBuilderDeckOption(id: $0.id, name: $0.name) }
        )
    }

    private var studyCommandHandlers: StudyCommandHandlers {
        if isStudying, let studyModel {
            return StudyCommandHandlers(
                startStudy: nil,
                requestEndSession: { endSessionTrigger = true },
                editCurrentCard: { isEditingStudyCard = true },
                grade: { rating in
                    Task { await studyModel.grade(rating) }
                },
                undoLastGrade: {
                    Task { await studyModel.undoLastGrade() }
                },
                canStartStudy: false,
                canEndSession: !isEditingStudyCard,
                canEditCurrentCard: studyModel.currentCard != nil
                    && !studyModel.isGrading
                    && !studyModel.isPreparingQueue
                    && !isEditingStudyCard,
                canGrade: studyModelCanGrade(studyModel),
                canUndoLastGrade: studyModel.canUndoLastGrade
                    && !studyModel.isGrading
                    && !isEditingStudyCard
            )
        }

        return StudyCommandHandlers(
            startStudy: { startStudy() },
            requestEndSession: nil,
            editCurrentCard: nil,
            grade: nil,
            undoLastGrade: nil,
            canStartStudy: itemsModel.dueCount > 0 && !isStudying,
            canEndSession: false,
            canEditCurrentCard: false,
            canGrade: false,
            canUndoLastGrade: false
        )
    }

    private func studyModelCanGrade(_ studyModel: StudyModel) -> Bool {
        guard let card = studyModel.currentCard else { return false }
        return studyModel.isAnswerRevealed
            && !studyModel.isGrading
            && !studyModel.isPreparingQueue
            && !isEditingStudyCard
            && StudySupport.isSupportedInteraction(card.template.interaction)
    }

    @ViewBuilder
    private var detail: some View {
        if isManagingTemplates, let templatesModel {
            TemplatesView(model: templatesModel) {
                await reloadScope()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isStudying, let studyModel {
            StudyView(
                model: studyModel,
                itemsModel: itemsModel,
                decksModel: decksModel,
                scope: studyScope,
                mediaStore: itemsModel.mediaStore,
                endSessionTrigger: $endSessionTrigger,
                isEditingCard: $isEditingStudyCard
            ) {
                endStudy()
            }
        } else if isAddingItem {
            NavigationStack {
                AddItemView(model: itemsModel, decksModel: decksModel) {
                    closeAddItem()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.detailBackground)
        } else if let selectedItemID,
                  let item = itemsModel.items.first(where: { $0.id == selectedItemID }) {
            NavigationStack {
                ItemDetailView(
                    model: itemsModel,
                    decksModel: decksModel,
                    scope: decksModel.studyScope,
                    summary: item,
                    onBack: { self.selectedItemID = nil },
                    onDeleted: {
                        self.selectedItemID = nil
                        // Deleting from the detail pane retires that item's cards,
                        // which the sidebar was counting.
                        Task { await refreshCounts() }
                    },
                    onSaved: { Task { await refreshCounts() } }
                )
            }
        } else if isBrowsing {
            ItemBrowserView(
                itemsModel: itemsModel,
                decksModel: decksModel,
                showsAnswerColumn: $browseShowsAnswerColumn,
                scope: decksModel.studyScope,
                onOpenItem: { selectedItemID = $0 },
                onAddItem: { openAddItem() },
                onStudy: { startStudy() },
                onDone: { closeBrowse() },
                onReady: { AppStartupTrace.mark("browse_ready") }
            )
        } else {
            ScopeHomeView(
                itemsModel: itemsModel,
                scope: decksModel.studyScope,
                onStudy: { startStudy() },
                onBrowse: { openBrowse() },
                onAddItem: { openAddItem() },
                onAddFromVocabulary: selectedVocabularyDestination != nil
                    && !vocabularyLibraryModel.installedPacks.isEmpty
                    ? { isAddingFromVocabulary = true }
                    : nil,
                onDeleteAllUnassigned: {
                    Task {
                        _ = await itemsModel.deleteAllUnassigned(scope: decksModel.studyScope)
                        await refreshLibrary(forceRefresh: true)
                    }
                }
            )
        }
    }

    private func openBrowse() {
        selectedItemID = nil
        let scope = decksModel.studyScope
        guard itemsModel.needsBrowseLoad else {
            isBrowsing = true
            return
        }
        itemsModel.beginBrowseLoad()
        isBrowsing = true
        Task {
            await itemsModel.load(scope: scope)
        }
    }

    private func closeBrowse() {
        isBrowsing = false
        itemsModel.searchText = ""
    }

    private func openAddItem() {
        selectedItemID = nil
        itemsModel.addItemDeckID = decksModel.defaultDeckIDForNewItem
        isAddingItem = true
    }

    private func openImport() {
        importModel = ImportModel(itemsModel: itemsModel)
        isChoosingImportFile = true
    }

    private func openVocabularyPackImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Offline Vocabulary Pack"
        panel.prompt = "Import Pack"
        panel.message = "Select a local .neovocab directory. NeoAnki will validate and copy it."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task { _ = await vocabularyLibraryModel.importPack(from: source) }
    }

    @MainActor
    private func importGeneratedVocabulary(_ generated: GeneratedDeckBundle) async throws -> Int {
        defer { generated.cleanup() }
        guard let destinationDeckID = generated.destinationDeckID else {
            throw VocabularyDeckBuilderError.missingDestinationDeck
        }
        let result = try await AuthoredDeck.importItems(
            from: generated.bundleURL,
            into: itemsModel.store,
            deckID: destinationDeckID
        )
        let now = Date.now
        await decksModel.load(asOf: now)
        decksModel.selectedScope = .deck(destinationDeckID)
        itemsModel.invalidateItemTypes()
        await reloadScope(asOf: now)
        await templatesModel?.load()
        return result.itemCount
    }

#if DEBUG
    private func openTestingTransfersIfRequested() async {
        guard AppDatabase.isTesting else { return }
        let environment = testingEnvironment.isEmpty
            ? ProcessInfo.processInfo.environment
            : testingEnvironment

        if let importPath = environment["NEOANKI_TEST_IMPORT_PATH"], !importPath.isEmpty {
            let source = URL(fileURLWithPath: importPath)
            guard let accessible = copyTestingTransferFile(source) else { return }
            importModel = ImportModel(itemsModel: itemsModel)
            guard let importModel, await importModel.selectFile(accessible) else { return }
            isShowingImport = true
            return
        }

        if let portablePath = environment["NEOANKI_TEST_PORTABLE_IMPORT_PATH"], !portablePath.isEmpty {
            let source = URL(fileURLWithPath: portablePath)
            guard let accessible = copyTestingTransferFile(source) else { return }
            if let imported = await portableDeckTransfer.importDeck(from: accessible) {
                await refreshAfterPortableDeckImport(imported)
            }
        }
    }

    private func openTestingInitialRouteIfRequested() {
        guard AppDatabase.isTesting else { return }
        switch testingInitialRoute {
        case .library, .importSheet:
            break
        case .browse:
            openBrowse()
        case .addItem:
            openAddItem()
        case .templates:
            openTemplates()
        case .study:
            startStudy()
        }
    }
#endif

    private func copyTestingTransferFile(_ source: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-test-transfer-\(UUID().uuidString)")
            .appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return destination
        } catch {
            return nil
        }
    }

    private func handleImportFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                guard let importModel, await importModel.selectFile(url) else {
                    importNotice = ImportNotice(
                        title: "Could Not Import File",
                        message: importModel?.errorMessage ?? "Choose a JSON or CSV file."
                    )
                    return
                }
                isShowingImport = true
            }
        case let .failure(error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            importNotice = ImportNotice(
                title: "Could Not Open File",
                message: "NeoAnki2 couldn’t open the selected file. Try choosing it again."
            )
        }
    }

    private func finishImport(_ count: Int) {
        isShowingImport = false
        let noun = count == 1 ? "item" : "items"
        importNotice = ImportNotice(
            title: "Import Complete",
            message: "\(count) \(noun) imported. Importing the same file again will create duplicates."
        )
        Task {
            let now = Date.now
            await decksModel.load(asOf: now)
        }
    }

    private func openPortableDeckImport() {
        switch PortableDeckImportSelection.choose() {
        case .cancelled:
            return
        case .invalidSelection:
            portableDeckTransfer.notice = PortableDeckTransferNotice(
                title: "Could Not Import Deck",
                message: "Choose a .neoanki folder or a .neodeck file."
            )
        case let .selected(source):
            handlePortableDeckFile(.success([source]))
        }
    }

    private func handlePortableDeckFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let source = urls.first else { return }
            Task {
                guard let imported = await portableDeckTransfer.importDeck(from: source) else {
                    return
                }
                await refreshAfterPortableDeckImport(imported)
            }
        case let .failure(error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            portableDeckTransfer.notice = PortableDeckTransferNotice(
                title: "Could Not Open Deck",
                message: "NeoAnki2 couldn’t open the selected deck. Try choosing it again."
            )
        }
    }

    private func importGeneratedDeck(_ generated: GeneratedDeckBundle) {
        Task {
            defer { generated.cleanup() }
            guard let imported = await portableDeckTransfer.importDeck(from: generated.bundleURL) else {
                return
            }
            if let destinationDeckID = generated.destinationDeckID,
               let importedRootID = imported.deckIDs.first {
                do {
                    var importedRoot = try await itemsModel.store.deck(id: importedRootID)
                    importedRoot.parentID = destinationDeckID
                    try await itemsModel.store.updateDeck(importedRoot)
                } catch {
                    portableDeckTransfer.notice = PortableDeckTransferNotice(
                        title: "Deck Imported at Top Level",
                        message: "The poem was imported, but its selected parent deck was unavailable."
                    )
                }
            }
            await refreshAfterPortableDeckImport(imported)
            isShowingDeckBuilder = false
        }
    }

    private func refreshAfterPortableDeckImport(_ result: PortableDeckImportResult) async {
        let now = Date.now
        await decksModel.load(asOf: now)
        if let rootID = result.deckIDs.first,
           decksModel.summaries.contains(where: { $0.id == rootID }) {
            decksModel.selectedScope = .deck(rootID)
        }
        itemsModel.invalidateItemTypes()
        await reloadScope(asOf: now)
        await templatesModel?.load()
    }

    private func resolvePortableDeckConflict(
        using resolution: PortableDeckTypeConflictResolution
    ) {
        Task {
            guard let imported = await portableDeckTransfer.resolveConflict(using: resolution) else {
                return
            }
            await refreshAfterPortableDeckImport(imported)
        }
    }

    private func openPortableDeckExport() {
        guard let deckID = decksModel.selectedDeckID else { return }
#if DEBUG
        if AppDatabase.isTesting,
           let exportPath = testingEnvironment["NEOANKI_TEST_PORTABLE_EXPORT_PATH"],
           !exportPath.isEmpty {
            let destination = URL(fileURLWithPath: exportPath)
            Task {
                await portableDeckTransfer.exportDeck(id: deckID, to: destination)
            }
            return
        }
#endif
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.neoDeck]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let deckName = decksModel.deckName(for: deckID) ?? "Deck"
        panel.nameFieldStringValue = "\(safeExportFileName(deckName)).\(PortableDeck.fileExtension)"
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != PortableDeck.fileExtension {
            destination.appendPathExtension(PortableDeck.fileExtension)
        }
        Task {
            await portableDeckTransfer.exportDeck(id: deckID, to: destination)
        }
    }

    private func safeExportFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = name.components(separatedBy: invalid)
        let safe = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Deck" : safe
    }

    private func closeAddItem() {
        isAddingItem = false
        columnVisibility = .all
        // A new item changes deck counts too, so the sidebar reloads with it.
        Task { await decksModel.refreshCounts() }
    }

    private func reloadScope(asOf now: Date = .now) async {
        let scope = decksModel.studyScope
        itemsModel.setCachedScope(scope)
        itemsModel.addItemDeckID = decksModel.defaultDeckIDForNewItem
        if isBrowsing {
            await itemsModel.load(scope: scope, asOf: now)
        } else {
            await itemsModel.loadHome(scope: scope, asOf: now)
        }
    }

    /// Reloads decks and the selected scope against one instant. Two separate
    /// `.now` reads are what let the sidebar total and the detail pane disagree
    /// about how many cards are due.
    private func refreshLibrary(forceRefresh: Bool = false) async {
        if !forceRefresh,
           !decksModel.needsInitialLoad,
           !itemsModel.needsInitialLoad {
            AppStartupTrace.mark("home_ready")
            return
        }
        let now = Date.now
        if decksModel.needsInitialLoad || itemsModel.needsInitialLoad {
            let scope = decksModel.studyScope
            do {
                let snapshot = try await itemsModel.store.coldLibraryHomeSnapshot(
                    scope: scope.filter,
                    asOf: now
                )
                decksModel.applyColdHomeSnapshot(snapshot)
                itemsModel.setCachedScope(scope)
                itemsModel.addItemDeckID = decksModel.defaultDeckIDForNewItem
                itemsModel.applyColdHomeSnapshot(snapshot, scope: scope)
                AppStartupTrace.mark("home_ready")
                return
            } catch {
                // Preserve the established model-owned error presentation.
            }
        }
        await decksModel.loadOrRefresh(asOf: now)
        await reloadScope(asOf: now)
        AppStartupTrace.mark("home_ready")
    }

    private func refreshAfterStudy(studiedItemIDs: Set<UUID>) async {
        let now = Date.now
        await decksModel.refreshCounts(asOf: now)
        await itemsModel.refreshSchedules(for: studiedItemIDs, asOf: now)
        // Last, and only after the visible surfaces are true: fitting is the
        // one thing here the learner is not waiting to see. New parameters
        // affect grades from here on, not any due time already on screen.
        await schedulingModel.optimizeIfNeeded()
    }

    /// Re-reads only what is due, on both surfaces, against one instant. This is
    /// the path for changes the learner did not ask to see — a card falling due,
    /// a save elsewhere — so it revises numbers in place and never reloads.
    private func refreshCounts() async {
        let now = Date.now
        await decksModel.refreshCounts(asOf: now)
        await itemsModel.refreshCounts(asOf: now)
    }

    /// Keeps the due counts true while the window just sits there. Cards come
    /// back on a schedule, so this waits for the next one rather than polling on
    /// a fixed beat: precise when something is about to fall due, near-free when
    /// nothing is.
    ///
    /// It runs in every mode. Study reads its own queue and is forbidden from
    /// showing these numbers, and the editors cover them, so a revision there is
    /// invisible rather than wrong — and skipping it would mean trusting flags
    /// this long-lived task cannot see change.
    private func trackDueCounts() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(dueCountRefreshDelay))
            guard !Task.isCancelled else { return }
            await refreshCounts()
        }
    }

    private var dueCountRefreshDelay: TimeInterval {
        // The ceiling bounds how stale decks outside the selected scope can get.
        // The floor keeps an already-overdue card from spinning this loop.
        let ceiling: TimeInterval = 60
        guard let nextStudyAt = itemsModel.scopeSummary.nextStudyAt else { return ceiling }
        return min(max(nextStudyAt.timeIntervalSinceNow, 5), ceiling)
    }

    private func startStudy() {
        studyScope = decksModel.studyScope
        studyModel = StudyModel(store: itemsModel.store)
        isStudying = true
    }

    private func endStudy() {
        isStudying = false
        isEditingStudyCard = false
        let studiedItemIDs = studyModel?.reviewedItemIDs ?? []
        studyModel = nil
        Task {
            await refreshAfterStudy(studiedItemIDs: studiedItemIDs)
        }
    }

    private func closeItemTypes() {
        Task {
            itemsModel.invalidateItemTypes()
            await reloadScope()
            isManagingTemplates = false
            columnVisibility = .all
        }
    }

    private func openTemplates() {
        if templatesModel == nil {
            templatesModel = TemplatesModel(store: itemsModel.store)
        }
        selectedItemID = nil
        isManagingTemplates = true
        setTemplatesFocus(true)
    }

    private func setAddItemFocus(_ focused: Bool) {
        let update = {
            columnVisibility = focused ? .detailOnly : .all
        }
        if reduceMotion || AppDatabase.isTesting {
            update()
        } else {
            withAnimation(.easeOut(duration: DesignSystem.revealDuration)) {
                update()
            }
        }
    }

    private func setTemplatesFocus(_ focused: Bool) {
        let update = {
            columnVisibility = focused ? .detailOnly : .all
        }
        if reduceMotion || AppDatabase.isTesting {
            update()
        } else {
            withAnimation(.easeOut(duration: DesignSystem.revealDuration)) {
                update()
            }
        }
    }

    private func setStudyFocus(_ focused: Bool) {
        let update = {
            columnVisibility = focused ? .detailOnly : .all
        }
        if reduceMotion || AppDatabase.isTesting {
            update()
        } else {
            withAnimation(.easeOut(duration: DesignSystem.revealDuration)) {
                update()
            }
        }
    }
}
