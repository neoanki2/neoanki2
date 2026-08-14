import Foundation
import SwiftUI
import WidgetKit

private struct WidgetDeckSummary: Codable, Identifiable {
    let id: UUID
    let name: String
    let dueCount: Int
    let nextDueAt: Date?
}

private struct WidgetSnapshot: Codable {
    let totalDueCount: Int
    let nextDueAt: Date?
    let decks: [WidgetDeckSummary]
    let updatedAt: Date
}

private struct DueEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct DueProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry { DueEntry(date: .now, snapshot: .init(totalDueCount: 12, nextDueAt: .now, decks: [], updatedAt: .now)) }
    func getSnapshot(in context: Context, completion: @escaping (DueEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DueEntry>) -> Void) {
        let entry = load()
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
    private func load() -> DueEntry {
        let data = UserDefaults(suiteName: "group.com.neoanki2.shared")?.data(forKey: "due-widget-snapshot-v1")
        let snapshot = data.flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
            ?? WidgetSnapshot(totalDueCount: 0, nextDueAt: nil, decks: [], updatedAt: .now)
        return DueEntry(date: .now, snapshot: snapshot)
    }
}

private struct DueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DueEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("NeoAnki2", systemImage: "rectangle.stack")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(entry.snapshot.totalDueCount, format: .number)
                .font(family == .accessoryInline ? .body : .largeTitle.bold())
            Text(entry.snapshot.totalDueCount == 1 ? "card due" : "cards due")
                .font(.subheadline)
            if let next = entry.snapshot.nextDueAt, entry.snapshot.totalDueCount == 0 {
                Text("Next \(next, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if family == .systemMedium {
                ForEach(entry.snapshot.decks.prefix(3)) { deck in
                    Link(destination: URL(string: "neoanki2://scope?kind=deck&id=\(deck.id.uuidString)")!) {
                        HStack { Text(deck.name).lineLimit(1); Spacer(); Text(deck.dueCount, format: .number).monospacedDigit() }
                            .font(.caption)
                    }
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "neoanki2://study?kind=all"))
        .accessibilityElement(children: .combine)
    }
}

struct NeoAnkiDueWidget: Widget {
    let kind = "NeoAnkiDueWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DueProvider()) { DueWidgetView(entry: $0) }
            .configurationDisplayName("Due Cards")
            .description("See what is due without showing prompts or answers.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

@main struct NeoAnkiWidgets: WidgetBundle {
    var body: some Widget { NeoAnkiDueWidget() }
}
