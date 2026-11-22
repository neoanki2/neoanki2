import NeoAnkiCore
import NeoAnkiApplication
import NeoAnkiFeatures
import NeoAnkiSharedUI
import NeoAnkiVocabularyKit
import SwiftUI

#if os(iOS)
import UIKit
private struct OpenWordCaptureKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID?) -> Void = { _ in }
}
private extension EnvironmentValues {
    var openWordCapture: @MainActor (UUID?) -> Void {
        get { self[OpenWordCaptureKey.self] }
        set { self[OpenWordCaptureKey.self] = newValue }
    }
}
public struct MobileRootView: View {
    @Bindable var model: MobileAppModel
    @State private var fixtureError: String?
    @State private var showsWordCapture = false
    @State private var showsLearnInContext = false
    @State private var wordCaptureDeckID: UUID?
    @State private var fixturesReady = false
    @State private var retriedFailureFixture = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.mobileUITestFixtures) private var fixtures
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mobile-conceals-answers") private var concealsAnswers = true
    @State private var vocabularyLibrary: MobileVocabularyLibraryModel
    private let vocabularyRootURL: URL

    public init(model: LibraryFeatureModel, vocabularyRootURL: URL, packCloudTransport: (any VocabularyPackCloudTransport)? = nil) {
        self.model = model
        self.vocabularyRootURL = vocabularyRootURL
        _vocabularyLibrary = State(initialValue: MobileVocabularyLibraryModel(rootURL: vocabularyRootURL, cloudTransport: packCloudTransport))
    }

    public var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset"),
               ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] == "mobile-load-error",
               !retriedFailureFixture {
                libraryRecovery(message: "Your library could not be opened. Try again to reconnect to your saved items.")
            } else {
            switch model.loadState {
            case .loading:
                ProgressView("Opening your library…")
            case .ready:
                if ["mobile-redesign", "mobile-vocabulary", "mobile-item-lookup"].contains(ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] ?? ""), !fixturesReady {
                    ProgressView("Preparing visual fixtures…")
                } else {
                    MobileTabView(model: model, vocabularyLibrary: vocabularyLibrary)
                }
            case let .failed(error):
                libraryRecovery(message: error.message)
            }
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = model.recoveryMessage {
                HStack {
                    Text(message).font(.footnote)
                    Button("Refresh") { Task { await model.refresh() } }
                }.padding().background(.regularMaterial)
            }
        }
        .tint(SharedDesignSystem.mobileTint(for: colorScheme))
        .environment(\.vocabularyPackRootURL, vocabularyRootURL)
        .environment(\.openLearnInContext, { deckID in
            wordCaptureDeckID = deckID
            showsLearnInContext = true
        })
        .environment(\.openWordCapture, { deckID in
            wordCaptureDeckID = deckID
            showsWordCapture = true
        })
        .sheet(isPresented: $showsWordCapture, onDismiss: { Task { await vocabularyLibrary.load() } }) {
            WordCaptureView(model: model.features.makeWordCapture(rootURL: vocabularyRootURL) {
                await model.authoringDidCommit()
            }, deckID: wordCaptureDeckID)
            .dynamicTypeSize(dynamicTypeSize)
        }
        .alert("Visual Fixture Failed", isPresented: Binding(get: { fixtureError != nil }, set: { if !$0 { fixtureError = nil } })) {
            Button("OK") { fixtureError = nil }
        } message: { Text(fixtureError ?? "") }
        .sheet(isPresented: $showsLearnInContext) {
            LearnInContextView(model: model.features.makeLearnInContext(rootURL: vocabularyRootURL) {
                await model.authoringDidCommit()
            }, deckID: wordCaptureDeckID).dynamicTypeSize(dynamicTypeSize)
        }
        .onAppear { model.concealsAnswers = concealsAnswers }
        .onChange(of: model.concealsAnswers) { _, value in concealsAnswers = value }
        .task(id: model.syncEnabled) { vocabularyLibrary.sync.setEnabled(model.syncEnabled) }
        .task(id: model.syncEnabled && scenePhase == .active) {
            guard model.syncEnabled, scenePhase == .active else { return }
            // SyncService currently exposes status as a query. Preserve its
            // status indicator without coupling it to full-library polling.
            while !Task.isCancelled {
                await model.refreshSyncStatus()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vocabularyLibrary.sync.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.dueCounts.invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            model.dueCounts.invalidate()
        }
        .task {
            await model.bootstrap()
            #if DEBUG
            do { try MobileImageAttachmentUITestFixture.seedIfRequested() }
            catch { fixtureError = MobileAppModel.message(for: error) }
            #endif
            if ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] == "mobile-redesign" {
                do { try await fixtures?.prepareRedesign(); await model.refresh() }
                catch { fixtureError = MobileAppModel.message(for: error); await model.refresh() }
                fixturesReady = true
            } else if ["mobile-vocabulary", "mobile-item-lookup"].contains(ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] ?? "") {
                do { try await fixtures?.prepareVocabulary(vocabularyLibrary); await model.refresh() }
                catch { fixtureError = MobileAppModel.message(for: error) }
                fixturesReady = true
            }
            // Availability owns a foreground-only timer for the next due time
            // or study-day boundary; no full-library polling is needed.
        }
    }

    private func libraryRecovery(message: String) -> some View {
        ContentUnavailableView {
            Label("Could Not Open NeoAnki2", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button {
                retriedFailureFixture = true
                Task { await model.bootstrap() }
            } label: { Text("Try Again").frame(minHeight: 44) }
            .buttonStyle(.borderedProminent).neoAnkiMobilePrimaryActionTint()
            .controlSize(.large)
        }
    }
}

