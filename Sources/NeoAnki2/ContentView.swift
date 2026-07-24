import NeoAnkiCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ItemsModel
    @State private var isAddingItem = false
    @State private var isStudying = false
    @State private var studyModel: StudyModel?
    @State private var selectedItemID: SavedItemSummary.ID?
    @State private var endSessionTrigger = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .navigationTitle("NeoAnki2")
        .toolbar {
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
                .disabled(model.dueCount == 0 || isStudying)
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
                    withAnimation(.easeOut(duration: 0.2)) {
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
        Group {
            if model.isLoading {
                ProgressView("Loading items…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView {
                    Label("No Items Yet", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Add an item to generate study cards.")
                } actions: {
                    Button("Add Item") { isAddingItem = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("addItemEmptyState")
                }
            } else {
                List(model.items, selection: $selectedItemID) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.subtitle)
                            .foregroundStyle(.secondary)
                        Text("\(item.cardCount) cards · \(item.itemTypeName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("itemRow-\(item.title)")
                }
            }
        }
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
            itemDetail(item)
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
    }

    private func itemDetail(_ item: SavedItemSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.title2.bold())
            Text(item.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(item.cardCount) cards · \(item.itemTypeName)")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
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
}
