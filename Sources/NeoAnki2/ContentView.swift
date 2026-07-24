import NeoAnkiCore
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var itemsModel: ItemsModel
    @Bindable var decksModel: DecksModel
    @State private var isAddingItem = false
    @State private var isManagingTemplates = false
    @State private var isStudying = false
    @State private var studyModel: StudyModel?
    @State private var studyScope: StudyScope = .allDecks
    @State private var templatesModel: TemplatesModel?
    @State private var selectedItemID: SavedItemSummary.ID?
    @State private var endSessionTrigger = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
            } else if !isStudying && !isAddingItem {
                ToolbarItem(placement: .primaryAction) {
                    Button("Item Types", systemImage: "square.grid.2x2") {
                        openTemplates()
                    }
                    .accessibilityIdentifier("templatesToolbar")
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
            Task { await reloadScope() }
        }
        .task {
            await decksModel.load()
            await reloadScope()
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
            openTemplates: { openTemplates() },
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
                canStartStudy: false,
                canEndSession: true,
                canShowAnswer: studyModelCanShowAnswer(studyModel),
                canGrade: studyModelCanGrade(studyModel)
            )
        }

        return StudyCommandHandlers(
            startStudy: { startStudy() },
            requestEndSession: nil,
            showAnswer: nil,
            grade: nil,
            canStartStudy: itemsModel.dueCount > 0 && !isStudying,
            canEndSession: false,
            canShowAnswer: false,
            canGrade: false
        )
    }

    private func studyModelCanShowAnswer(_ studyModel: StudyModel) -> Bool {
        guard let card = studyModel.currentCard else { return false }
        return !studyModel.isAnswerRevealed
            && !studyModel.isLoading
            && !studyModel.isFinished
            && card.template.interaction == .reveal
            && !cardHasUnsupportedContent(card)
    }

    private func studyModelCanGrade(_ studyModel: StudyModel) -> Bool {
        guard let card = studyModel.currentCard else { return false }
        return studyModel.isAnswerRevealed
            && !studyModel.isGrading
            && card.template.interaction == .reveal
            && !cardHasUnsupportedContent(card)
    }

    private func cardHasUnsupportedContent(_ card: DueCard) -> Bool {
        let values = SideContent.values(for: card.template.prompt, from: card.item)
            + SideContent.values(for: card.template.answer, from: card.item)
        return values.contains { value in
            switch value {
            case .media, .cloze:
                true
            default:
                false
            }
        }
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