private struct MobileTabView: View {
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.neoAnkiAccessibilityReduceMotionOverride) private var reduceMotionOverride
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var createPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var statisticsPath = NavigationPath()

    private var usesSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        // Keep one TabView and its stacks mounted as the sidebar appears or
        // disappears. A nested split view merges the stacks' navigation bars.
        HStack(spacing: 0) {
            if usesSidebar {
            VStack(alignment: .leading, spacing: 0) {
                Text("NeoAnki2").font(.title2.weight(.semibold)).padding(20)
                List(AppSection.allCases) { section in
                    Button { model.section = section } label: {
                        Label(section.title, systemImage: section.symbol)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("top-level-\(section.title.lowercased())")
                    .listRowBackground(model.section == section ? Color.accentColor.opacity(0.14) : Color.clear)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
                .listStyle(.sidebar)
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 320 : 260)
            }
            TabView(selection: $model.section) {
                ForEach(AppSection.allCases) { section in
                    destination(section)
                        .dynamicTypeSize(dynamicTypeSize)
                        .frame(maxWidth: usesSidebar ? 900 : .infinity)
                        .frame(maxWidth: .infinity)
                        .tabItem { Label(section.title, systemImage: section.symbol) }
                        .tag(section)
                }
            }
            .toolbar(usesSidebar ? .hidden : .visible, for: .tabBar)
        }
        .tint(SharedDesignSystem.mobileTint(for: colorScheme))
        .fullScreenCover(item: $model.activeStudy) { session in
            StudySessionView(session: session, model: model)
                .dynamicTypeSize(dynamicTypeSize)
                .environment(\.neoAnkiAccessibilityReduceMotionOverride, reduceMotionOverride)
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
        case .home: HomeView(model: model, path: $homePath)
        case .library: LibraryView(model: model, navigationPath: $libraryPath)
        case .create: CreateHubView(model: model, vocabularyLibrary: vocabularyLibrary, path: $createPath)
        case .statistics:
            NavigationStack(path: $statisticsPath) {
                StatisticsView(model: model.features.makeStatistics(scope: model.statisticsScope, sessionID: model.statisticsSessionID))
                    .id(model.statisticsNavigationID)
            }
        case .settings: SettingsView(model: model, vocabularyLibrary: vocabularyLibrary, path: $settingsPath)
        }
    }
}

struct MobileTabBarVisibility: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.toolbar(UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular ? .hidden : .visible, for: .tabBar)
    }
}

private extension AppSection {
    var title: String {
        switch self { case .home: "Home"; case .library: "Library"; case .create: "Create"; case .statistics: "Statistics"; case .settings: "Settings" }
    }
    var symbol: String {
        switch self { case .home: "house"; case .library: "rectangle.stack"; case .create: "plus.square"; case .statistics: "chart.bar.xaxis"; case .settings: "gearshape" }
    }
}

