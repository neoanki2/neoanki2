import NeoAnkiCore
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ItemsModel
    @State private var isAddingItem = false
    @State private var isStudying = false
    @State private var studyModel: StudyModel?
    @State private var selectedItemID: SavedItemSummary.ID?
    @State private var endSessionTrigger = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: DesignSystem.sidebarMin,
                    ideal: DesignSystem.sidebarIdeal,
                    max: DesignSystem.sidebarMax
                )
        } detail: {
            detail
        }
        .tint(DesignSystem.accent(for: colorScheme))
        .navigationTitle(isStudying ? "Study" : "NeoAnki2")
        .toolbar {
            if !isStudying {
                ToolbarItem(placement: .automatic) {
                    Button {
                        startStudy()
                    } label: {
                        if model.dueCount > 0 {
                            Label("Study", systemImage: "play.fill")
                                .badge(model.dueCount)
                        } else {
                            Label("Study", systemImage: "play.fill")
                        }
                    }
                    .disabled(model.dueCount == 0)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .accessibilityIdentifier("studyButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Item", systemImage: "plus") {
                        isAddingItem = true
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("addItemToolbar")
                }
            }
        }
        .onChange(of: isStudying) { _, studying in
            setStudyFocus(studying)
        }
        .sheet(isPresented: $isAddingItem) {
            NavigationStack {
                AddItemView(model: model)
            }
        }
        .task {
            await model.load()
        }
        .focusedSceneValue(\.studyCommandHandlers, studyCommandHandlers)
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
            canStartStudy: model.dueCount > 0 && !isStudying,
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
    private var sidebar: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage, !model.isLoading {
                ErrorBanner(message: errorMessage)
            }

            Group {
                if model.isLoading {
                    ProgressView("Loading items…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.items.isEmpty {
                    SidebarEmptyState(
                        title: "No Items Yet",
                        message: "Add an item to generate study cards.",
                        systemImage: "rectangle.stack.badge.plus",
                        actionTitle: "Add Item",
                        action: { isAddingItem = true },
                        actionIdentifier: "addItemEmptyState"
                    )
                } else {
                    List(model.items, selection: $selectedItemID) { item in
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.rowTight) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.subtitle)
                                .foregroundStyle(.secondary)
                            Text("\(item.cardCount) cards · \(item.itemTypeName)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(item.title), \(item.subtitle), \(item.cardCount) cards, \(item.itemTypeName)"
                        )
                        .accessibilityIdentifier("itemRow-\(item.title)")
                    }
                }
            }
        }
        .background(DesignSystem.sidebarBackground)
        .navigationTitle("Items")
    }

    @ViewBuilder
    private var detail: some View {
        if isStudying, let studyModel {
            StudyView(model: studyModel, endSessionTrigger: $endSessionTrigger) {
                endStudy()
            }
        } else if let selectedItemID,
                  let item = model.items.first(where: { $0.id == selectedItemID }) {
            ItemDetailView(summary: item, store: model.store)
        } else {
            studyPrompt
        }
    }

    private var studyPrompt: some View {
        ContentUnavailableView {
            Label("Ready to Study", systemImage: "text.book.closed")
        } description: {
            if model.dueCount > 0 {
                Text("You have \(model.dueCount) due cards. Start a session from the toolbar.")
            } else if model.items.isEmpty {
                Text("Add your first item to begin.")
            } else {
                Text("Select an item from the sidebar, or study when cards are due.")
            }
        } actions: {
            if model.dueCount > 0 {
                Button("Study") {
                    startStudy()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("studyDetailPrompt")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.detailBackground)
    }

    private func startStudy() {
        studyModel = StudyModel(store: model.store)
        isStudying = true
    }

    private func endStudy() {
        isStudying = false
        studyModel = nil
        Task { await model.load() }
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
