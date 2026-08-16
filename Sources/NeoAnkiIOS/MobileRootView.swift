import NeoAnkiCore
import NeoAnkiApplication
import NeoAnkiFeatures
import NeoAnkiSharedUI
import SwiftUI

#if os(iOS)
public struct MobileRootView: View {
    @Bindable var model: MobileAppModel
    @State private var vocabularyLibrary: MobileVocabularyLibraryModel

    public init(model: LibraryFeatureModel, vocabularyRootURL: URL) {
        self.model = model
        _vocabularyLibrary = State(initialValue: MobileVocabularyLibraryModel(rootURL: vocabularyRootURL))
    }

    public var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Opening your library…")
            case .ready:
                MobileTabView(model: model, vocabularyLibrary: vocabularyLibrary)
            case let .failed(error):
                ContentUnavailableView {
                    Label("Could Not Open NeoAnki2", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try Again") {
                        Task { await model.bootstrap() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .task { await model.bootstrap() }
    }
}

private struct MobileTabView: View {
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var detailIdentity = UUID()

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(AppSection.allCases) { section in
                        Button {
                            model.section = section
                            detailIdentity = UUID()
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("top-level-\(section.title.lowercased())")
                        .listRowBackground(model.section == section ? Color.accentColor.opacity(0.14) : Color.clear)
                        .accessibilityAddTraits(model.section == section ? .isSelected : [])
                    }
                    .navigationTitle("NeoAnki2")
                } detail: {
                    destination(model.section)
                }
                .navigationSplitViewStyle(.balanced)
                .id(detailIdentity)
            } else {
                TabView(selection: $model.section) {
                    destination(.home)
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(AppSection.home)
                    destination(.library)
                        .tabItem { Label("Library", systemImage: "rectangle.stack") }
                        .tag(AppSection.library)
                    destination(.create)
                        .tabItem { Label("Create", systemImage: "plus.square") }
                        .tag(AppSection.create)
                    destination(.settings)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppSection.settings)
                }
            }
        }
        .fullScreenCover(item: $model.activeStudy) { session in
            StudySessionView(session: session, model: model)
        }
        .onChange(of: model.activeStudy == nil) { _, isDismissed in
            if isDismissed {
                Task { await model.endStudy() }
            }
        }
    }

    @ViewBuilder
    private func destination(_ section: AppSection) -> some View {
        switch section {
        case .home: HomeView(model: model)
        case .library: LibraryView(model: model)
        case .create: CreateHubView(model: model, vocabularyLibrary: vocabularyLibrary)
        case .settings: SettingsView(model: model)
        }
    }
}

private extension AppSection {
    var title: String {
        switch self { case .home: "Home"; case .library: "Library"; case .create: "Create"; case .settings: "Settings" }
    }
    var symbol: String {
        switch self { case .home: "house"; case .library: "rectangle.stack"; case .create: "plus.square"; case .settings: "gearshape" }
    }
}

private struct CreateHubView: View {
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    @State private var isAddingItem = false
    @State private var isAddingDeck = false