private struct CreateHubView: View {
    @Environment(\.openWordCapture) private var openWordCapture
    @Environment(\.openLearnInContext) private var openLearnInContext
    @Bindable var model: MobileAppModel
    @Bindable var vocabularyLibrary: MobileVocabularyLibraryModel
    @Binding var path: NavigationPath
    @State private var isAddingItem = false
    @State private var isAddingDeck = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Add") {
                    Button("Learn in Context", systemImage: "text.bubble") { openLearnInContext(nil) }
                        .accessibilityIdentifier("create-learn-in-context")
                    Button("Add Word", systemImage: "character.book.closed") { openWordCapture(nil) }
                        .accessibilityIdentifier("create-add-word")
                    Button { isAddingItem = true } label: { Label("New Item", systemImage: "rectangle.stack.badge.plus") }
                    Button { isAddingDeck = true } label: { Label("New Deck", systemImage: "folder.badge.plus") }
                }
                Section("Design") {
                    NavigationLink { ItemTypesMobileView(model: model) } label: { Label("Item Types & Card Setups", systemImage: "square.stack.3d.up") }
                }
                Section("Deck Builders") {
                    NavigationLink { PoemBuilderMobileHost(model: model) } label: { Label("Poem Deck", systemImage: "text.quote") }
                    NavigationLink { ProseBuilderMobileHost(model: model) } label: { Label("Prose Deck", systemImage: "text.book.closed") }
                }
                Section("Transfer") {
                    NavigationLink { TransferToolsView(model: model) } label: { Label("Import or Export", systemImage: "arrow.up.arrow.down.square") }
                    NavigationLink { VocabularyToolsView(model: vocabularyLibrary) } label: { Label("Vocabulary Packs", systemImage: "books.vertical") }
                }
            }
            .navigationTitle("Create")
            .modifier(MobileTabBarVisibility())
            .sheet(isPresented: $isAddingItem) { AddItemView(model: model) }
            .sheet(isPresented: $isAddingDeck) { NewDeckView(model: model) }
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: MobileAppModel
    let vocabularyLibrary: MobileVocabularyLibraryModel
    @Binding var path: NavigationPath
    @AppStorage(StudyPreferences.usesPassFailGrades) private var usesPassFailGrades = false
    @State private var showsSyncConsent = false
    @State private var errorMessage: String?
    @State private var rolloverMinutes: Int?
    @State private var isSavingRollover = false

    var body: some View {
        NavigationStack(path: $path) {
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
                    Button("Sync Now") { Task { await model.synchronize(); await vocabularyLibrary.sync.refresh() } }
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
                    DatePicker("New day begins", selection: rolloverTime, displayedComponents: .hourAndMinute)
                        .disabled(rolloverMinutes == nil || isSavingRollover)
                        .accessibilityIdentifier("study-day-rollover")
                }
                Section("About") {
                    LabeledContent("Data", value: "Stored on this device")
                    Text("NeoAnki2 keeps working offline. iCloud is optional and uses your private CloudKit database.")
                        .foregroundStyle(.secondary)
                    Link("Privacy Policy", destination: URL(string: "https://neoanki2.github.io/user/privacy/")!)
                        .accessibilityIdentifier("mobilePrivacyPolicy")
                    Link("Help & Support", destination: URL(string: "https://neoanki2.github.io/user/support/")!)
                        .accessibilityIdentifier("mobileSupport")
                }
            }
            .navigationTitle("Settings")
            .modifier(MobileTabBarVisibility())
            .task {
                do { rolloverMinutes = try await model.studyDayRolloverMinutes() }
                catch { errorMessage = MobileAppModel.message(for: error) }
            }
            .alert("Enable iCloud Sync?", isPresented: $showsSyncConsent) {
                Button("Create Backup & Enable") { Task { await model.setSyncEnabled(true) } }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("NeoAnki2 will create a verified local backup, then merge this library with your private iCloud library. Imported dictionaries upload automatically; other devices download them when you choose. Existing content is never replaced wholesale.")
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

    private var rolloverTime: Binding<Date> {
        Binding(
            get: {
                let minutes = rolloverMinutes ?? 240
                return Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? .now
            },
            set: { value in
                guard rolloverMinutes != nil, !isSavingRollover else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                let minutes = (parts.hour ?? 4) * 60 + (parts.minute ?? 0)
                guard minutes != rolloverMinutes else { return }
                isSavingRollover = true
                Task {
                    defer { isSavingRollover = false }
                    do {
                        try await model.setStudyDayRolloverMinutes(minutes)
                        rolloverMinutes = minutes
                    } catch { errorMessage = MobileAppModel.message(for: error) }
                }
            }
        )
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
    @Binding var path: NavigationPath
    @State private var isAddingItem = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    DueNowCard(
                        summary: model.allDecksSummary,
                        dueCount: model.dueCounts.count(for: .allDecks),
                        loadState: model.dueCounts.state,
                        retry: { Task { await model.dueCounts.refresh() } },
                        // Background count refreshes do not prevent study.
                        // Only starting a session must disable this action.
                        isWorking: model.isStartingStudy,
                        action: { startStudy(.allDecks) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    if model.allDecksSummary.itemCount == 0 {
                        Button("Add First Item", systemImage: "plus") { isAddingItem = true }
                    }
                }

                Section {
                    NavigationLink(value: MobileScope.allDecks) {
                        ScopeRow(
                            title: "All Decks",
                            subtitle: "Everything in your library",
                            itemCount: model.allDecksSummary.itemCount,
                            dueCount: model.dueCounts.count(for: .allDecks), loadState: model.dueCounts.state
                        )
                    }

                    ForEach(model.decks.filter { $0.parentID == nil }) { deck in
                        NavigationLink(value: MobileScope.deck(deck.id)) {
                            ScopeRow(
                                title: deck.name,
                                subtitle: deck.parentID == nil ? "Deck" : "Nested deck",
                                itemCount: deck.itemCount,
                                dueCount: model.dueCounts.deckCount(deck.id), loadState: model.dueCounts.state
                            )
                        }
                    }

                    NavigationLink(value: MobileScope.unassigned) {
                        ScopeRow(
                            title: "Unassigned",
                            subtitle: "Cards without a deck",
                            itemCount: model.unassignedSummary.itemCount,
                            dueCount: model.dueCounts.count(for: .unassigned), loadState: model.dueCounts.state
                        )
                    }
                } header: {
                    Text("Decks")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .textCase(nil)
                }
            }
            .navigationTitle("Home")
            .modifier(MobileTabBarVisibility())
            .navigationDestination(for: MobileScope.self) { scope in
                ScopeDetailView(model: model, scope: scope)
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $isAddingItem) { AddItemView(model: model) }
            .onChange(of: model.route) { _, route in
                if case let .scope(scope) = route { path = NavigationPath([MobileScope(scope)]) }
            }
            .task {
                model.dueCounts.selectScope(nil)
                if case let .scope(scope) = model.route { path = NavigationPath([MobileScope(scope)]) }
            }
        }
    }

    private func startStudy(_ scope: MobileScope) {
        Task {
            await model.beginStudy(scope: scope)
        }
    }
}

