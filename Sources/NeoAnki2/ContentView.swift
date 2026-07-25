import NeoAnkiCore
import SwiftUI
import UniformTypeIdentifiers

private struct ImportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var itemsModel: ItemsModel
    @Bindable var decksModel: DecksModel
    @Bindable var schedulingModel: SchedulingModel
    @State private var isAddingItem = false
    @State private var isManagingTemplates = false
    @State private var isStudying = false
    @State private var studyModel: StudyModel?
    @State private var studyScope: StudyScope = .allDecks
    @State private var templatesModel: TemplatesModel?
    @State private var selectedItemID: SavedItemSummary.ID?
    @State private var endSessionTrigger = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var importModel: ImportModel?
    @State private var isChoosingImportFile = false
    @State private var isShowingImport = false
    @State private var importNotice: ImportNotice?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DeckSidebarView(
                decksModel: decksModel,
                selection: $decksModel.selectedScope
            )
            .navigationSplitViewColumnWidth(
                min: DesignSystem.sidebarMin,
                ideal: DesignSystem.sidebarIdeal,
                max: DesignSystem.sidebarMax
            )
        } detail: {
            detail
        }
        .tint(DesignSystem.accent(for: colorScheme))
        .navigationTitle(windowTitle)
        .toolbar {
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
            await decksModel.load()
            await reloadScope()
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
        .alert(item: $importNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .focusedSceneValue(\.studyCommandHandlers, studyCommandHandlers)
        .focusedSceneValue(\.libraryCommandHandlers, libraryCommandHandlers)
        .alert(
            schedulingModel.notice?.title ?? "Scheduling",
            isPresented: Binding(
                get: { schedulingModel.notice != nil },
                set: { if !$0 { schedulingModel.notice = nil } }
            )
        ) {
            Button("OK") {
                schedulingModel.notice = nil
            }
        } message: {
            Text(schedulingModel.notice?.message ?? "")
        }
    }

    private var windowTitle: String {
        if isStudying { return "Study" }
        if isManagingTemplates { return "Item Types" }
        if isAddingItem { return "Add Item" }
        return "NeoAnki2"
    }

    private var libraryCommandHandlers: LibraryCommandHandlers {
        LibraryCommandHandlers(
            openImport: { openImport() },
            openTemplates: { openTemplates() },
            canImport: !itemsModel.isLoading
                && !itemsModel.itemTypes.isEmpty
                && !isStudying
                && !isManagingTemplates
                && !isAddingItem
                && !isShowingImport,
            canOpenTemplates: !isStudying && !isManagingTemplates && !isAddingItem
        )
    }

    private var studyCommandHandlers: StudyCommandHandlers {
        if isStudying, let studyModel {
            return StudyCommandHandlers(
                startStudy: nil,
                requestEndSession: { endSessionTrigger = true },
                showAnswer: {
                    StudyAnimation.revealAnswer(reduceMotion: reduceMotion) {
                        studyModel.revealAnswer()
                    }
                },
                grade: { rating in
                    Task { await studyModel.grade(rating) }
                },
                undoLastGrade: {
                    Task { await studyModel.undoLastGrade() }
                },
                canStartStudy: false,
                canEndSession: true,
                canShowAnswer: studyModelCanShowAnswer(studyModel),
                canGrade: studyModelCanGrade(studyModel),
                canUndoLastGrade: studyModel.canUndoLastGrade && !studyModel.isGrading
            )
        }

        return StudyCommandHandlers(
            startStudy: { startStudy() },
            requestEndSession: nil,
            showAnswer: nil,
            grade: nil,
            undoLastGrade: nil,
            canStartStudy: itemsModel.dueCount > 0 && !isStudying,
            canEndSession: false,
            canShowAnswer: false,
            canGrade: false,
            canUndoLastGrade: false
        )
    }

    private func studyModelCanShowAnswer(_ studyModel: StudyModel) -> Bool {
        guard let card = studyModel.currentCard else { return false }
        return !studyModel.isAnswerRevealed
            && !studyModel.isLoading
            && !studyModel.isFinished
            && StudySupport.isSupportedInteraction(card.template.interaction)
    }

    private func studyModelCanGrade(_ studyModel: StudyModel) -> Bool {
        guard let card = studyModel.currentCard else { return false }
        return studyModel.isAnswerRevealed
            && !studyModel.isGrading
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
                scope: studyScope,
                mediaStore: itemsModel.mediaStore,
                endSessionTrigger: $endSessionTrigger
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
                    summary: item
                ) {
                    self.selectedItemID = nil
                }
            }
        } else {
            DeckDetailView(
                itemsModel: itemsModel,
                decksModel: decksModel,
                scope: decksModel.studyScope,
                selectedItemID: $selectedItemID,
                onAddItem: { openAddItem() },
                onStudy: { startStudy() }
            )
        }
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

    private func handleImportFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            guard let importModel, importModel.selectFile(url) else {
                importNotice = ImportNotice(
                    title: "Could Not Import File",
                    message: importModel?.errorMessage ?? "Choose a JSON or CSV file."
                )
                return
            }
            isShowingImport = true
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
            await decksModel.load()
        }
    }

    private func closeAddItem() {
        isAddingItem = false
        columnVisibility = .all
        Task { await reloadScope() }
    }

    private func reloadScope() async {
        let scope = decksModel.studyScope
        itemsModel.setCachedScope(scope)
        itemsModel.addItemDeckID = decksModel.defaultDeckIDForNewItem
        await itemsModel.load(scope: scope)
    }

    private func startStudy() {
        studyScope = decksModel.studyScope
        studyModel = StudyModel(store: itemsModel.store)
        isStudying = true
    }

    private func endStudy() {
        isStudying = false
        studyModel = nil
        Task {
            await decksModel.load()
            await reloadScope()
        }
    }

    private func closeItemTypes() {
        Task {
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