    var body: some View {
        NavigationStack {
            List {
                Section("Add") {
                    Button { isAddingItem = true } label: { Label("New Item", systemImage: "rectangle.stack.badge.plus") }
                    Button { isAddingDeck = true } label: { Label("New Deck", systemImage: "folder.badge.plus") }
                }
                Section("Design") {
                    NavigationLink { ItemTypesMobileView(model: model) } label: { Label("Item Types & Templates", systemImage: "square.stack.3d.up") }
                }
                Section("Transfer & Build") {
                    NavigationLink { TransferToolsView(model: model) } label: { Label("Import or Export", systemImage: "arrow.up.arrow.down.square") }
                    NavigationLink { BuilderToolsView(model: model, vocabularyLibrary: vocabularyLibrary) } label: { Label("Deck Builders", systemImage: "hammer") }
                    NavigationLink { VocabularyToolsView(model: vocabularyLibrary) } label: { Label("Vocabulary Packs", systemImage: "books.vertical") }
                }
            }
            .navigationTitle("Create")
            .sheet(isPresented: $isAddingItem) { AddItemView(model: model) }
            .sheet(isPresented: $isAddingDeck) { NewDeckView(model: model) }
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: MobileAppModel
    @AppStorage(StudyPreferences.usesPassFailGrades) private var usesPassFailGrades = false
    @State private var showsSyncConsent = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud Sync") {
                    if model.syncEnabled {
                        Toggle("Sync this device", isOn: Binding(
                            get: { true },
                            set: { value in
                                if !value { Task { await model.setSyncEnabled(false) } }
                            }
                        ))
                    } else {
                        Button("Enable iCloud Sync…") { showsSyncConsent = true }
                    }
                    LabeledContent("Status", value: syncLabel)
                    if !model.syncIssues.isEmpty {
                        NavigationLink("Sync Issues (\(model.syncIssues.count))") { SyncIssuesMobileView(model: model) }
                    }
                    Button("Sync Now") { Task { await model.synchronize() } }
                        .disabled(!model.syncEnabled)
                }
                Section("Daily Reminder") {
                    Toggle("Remind me", isOn: reminderEnabled)
                    DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                        .disabled(!model.reminderSettings.isEnabled)
                    Picker("Scope", selection: reminderScope) {
                        Text("All Decks").tag(ReminderScope.allDecks)
                        ForEach(model.decks) { deck in Text(deck.name).tag(ReminderScope.deck(deck.id)) }
                    }
                    .disabled(!model.reminderSettings.isEnabled)
                }
                Section("Study") {
                    Toggle("Use Fail / Pass grades", isOn: $usesPassFailGrades)
                        .accessibilityIdentifier("usesPassFailGrades")
                    Text("Fail schedules as Again; Pass schedules as Good.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Conceal answers while browsing", isOn: $model.concealsAnswers)
                    NavigationLink("Scheduling") { SchedulingMobileView(model: model) }
                }
                Section("About") {
                    LabeledContent("Data", value: "Stored on this device")
                    Text("NeoAnki2 keeps working offline. iCloud is optional and uses your private CloudKit database.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .alert("Enable iCloud Sync?", isPresented: $showsSyncConsent) {
                Button("Create Backup & Enable") { Task { await model.setSyncEnabled(true) } }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("NeoAnki2 will create a verified local backup, then merge this library with your private iCloud library. Existing content is never replaced wholesale.")
            }
            .alert("Could Not Update Settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private var syncLabel: String {
        switch model.syncStatus {
        case .offline: "Offline"
        case .syncing: "Syncing"
        case .current: "Current"
        case .accountUnavailable: "Account unavailable"
        case .needsAttention: "Needs attention"
        }
    }

    private var reminderEnabled: Binding<Bool> { Binding(
        get: { model.reminderSettings.isEnabled },
        set: { value in var settings = model.reminderSettings; settings.isEnabled = value; updateReminder(settings) }
    ) }
    private var reminderScope: Binding<ReminderScope> { Binding(
        get: { model.reminderSettings.scope },
        set: { value in var settings = model.reminderSettings; settings.scope = value; updateReminder(settings) }
    ) }
    private var reminderTime: Binding<Date> { Binding(
        get: {
            Calendar.current.date(from: DateComponents(hour: model.reminderSettings.hour, minute: model.reminderSettings.minute)) ?? .now
        },
        set: { value in
            let components = Calendar.current.dateComponents([.hour, .minute], from: value)
            var settings = model.reminderSettings
            settings.hour = components.hour ?? 19; settings.minute = components.minute ?? 0
            updateReminder(settings)
        }
    ) }
    private func updateReminder(_ settings: ReminderSettings) {
        Task { do { try await model.setReminderSettings(settings) } catch { errorMessage = MobileAppModel.message(for: error) } }
    }
}

private struct HomeView: View {
    @Bindable var model: MobileAppModel
    @State private var isAddingDeck = false
    @State private var errorMessage: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    DueNowCard(
                        title: "Ready to study",
                        summary: model.allDecksSummary,
                        isWorking: model.isRefreshing || model.isStartingStudy,
                        action: { startStudy(.allDecks) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink(value: MobileScope.allDecks) {
                        ScopeRow(
                            title: "All Decks",
                            subtitle: "Everything in your library",
                            itemCount: model.allDecksSummary.itemCount,
                            dueCount: model.allDecksSummary.dueNow
                        )
                    }

                    ForEach(model.decks) { deck in
                        NavigationLink(value: MobileScope.deck(deck.id)) {
                            ScopeRow(
                                title: deck.name,
                                subtitle: deck.parentID == nil ? "Deck" : "Nested deck",
                                itemCount: deck.itemCount,
                                dueCount: deck.dueCount
                            )
                            .padding(.leading, CGFloat(model.deckDepth(deck)) * 16)
                        }
                    }

                    NavigationLink(value: MobileScope.unassigned) {
                        ScopeRow(
                            title: "Unassigned",
                            subtitle: "Cards without a deck",
                            itemCount: model.unassignedSummary.itemCount,
                            dueCount: model.unassignedSummary.dueNow
                        )
                    }
                } header: {
                    Text("Decks")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .textCase(nil)
                }
            }
            .navigationTitle("NeoAnki2")
            .navigationDestination(for: MobileScope.self) { scope in
                ScopeDetailView(model: model, scope: scope)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Deck", systemImage: "folder.badge.plus") {
                        isAddingDeck = true
                    }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $isAddingDeck) {
                NewDeckView(model: model)
            }
            .alert("Could Not Start Study", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
            .onChange(of: model.route) { _, route in
                if case let .scope(scope) = route { path = NavigationPath([MobileScope(scope)]) }
            }
            .task {
                if case let .scope(scope) = model.route { path = NavigationPath([MobileScope(scope)]) }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func startStudy(_ scope: MobileScope) {
        Task {
            await model.beginStudy(scope: scope)
        }
    }
}

private struct DueNowCard: View {
    let title: String
    let summary: ScopeSummary
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(summary.dueNow, format: .number)
                    .font(.largeTitle.bold())
                    .contentTransition(.numericText())
                Text(summary.dueNow == 1 ? "card due now" : "cards due now")
                    .foregroundStyle(.primary)
            }

            Button(action: action) {
                Label(summary.hasDueCards ? "Start Studying" : "Nothing Due", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!summary.hasDueCards || isWorking)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct ScopeRow: View {
    let title: String
    let subtitle: String
    let itemCount: Int
    let dueCount: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text("\(itemCount) \(itemCount == 1 ? "item" : "items") · \(subtitle)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if dueCount > 0 {
                Text(dueCount, format: .number)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.tint.opacity(0.14), in: Capsule())
                    .accessibilityLabel("\(dueCount) due")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ScopeDetailView: View {
    @Bindable var model: MobileAppModel
    let scope: MobileScope
    @State private var summary: ScopeSummary?
    @State private var errorMessage: String?
    @State private var showsDeckSettings = false

    var body: some View {
        List {
            if let summary {
                Section {
                    DueNowCard(
                        title: model.scopeTitle(scope),
                        summary: summary,
                        isWorking: model.isStartingStudy,
                        action: startStudy
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Overview") {
                    LabeledContent("Items", value: summary.itemCount.formatted())
                    LabeledContent("Cards", value: summary.cardCount.formatted())
                    LabeledContent("New", value: summary.newCount.formatted())
                    LabeledContent("Learning", value: summary.inLearningCount.formatted())
                    LabeledContent("Review", value: summary.reviewCount.formatted())
                }
            } else if let errorMessage {
                ContentUnavailableView("Could Not Load Deck", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(model.scopeTitle(scope))
        .toolbar {
            if case let .deck(id) = scope {
                Button("Deck Settings", systemImage: "ellipsis.circle") { showsDeckSettings = true }
                    .sheet(isPresented: $showsDeckSettings) { DeckSettingsMobileView(model: model, deckID: id) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            summary = try await model.summary(for: scope)
        } catch {
            errorMessage = MobileAppModel.message(for: error)
        }
    }

    private func startStudy() {
        Task {
            await model.beginStudy(scope: scope)
        }
    }
}

private struct DeckSettingsMobileView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    let deckID: UUID
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var limitEnabled = false
    @State private var newCardLimit = 20
    @State private var errorMessage: String?
    @State private var deletionImpact: DeckDeletionImpact?
    @State private var resetImpact: DeckResetImpact?

    var body: some View {
        NavigationStack {
            Form {
                Section("Deck") {
                    TextField("Name", text: $name)
                    Picker("Parent", selection: $parentID) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(model.decks.filter { $0.id != deckID }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Daily New Cards") {
                    Toggle("Limit new cards", isOn: $limitEnabled)
                    Stepper("\(newCardLimit) per day", value: $newCardLimit, in: 0...999).disabled(!limitEnabled)
                }
                Section("Progress") {
                    Button("Reset Progress", role: .destructive) { Task { resetImpact = try? await model.library.deckResetImpact(id: deckID) } }
                }
                Section { Button("Delete Deck", role: .destructive) { Task { deletionImpact = try? await model.deckDeletionImpact(id: deckID, policy: .unassignItems) } } }
            }
            .navigationTitle("Deck Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .task { await load() }
            .confirmationDialog("Reset deck progress?", isPresented: Binding(get: { resetImpact != nil }, set: { if !$0 { resetImpact = nil } }), titleVisibility: .visible) {
                Button("Reset \(resetImpact?.cardCount ?? 0) Cards", role: .destructive) { Task { try? await model.resetDeckProgress(id: deckID); dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes \(resetImpact?.reviewLogCount ?? 0) review records. The cards become new again.") }
            .confirmationDialog("Delete deck?", isPresented: Binding(get: { deletionImpact != nil }, set: { if !$0 { deletionImpact = nil } }), titleVisibility: .visible) {
                Button("Delete and Unassign Items", role: .destructive) { Task { try? await model.deleteDeck(id: deckID, policy: .unassignItems); dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("\(deletionImpact?.itemCount ?? 0) items will remain in the library as unassigned. Nested decks are included.") }
            .alert("Could Not Save Deck", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
    private func load() async { if let deck = try? await model.library.deck(id: deckID) { name = deck.name; parentID = deck.parentID; limitEnabled = deck.newCardsPerDay != nil; newCardLimit = deck.newCardsPerDay ?? 20 } }
    private func save() async { do { try await model.updateDeck(id: deckID, name: name, parentID: parentID, newCardsPerDay: limitEnabled ? newCardLimit : nil); dismiss() } catch { errorMessage = MobileAppModel.message(for: error) } }
}

private struct NewDeckView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Deck name") {
                    TextField("e.g. Spanish vocabulary", text: $name)
                        .textContentType(.none)
                        .submitLabel(.done)
                }
            }
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel("Creating deck")
                    } else {
                        Button("Create") { save() }
                            .accessibilityIdentifier("new-deck-create")
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("Could Not Create Deck", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.createDeck(name: name)
                dismiss()
            } catch {
                errorMessage = MobileAppModel.message(for: error)
            }
        }
    }
}
#endif