private struct DueNowCard: View {
    let summary: ScopeSummary
    let dueCount: Int?
    let loadState: DueCountLoadState
    var hasStandaloneLesson = false
    let retry: () -> Void
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .failed = loadState {
                Text("Could Not Check Due Cards").font(.headline)
                Button("Try Again", action: retry).frame(minHeight: 44)
            } else if hasStandaloneLesson, (dueCount ?? 0) == 0 {
                Text("Lesson ready").font(.title2.weight(.semibold))
                studyButton
            } else if let dueCount {
                Text(dueCount > 0 ? "\(dueCount) \(dueCount == 1 ? "card" : "cards") due" : "You're caught up")
                    .font(.title2.weight(.semibold))
                if dueCount > 0 {
                    Text("A little practice goes a long way.").foregroundStyle(.secondary)
                    studyButton
                } else {
                    Text(summary.itemCount == 0 ? "Add your first item to begin." : "Come back when your next cards are due.")
                        .foregroundStyle(.primary)
                }
            } else {
                ProgressView("Checking due cards…")
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private var studyButton: some View {
        Button(action: action) {
            Label("Study", systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).neoAnkiMobilePrimaryActionTint()
        .disabled(isWorking)
    }
}

private struct ScopeRow: View {
    let title: String
    let subtitle: String
    let itemCount: Int
    let dueCount: Int?
    let loadState: DueCountLoadState

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
            if let dueCount, dueCount > 0 {
                Text(dueCount, format: .number)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.tint.opacity(0.14), in: Capsule())
                    .accessibilityLabel("\(dueCount) due")
            } else if dueCount == nil {
                if case .failed = loadState {
                    Text("—").accessibilityLabel("Due count unavailable")
                } else {
                    ProgressView().accessibilityLabel("Checking due cards")
                }
            }
        }
        .padding(.vertical, 4)
    }

}

private struct ScopeDetailView: View {
    @Environment(\.openWordCapture) private var openWordCapture
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MobileAppModel
    let scope: MobileScope
    @State private var summary: ScopeSummary?
    @State private var hasStandaloneLesson = false
    @State private var errorMessage: String?
    @State private var showsDeckSettings = false
    @State private var showsAddItem = false

