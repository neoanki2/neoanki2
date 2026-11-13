import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI

public enum LearningTimeFormat {
    public static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    public static func accessibleDuration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1000
        return "\(seconds / 3600) hours, \((seconds % 3600) / 60) minutes, \(seconds % 60) seconds"
    }
}

public struct LearningTimeHomeSection: View {
    @State private var model: LearningTimeFeatureModel
    private let onDetails: () -> Void
    public init(library: any LibraryRepository, scope: DeckScope, onDetails: @escaping () -> Void) {
        _model = State(initialValue: LearningTimeFeatureModel(library: library, scope: scope)); self.onDetails = onDetails
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Learning time").font(.headline)
            if let today = model.today, let all = model.allTime {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { totals(today, all) }
                    VStack(alignment: .leading, spacing: 8) { totals(today, all) }
                }
                if case .deck = model.scope { Text("Including subdecks").font(.caption).foregroundStyle(.secondary) }
                if model.scope == .allDecks, all.pendingMilliseconds > 0 {
                    Text(LearningTimeFormat.duration(all.pendingMilliseconds) + " waiting for synced content.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.error == nil {
                ProgressView("Loading learning time…")
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            LearningTimeSaveStatusView()
            Button("View Learning Time", action: onDetails).buttonStyle(.borderless)
                .accessibilityIdentifier("viewLearningTime")
        }
        .accessibilityElement(children: .contain)
        .task { await model.observe() }
    }
    @ViewBuilder private func totals(_ today: LearningTimeSummary, _ all: LearningTimeSummary) -> some View {
        LabeledContent("Today", value: LearningTimeFormat.duration(today.totalMilliseconds))
        LabeledContent("All time", value: LearningTimeFormat.duration(all.totalMilliseconds))
    }
}

public struct LearningTimeView: View {
    @State private var model: LearningTimeFeatureModel
    private let title: String
    public init(library: any LibraryRepository, scope: DeckScope, title: String = "Learning Time") {
        _model = State(initialValue: LearningTimeFeatureModel(library: library, scope: scope)); self.title = title
    }
    public var body: some View {
        List {
            Section {
                Picker("Period", selection: $model.period) {
                    ForEach(LearningTimePeriod.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("learningTimePeriod")
            }
            Section { LearningTimeSaveStatusView() }
            if let summary = model.summary {
                Section {
                    LabeledContent("Learning time", value: LearningTimeFormat.duration(summary.totalMilliseconds))
                        .accessibilityLabel("Learning time, " + LearningTimeFormat.accessibleDuration(summary.totalMilliseconds))
                        .accessibilityIdentifier("learningTimeTotal")
                    if model.scope == .allDecks, summary.pendingMilliseconds > 0 {
                        Text(LearningTimeFormat.duration(summary.pendingMilliseconds) + " waiting for synced content.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if case .deck = model.scope {
                        LabeledContent("This deck only", value: LearningTimeFormat.duration(summary.directMilliseconds))
                        LabeledContent("Subdecks", value: LearningTimeFormat.duration(summary.descendantMilliseconds))
                    }
                    if let began = summary.trackingStartedAt {
                        Text("Tracking since \(began.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No learning time recorded yet").foregroundStyle(.secondary)
                    }
                    Text("Days follow your study-day rollover and this device’s time zone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Decks") {
                    ForEach(roots(summary)) { deck in LearningTimeDeckRow(deck: deck, decks: summary.decks) }
                    if model.scope == .allDecks || model.scope == .unassigned {
                        if summary.unassignedMilliseconds > 0 {
                            LabeledContent("Unassigned", value: LearningTimeFormat.duration(summary.unassignedMilliseconds))
                        }
                    }
                    if model.scope == .allDecks, summary.deletedMilliseconds > 0 {
                        LabeledContent("Deleted Content", value: LearningTimeFormat.duration(summary.deletedMilliseconds))
                    }
                }
            } else if model.error == nil {
                ProgressView("Loading learning time…")
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    if let range = model.summary?.range {
                        Text("Saved period: \(range.start.formatted(date: .abbreviated, time: .shortened)) – \(range.end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Retry") { Task { await model.refresh() } }
                }
            }
        }
        .navigationTitle(title)
        .task { await model.observe() }
        .task(id: model.period) { await model.refresh() }
    }
    private func roots(_ summary: LearningTimeSummary) -> [LearningTimeDeckTotal] {
        switch model.scope {
        case .allDecks: summary.decks.filter { $0.parentID == nil }
        case .unassigned: []
        case let .deck(id, _): summary.decks.filter { $0.id == id }
        }
    }
}

private struct LearningTimeDeckRow: View {
    let deck: LearningTimeDeckTotal
    let decks: [LearningTimeDeckTotal]
    private var children: [LearningTimeDeckTotal] { decks.filter { $0.parentID == deck.id } }
    var body: some View {
        if children.isEmpty {
            LabeledContent(deck.name, value: LearningTimeFormat.duration(deck.totalMilliseconds))
        } else {
            DisclosureGroup {
                LabeledContent("This deck only", value: LearningTimeFormat.duration(deck.directMilliseconds))
                ForEach(children) { child in LearningTimeDeckRow(deck: child, decks: decks) }
            } label: {
                LabeledContent(deck.name, value: LearningTimeFormat.duration(deck.totalMilliseconds))
                    .accessibilityLabel(deck.name + ", including subdecks, " + LearningTimeFormat.accessibleDuration(deck.totalMilliseconds))
            }
        }
    }
}
