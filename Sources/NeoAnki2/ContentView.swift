import AppKit
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isAddingItem = false
    @State private var isManagingTemplates = false
    @State private var isStudying = false
    @State private var isBrowsing = false
    /// Persisted per user, not per browse session: whether you want to see
    /// answers is a standing preference, not something to rediscover.
    @AppStorage(AppPreferences.browseShowsAnswerColumn) private var browseShowsAnswerColumn = false
    @State private var studyModel: StudyModel?
    @State private var studyScope: StudyScope = .allDecks
    @State private var templatesModel: TemplatesModel?
    @State private var selectedItemID: SavedItemSummary.ID?
    @State private var endSessionTrigger = false
    /// Lives here rather than in `StudyView` because the Study menu opens the
    /// card editor, and every study command has to stand down while it is open:
    /// the grade keys are unmodified, so they would otherwise land in a field.
    @State private var isEditingStudyCard = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var importModel: ImportModel?
    @State private var isChoosingImportFile = false
    @State private var isShowingImport = false
    @State private var importNotice: ImportNotice?
    @State private var portableDeckTransfer: PortableDeckTransferModel
    @State private var isShowingDeckBuilder = false
    private let deckBuilderRegistry: DeckBuilderRegistry

    init(
        itemsModel: ItemsModel,
        decksModel: DecksModel,
        schedulingModel: SchedulingModel,
        deckBuilderRegistry: DeckBuilderRegistry
    ) {
        self.itemsModel = itemsModel
        self.decksModel = decksModel
        self.schedulingModel = schedulingModel
        _portableDeckTransfer = State(
            initialValue: PortableDeckTransferModel(store: itemsModel.store)
        )
        self.deckBuilderRegistry = deckBuilderRegistry
    }

    var body: some View {
        GeometryReader { available in
            interface
                .frame(
                    width: available.size.width,
                    height: available.size.height,
                    alignment: .topLeading
                )
        }
    }

    private var interface: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DeckSidebarView(
                decksModel: decksModel,
                selection: $decksModel.selectedScope,
                onDeleteAllUnassigned: {
                    Task {
                        _ = await itemsModel.deleteAllUnassigned(scope: decksModel.studyScope)
                        await refreshLibrary()
                    }
                },
                onDeckSettingsSaved: {
                    await refreshCounts()
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
            if portableDeckTransfer.isBusy || portableDeckTransfer.testingForceBusy {
                ToolbarItem(placement: .status) {
                    ProgressView("Transferring deck…")
                        .controlSize(.small)
                        .accessibilityIdentifier("portableDeckTransferBusy")
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
        .task {
            await refreshLibrary()
            await openTestingTransfersIfRequested()
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
        .sheet(isPresented: $isShowingImport) {
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
        .sheet(isPresented: $isShowingDeckBuilder) {
            DeckBuilderSheet(
                registry: deckBuilderRegistry,
                context: deckBuilderContext,
                isImporting: portableDeckTransfer.isBusy,
                onGenerated: importGeneratedDeck,
                onCancel: { isShowingDeckBuilder = false }
            )
        }
        .sheet(isPresented: $schedulingModel.isShowingSettings) {
            SchedulingSettingsView(model: schedulingModel) {
                // A new rollover redraws the day's budget, which is a count
                // change across every scope and nothing more.
                await refreshCounts()
            }
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

    private var libraryCommandHandlers: LibraryCommandHandlers {
        LibraryCommandHandlers(
            openAddItem: { openAddItem() },
            openImport: { openImport() },
            openPortableDeckImport: openPortableDeckImport,
            openPortableDeckExport: { openPortableDeckExport() },
            openDeckBuilder: { isShowingDeckBuilder = true },
            openTemplates: { openTemplates() },
            openBrowse: { openBrowse() },
            toggleAnswerColumn: { browseShowsAnswerColumn.toggle() },
            isAnswerColumnVisible: browseShowsAnswerColumn,
            canToggleAnswerColumn: isBrowsing,
            canAddItem: !itemsModel.itemTypes.isEmpty
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && !isShowingImport
                && !isShowingDeckBuilder,
            canImport: !itemsModel.isLoading
                && !itemsModel.itemTypes.isEmpty
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && !isShowingImport
                && !isShowingDeckBuilder,
            canImportPortableDeck: canTransferPortableDeck,
            canExportPortableDeck: canTransferPortableDeck && decksModel.selectedDeckID != nil,
            canOpenDeckBuilder: canTransferPortableDeck && !deckBuilderRegistry.features.isEmpty,
            canOpenTemplates: !isStudying && !isManagingTemplates && !isAddingItem,
            canBrowse: !isBrowsing
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && !itemsModel.items.isEmpty
        )
    }

    private var canTransferPortableDeck: Bool {
        !portableDeckTransfer.isBusy
            && !portableDeckTransfer.testingForceBusy
            && !itemsModel.isLoading
            && !decksModel.isLoading
            && !isStudying
            && !isManagingTemplates
            && !isAddingItem
            && !isShowingImport
            && !isShowingDeckBuilder
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
                onDone: { closeBrowse() }
            )
        } else {
            ScopeHomeView(
                itemsModel: itemsModel,
                scope: decksModel.studyScope,
                onStudy: { startStudy() },
                onBrowse: { openBrowse() },
                onAddItem: { openAddItem() },
                onDeleteAllUnassigned: {
                    Task {
                        _ = await itemsModel.deleteAllUnassigned(scope: decksModel.studyScope)
                        await refreshLibrary()
                    }
                }
            )
        }
    }

    private func openBrowse() {
        selectedItemID = nil
        isBrowsing = true
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

    private func openTestingTransfersIfRequested() async {
        guard AppDatabase.isTesting else { return }
        let environment = ProcessInfo.processInfo.environment

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
        await itemsModel.load(scope: scope, asOf: now)
    }

    /// Reloads decks and the selected scope against one instant. Two separate
    /// `.now` reads are what let the sidebar total and the detail pane disagree
    /// about how many cards are due.
    private func refreshLibrary() async {
        let now = Date.now
        if decksModel.needsInitialLoad || itemsModel.needsInitialLoad {
            let scope = decksModel.studyScope
            do {
                let snapshot = try await itemsModel.store.coldLibrarySnapshot(
                    scope: scope.filter,
                    asOf: now
                )
                decksModel.applyColdSnapshot(snapshot)
                itemsModel.setCachedScope(scope)
                itemsModel.addItemDeckID = decksModel.defaultDeckIDForNewItem
                itemsModel.applyColdSnapshot(snapshot, scope: scope)
                return
            } catch {
                // Preserve the established model-owned error presentation.
            }
        }
        await decksModel.loadOrRefresh(asOf: now)
        await reloadScope(asOf: now)
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
        if reduceMotion {
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
        if reduceMotion {
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
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeOut(duration: DesignSystem.revealDuration)) {
                update()
            }
        }
    }
}