    var body: some View {
        List {
            if let summary {
                Section {
                    DueNowCard(
                        summary: summary,
                        dueCount: model.dueCounts.count(for: scope.filter),
                        loadState: model.dueCounts.state,
                        hasStandaloneLesson: hasStandaloneLesson,
                        retry: { Task { await model.dueCounts.refresh() } },
                        isWorking: model.isStartingStudy,
                        action: startStudy
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    if case let .deck(id) = scope {
                        Button("Add Word", systemImage: "character.book.closed") { openWordCapture(id) }
                            .accessibilityIdentifier("deck-add-word")
                    }
                    Button("Add Item", systemImage: "plus") { showsAddItem = true }
                }
                if case let .deck(id) = scope, model.decks.contains(where: { $0.parentID == id }) {
                    Section("Decks") {
                        ForEach(model.decks.filter { $0.parentID == id }) { deck in
                            NavigationLink(value: MobileScope.deck(deck.id)) {
                                ScopeRow(title: deck.name, subtitle: "Deck", itemCount: deck.itemCount,
                                         dueCount: model.dueCounts.deckCount(deck.id), loadState: model.dueCounts.state)
                            }
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Could Not Load Deck", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showsAddItem, onDismiss: { Task { await load() } }) {
            AddItemView(model: model, deckID: { if case let .deck(id) = scope { return id }; return nil }())
        }
        .navigationTitle(model.scopeTitle(scope))
        .toolbar {
            if case let .deck(id) = scope {
                Button("Deck Settings", systemImage: "ellipsis.circle") { showsDeckSettings = true }
                    .sheet(isPresented: $showsDeckSettings) {
                        DeckSettingsMobileView(model: model, deckID: id) { dismiss() }
                    }
            }
        }
        .task {
            model.dueCounts.selectScope(scope.filter)
            await load()
        }
        .onAppear { model.dueCounts.selectScope(scope.filter) }
        .onDisappear {
            if model.dueCounts.activeScope == scope.filter { model.dueCounts.selectScope(nil) }
        }
        .onChange(of: model.allDecksSummary) { _, _ in Task { await load() } }
        .onChange(of: model.activeStudy?.id) { _, id in if id == nil { Task { await load() } } }
    }

    private func load() async {
        do {
            summary = try await model.summary(for: scope)
            let available = await model.hasStandaloneCourseLesson(in: scope.filter)
            if !Task.isCancelled { hasStandaloneLesson = available }
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
    let onDeleted: () -> Void
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var limitEnabled = false
    @State private var newCardLimit = 20
    @State private var errorMessage: String?
    @State private var typesRevision = 0
    @State private var typeStudio: ItemTypesFeatureModel?
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
                Section("Item Types") {
                    NavigationLink("Manage Item Types") {
                        DeckItemTypesView(model: model.features.makeDeckItemTypes(deckID: deckID, onChanged: { await model.authoringDidCommit() }), refreshToken: typesRevision, onEdit: { type in
                            Task { typeStudio = await model.features.openItemType(id: type.id, deckID: deckID) }
                        })
                    }
                }
                Section("Daily New Cards") {
                    Toggle("Limit new cards", isOn: $limitEnabled)
                    Stepper("\(newCardLimit) per day", value: $newCardLimit, in: 0...999).disabled(!limitEnabled)
                }
                Section("Progress") {
                    Button("Reset Progress", role: .destructive) { Task { resetImpact = try? await model.deckResetImpact(id: deckID) } }
                }
                Section { Button("Delete Deck", role: .destructive) { Task { deletionImpact = try? await model.deckDeletionImpact(id: deckID, policy: .unassignItems) } } }
            }
            .navigationTitle("Deck Settings").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: { typeStudio != nil }, set: { if !$0 { typeStudio = nil } }), onDismiss: { typesRevision += 1 }) {
                if let typeStudio { NavigationStack { ItemTypeStudioMobileView(model: typeStudio, reloadLibrary: { await model.authoringDidCommit() }) } }
            }
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
                Button("Delete and Unassign Items", role: .destructive) {
                    Task { await deleteDeck() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("\(deletionImpact?.itemCount ?? 0) items will remain in the library as unassigned. Nested decks are included.") }
            .alert("Could Not Update Deck", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
    private func load() async { if let deck = try? await model.deck(id: deckID) { name = deck.name; parentID = deck.parentID; limitEnabled = deck.newCardsPerDay != nil; newCardLimit = deck.newCardsPerDay ?? 20 } }
    private func save() async { do { try await model.updateDeck(id: deckID, name: name, parentID: parentID, newCardsPerDay: limitEnabled ? newCardLimit : nil); dismiss() } catch { errorMessage = MobileAppModel.message(for: error) } }
    private func deleteDeck() async {
        do {
            try await model.deleteDeck(id: deckID, policy: .unassignItems)
            onDeleted()
        } catch {
            errorMessage = MobileAppModel.message(for: error)
        }
    }
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
