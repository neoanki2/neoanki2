import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

@Test func decodesItemDeepLink() {
    let id = UUID()
    #expect(AppDeepLink(url: URL(string: "neoanki2://item?id=\(id.uuidString)")!) == .item(id))
}

@Test func decodesStudyDeckDeepLink() {
    let id = UUID()
    #expect(AppDeepLink(url: URL(string: "neoanki2://study?kind=deck&id=\(id.uuidString)")!) == .study(.deck(id)))
}

@Test func deviceLocalConsentAndReminderSettingsSurviveModelRecreation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-feature-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    let settings = VolatileMobileSettingsStore()
    let first = await LibraryFeatureModel(library: repository, settingsStore: settings)
    await first.bootstrap()
    await first.setSyncEnabled(true)
    try await first.setReminderSettings(ReminderSettings(isEnabled: true, hour: 8, minute: 15, scope: .allDecks))

    let second = await LibraryFeatureModel(library: repository, settingsStore: settings)
    await second.bootstrap()
    #expect(await second.syncEnabled)
    #expect(await second.reminderSettings == ReminderSettings(isEnabled: true, hour: 8, minute: 15, scope: .allDecks))
}
