import Charts
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import SwiftUI
import UniformTypeIdentifiers

private struct StatisticsCSV: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// A single surface, including layout and chart definitions, for all Apple
/// platforms. Shells supply only the library and initial navigation context.
public struct StatisticsView: View {
    @State private var model: StatisticsFeatureModel
    @State private var heatmapTime = false
    @State private var exportText: String?
    @State private var exporting = false
    @State private var selectedInterval: DateInterval?
    @State private var selectedGrade: String?
    @State private var selectedCardGroup: StatisticsCardGroup?
    @State private var selectedReview: StatisticsReview?
    @State private var visibleReviews = 100
    @State private var customPace = false
    @State private var customRetention = false
    public init(library: any LibraryRepository, scope: DeckScope = .allDecks, sessionID: UUID? = nil) {
        _model = State(
            initialValue: StatisticsFeatureModel(library: library, scope: scope, sessionID: sessionID))
    }
    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                filters
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model.refresh() } }
                    }
                }
                LearningTimeSaveStatusView()
                if let snapshot = model.snapshot {
                    Text(
                        "\(snapshot.range.start.formatted(date:.abbreviated,time:.omitted)) – \(snapshot.range.end.formatted(date:.abbreviated,time:.omitted))"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    switch model.section {
                    case .overview: overview(snapshot)
                    case .activity: activity(snapshot)
                    case .memory: memory(snapshot)
                    case .workload: workload(snapshot)
                    }
                } else if model.isLoading {
                    ProgressView("Preparing statistics…")
                } else {
                    ContentUnavailableView(
                        "No Statistics Yet", systemImage: "chart.bar",
                        description: Text("Study a card to begin recording your activity."))
                }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .environment(
            \.statisticsExportCSV,
            { text in
                exportText = text
                exporting = true
            }
        )
        .navigationTitle("Statistics")
        .accessibilityIdentifier("statisticsScreen")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if model.isLoading { ProgressView().accessibilityLabel("Refreshing statistics") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV", systemImage: "square.and.arrow.up") {
                    exportText = nil
                    exporting = true
                }.disabled(model.snapshot == nil)
            }
        }
        .fileExporter(
            isPresented: $exporting, document: StatisticsCSV(exportText ?? model.snapshot?.csv ?? ""),
            contentType: .commaSeparatedText, defaultFilename: "NeoAnki-Statistics"
        ) { _ in }
        .task { await model.observe() }
        .onChange(of: model.query) { _, _ in
            selectedInterval = nil
            selectedGrade = nil
            visibleReviews = 100
            Task { await model.refresh() }
        }
        .onDisappear { model.cancelForecast() }
        .sheet(item: $selectedCardGroup) { group in StatisticsCardInspector(group: group) }
        .sheet(item: $selectedReview) { review in reviewDetail(review) }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                Picker("Section", selection: $model.section) {
                    ForEach(StatisticsSection.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Section", selection: $model.section) {
                    ForEach(StatisticsSection.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            }.accessibilityIdentifier("statisticsSection")
            ViewThatFits(in: .horizontal) {
                HStack {
                    scopePicker
                    periodPicker
                }
                VStack(alignment: .leading) {
                    scopePicker
                    periodPicker
                }
            }
            if case .deck(let id, let descendants) = model.query.scope {
                Toggle(
                    "Include subdecks",
                    isOn: Binding(
                        get: { descendants }, set: { model.query.scope = .deck(id, includeDescendants: $0) }))
            }
            if model.query.period == .custom {
                DatePicker(
                    "From", selection: $model.query.customStart, in: ...Date.now, displayedComponents: .date)
                DatePicker(
                    "Through", selection: $model.query.customEnd, in: ...Date.now, displayedComponents: .date)
            }
            if model.query.sessionID != nil {
                Button("Clear session filter", systemImage: "xmark.circle") { model.query.sessionID = nil }
            }
            DisclosureGroup("More filters") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Item type", selection: $model.query.itemTypeID) {
                        Text("All item types").tag(nil as UUID?)
                        ForEach(
                            (model.snapshot?.itemTypeNames ?? [:]).keys.sorted(by: {
                                $0.uuidString < $1.uuidString
                            }), id: \.self
                        ) { id in Text(model.snapshot?.itemTypeNames[id] ?? "Unknown").tag(Optional(id)) }
                    }
                    Picker("Card setup", selection: $model.query.templateID) {
                        Text("All card setups").tag(nil as UUID?)
                        ForEach(
                            (model.snapshot?.templateNames ?? [:]).keys.sorted(by: {
                                $0.uuidString < $1.uuidString
                            }), id: \.self
                        ) { id in Text(model.snapshot?.templateNames[id] ?? "Unknown").tag(Optional(id)) }
                    }
                    Picker("Skill", selection: $model.query.skill) {
                        Text("All skills").tag(nil as String?)
                        ForEach(Array(Set((model.snapshot?.skills ?? []) + ["Unknown"])).sorted(), id: \.self)
                        { Text($0).tag(Optional($0)) }
                    }
                    Picker("Answer method", selection: $model.query.interaction) {
                        Text("All answer methods").tag(nil as String?)
                        ForEach(
                            Array(Set((model.snapshot?.interactions ?? []) + ["Unknown"])).sorted(),
                            id: \.self
                        ) { Text($0.capitalized).tag(Optional($0)) }
                    }
                    Toggle(
                        "Attribute reviews to deck at time of study", isOn: $model.query.studyTimeAttribution)
                    Text(
                        "Active time follows current item location. Deleted content is included in All Decks. Current memory charts always describe now."
                    ).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.subheadline)
        }
    }
    private var scopePicker: some View {
        Picker(
            "Scope",
            selection: Binding<String>(
                get: {
                    switch model.query.scope {
                    case .allDecks: "all"
                    case .unassigned: "unassigned"
                    case .deck(let id, _): id.uuidString
                    }
                },
                set: { value in
                    if let id = UUID(uuidString: value) {
                        model.query.scope = .deck(id)
                    } else {
                        model.query.scope = value == "all" ? .allDecks : .unassigned
                    }
                })
        ) {
            Text("All Decks").tag("all")
            Text("Unassigned").tag("unassigned")
            ForEach(model.snapshot?.decks ?? []) { Text($0.name).tag($0.id.uuidString) }
        }.accessibilityIdentifier("statisticsScope")
    }
    private var periodPicker: some View {
        Picker("Period", selection: $model.query.period) {
            ForEach(StatisticsPeriod.allCases) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("statisticsPeriod")
    }
    private func overview(_ s: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("Reviews")
                    Text(s.reviewCount, format: .number).monospacedDigit()
                    Text(
                        model.query.period == .all
                            ? "All recorded reviews"
                            : "\(s.reviewCount-s.previousReviews >= 0 ? "+" : "")\(s.reviewCount-s.previousReviews) vs previous period"
                    ).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Cards studied")
                    Text(s.distinctCards, format: .number).monospacedDigit()
                    Text("\(s.distinctItems) distinct items").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Active time")
                    Text(LearningTimeFormat.duration(s.activeMilliseconds)).monospacedDigit()
                    Text("Previous: " + LearningTimeFormat.duration(s.previousMilliseconds)).foregroundStyle(
                        .secondary)
                }
                GridRow {
                    Text("Observed recall")
                    Text(s.observedRecall.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                        .monospacedDigit()
                    Text("\(s.recallPassed)/\(s.recallTotal) spaced reviews").foregroundStyle(.secondary)
                }
            }.font(.subheadline).accessibilityIdentifier("statisticsTotals")
            Text(
                "\(s.currentStreak)-day current streak · \(s.longestStreak)-day longest · \(s.activeDays) active days in this period"
            ).font(.subheadline)
            HStack {
                Text("Calendar year")
                Picker(
                    "Calendar year",
                    selection: Binding(
                        get: { model.query.heatmapYear ?? Calendar.current.component(.year, from: .now) },
                        set: { model.query.heatmapYear = $0 })
                ) { ForEach(years(s), id: \.self) { Text(String($0)).tag($0) } }.labelsHidden()
            }
            Picker("Calendar metric", selection: $heatmapTime) {
                Text("Reviews").tag(false)
                Text("Active minutes").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("statisticsCalendarMetric")
            StatisticsHeatmap(points: heatmapTime ? s.timeHeatmap : s.heatmap, onSelect: { selectDay($0) })
            StatisticsTimeChart(
                title: "Reviews",
                points: s.daily.filter { ["New", "Learning", "Review", "Relearning"].contains($0.series) },
                onSelect: { selectInterval($0) })
            StatisticsTimeChart(title: "Upcoming scheduled cards", points: Array(s.due.prefix(30)))
            Text(
                "Upcoming cards show current due dates, including backlog in today's bucket. Simulated repeat workload is under Workload."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func activity(_ s: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            StatisticsTimeChart(
                title: "Reviews by phase",
                points: s.daily.filter { ["New", "Learning", "Review", "Relearning"].contains($0.series) },
                onSelect: { selectInterval($0) })
            StatisticsTimeChart(
                title: "Active minutes", points: s.daily.filter { $0.series == "Active minutes" })
            StatisticsTimeChart(
                title: "Cumulative reviews", points: s.daily.filter { $0.series == "Cumulative reviews" },
                lines: true)
            StatisticsTimeChart(
                title: "Cumulative minutes", points: s.daily.filter { $0.series == "Cumulative minutes" },
                lines: true)
            StatisticsBarChart(title: "Answer grades", bins: s.grades, onSelect: { selectedGrade = $0 })
            StatisticsHourChart(points: s.hours)
            StatisticsTimeChart(
                title: "New cards introduced", points: s.daily.filter { $0.series == "New introductions" })
            StatisticsBarChart(title: "Reviews by deck", bins: s.comparisons)
            StatisticsBarChart(title: "Reviews by skill", bins: s.skillComparisons)
            StatisticsBarChart(title: "Reviews by answer method", bins: s.methodComparisons)
            StatisticsBarChart(title: "Graded-attempt duration", bins: s.durations)
            Text(
                "Median: \(seconds(s.durationMedian)) · 90th percentile: \(seconds(s.durationP90)) · \(s.excludedDurations) unusable duration samples excluded. Active time also includes unfinished attempts."
            ).font(.caption).foregroundStyle(.secondary)
            let split = s.reviews.filter { $0.promptMilliseconds != nil }
            if !split.isEmpty {
                Text(
                    "Active prompt time: "
                        + LearningTimeFormat.duration(split.compactMap(\.promptMilliseconds).reduce(0, +))
                        + " · answer/checking: "
                        + LearningTimeFormat.duration(split.compactMap(\.answerMilliseconds).reduce(0, +))
                ).font(.subheadline)
            }
            sessionList(s)
            reviewList(s)
        }
    }
    private func memory(_ s: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Current memory · as of \(s.asOf.formatted(date:.abbreviated,time:.shortened))").font(
                .subheadline
            ).foregroundStyle(.secondary)
            StatisticsBarChart(title: "Card progress", bins: s.phases)
            Text(
                "Estimated remembered cards: \(s.estimatedRemembered.formatted(.number.precision(.fractionLength(1)))). This sums FSRS recall probabilities, not independently proven facts."
            ).font(.subheadline)
            StatisticsTimeChart(title: "Observed spaced recall (%)", points: s.recall, lines: true)
            if let lower = s.recallLower, let upper = s.recallUpper {
                Text(
                    "95% interval: \(lower.formatted(.percent.precision(.fractionLength(1))))–\(upper.formatted(.percent.precision(.fractionLength(1)))) · \(s.recallTotal) first spaced reviews. Again fails; Hard, Good and Easy pass."
                ).font(.caption).foregroundStyle(.secondary)
            }
            StatisticsTimeChart(title: "Maintaining history", points: s.progress, lines: true)
            StatisticsCohortChart(points: s.cohorts)
            StatisticsBarChart(title: "Time to first Maintaining milestone", bins: s.milestoneDurations)
            StatisticsBarChart(
                title: "Stability (days)", bins: s.stability,
                onSelect: { inspect(s, metric: "stability", label: $0) })
            StatisticsBarChart(
                title: "Difficulty", bins: s.difficulty,
                onSelect: { inspect(s, metric: "difficulty", label: $0) })
            StatisticsBarChart(
                title: "Estimated recall probability now", bins: s.retrievability,
                onSelect: { inspect(s, metric: "retrievability", label: $0) })
            StatisticsBarChart(
                title: "Current scheduled intervals", bins: s.intervals,
                onSelect: { inspect(s, metric: "intervals", label: $0) })
            StatisticsBarChart(
                title: "Lapses", bins: s.lapses, onSelect: { inspect(s, metric: "lapses", label: $0) })
            StatisticsBarChart(
                title: "Observed recall by predicted probability (%)", bins: s.calibration, percent: true)
            StatisticsBarChart(title: "Recall by elapsed interval (%)", bins: s.intervalRecall, percent: true)
            StatisticsBarChart(title: "Recall by lateness (%)", bins: s.latenessRecall, percent: true)
            Text("Lateness includes only spaced reviews with a recorded prior due date.")
                .font(.caption).foregroundStyle(.secondary)
            StatisticsDensityChart(cards: s.cards)
            Text("Cards to inspect").font(.headline)
            ForEach(s.attentionReviews) { review in reviewButton(review) }
            Text(
                "Longer attempts and repeated lapses can help identify cards to improve. Small samples and time-of-day differences do not establish causes."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func workload(_ s: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            StatisticsTimeChart(title: "Current scheduled due dates · next year", points: s.due)
            StatisticsBarChart(title: "Overdue backlog age", bins: s.backlog)
            if let duration = s.durationMedian {
                Text(
                    "Estimated time for today's scheduled cards: \(((s.due.filter {Calendar.current.isDate($0.date,inSameDayAs:s.asOf)}.reduce(0) {$0+$1.value})*duration/60000).formatted(.number.precision(.fractionLength(1)))) minutes, using your median graded-attempt duration. Repeated attempts can add work."
                ).font(.subheadline)
            }
            Divider()
            Text("What-if scenario").font(.title3.weight(.semibold))
            Picker("Horizon", selection: $model.forecastRequest.days) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }.pickerStyle(.segmented)
            Toggle("Choose new-card pace", isOn: $customPace).onChange(of: customPace) { _, enabled in
                model.forecastRequest.newCardsPerDay = enabled ? 10 : nil
            }
            if customPace {
                Stepper(
                    "New cards per day: \(model.forecastRequest.newCardsPerDay ?? 10)",
                    value: Binding(
                        get: { model.forecastRequest.newCardsPerDay ?? 10 },
                        set: { model.forecastRequest.newCardsPerDay = $0 }), in: 0...1000)
            }
            Toggle("Choose desired retention", isOn: $customRetention).onChange(of: customRetention) {
                _, enabled in model.forecastRequest.desiredRetention = enabled ? 0.9 : nil
            }
            if customRetention {
                Slider(
                    value: Binding(
                        get: { model.forecastRequest.desiredRetention ?? 0.9 },
                        set: { model.forecastRequest.desiredRetention = $0 }), in: 0.7...0.99, step: 0.01
                ) { Text("Desired retention") }
                Text(
                    "Desired retention: \((model.forecastRequest.desiredRetention ?? 0.9).formatted(.percent))"
                )
            }
            HStack {
                Button("Run Scenario", systemImage: "play") { Task { await model.simulate() } }.buttonStyle(
                    .borderedProminent
                ).disabled(model.isForecasting)
                if model.isForecasting {
                    ProgressView()
                    Button("Cancel") { model.cancelForecast() }
                }
            }
            Text("Read-only model. Your cards, due dates and settings are never changed.").font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.forecastError { Text(error).foregroundStyle(.secondary) }
            if let forecast = model.forecast {
                StatisticsForecastChart(forecast: forecast, baseline: model.baselineForecast)
            }
        }.onChange(of: model.forecastRequest) { _, _ in model.cancelForecast() }
    }
    private func sessionList(_ s: StatisticsSnapshot) -> some View {
        DisclosureGroup("Sessions (\(s.sessions.count))") {
            ForEach(s.sessions.prefix(100)) { session in
                Button {
                    model.query.sessionID = session.id
                    model.query.period = .all
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.date, format: .dateTime.month().day().hour().minute())
                        Text(
                            "\(LearningTimeFormat.duration(session.milliseconds)) · \(session.reviews) linked reviews · \(session.cards) cards · \(session.items) items · \(session.submissions) saved responses"
                        ).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
        }
    }
    private func reviewList(_ s: StatisticsSnapshot) -> some View {
        let rows = s.reviews.filter { review in
            (selectedInterval == nil
                || (review.log.reviewedAt >= selectedInterval!.start
                    && review.log.reviewedAt < selectedInterval!.end))
                && (selectedGrade == nil
                    || String(describing: review.log.rating).capitalized == selectedGrade)
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review history (\(rows.count))").font(.headline)
                Spacer()
                if selectedInterval != nil || selectedGrade != nil {
                    Button("Clear selection") {
                        selectedInterval = nil
                        selectedGrade = nil
                    }
                }
            }
            ForEach(rows.prefix(visibleReviews)) { review in reviewButton(review) }
            if rows.count > visibleReviews { Button("Show more") { visibleReviews += 100 } }
        }
    }
    private func reviewButton(_ review: StatisticsReview) -> some View {
        Button {
            selectedReview = review
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.deckName)
                    Text(review.log.reviewedAt, format: .dateTime.month().day().hour().minute()).font(
                        .caption
                    ).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(describing: review.log.rating).capitalized)
                Text("\(Double(review.log.durationMs)/1000,format:.number.precision(.fractionLength(1)))s")
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }.buttonStyle(.plain)
    }
    private func inspect(_ s: StatisticsSnapshot, metric: String, label: String) {
        let bins: [StatisticsBin]
        switch metric {
        case "difficulty": bins = s.difficulty
        case "retrievability": bins = s.retrievability
        case "lapses": bins = s.lapses
        case "intervals": bins = s.intervals
        default: bins = s.stability
        }
        let ids = Set(bins.first(where: { $0.label == label })?.cardIDs ?? [])
        let rows = s.cards.filter { ids.contains($0.card.id) }
        selectedCardGroup = StatisticsCardGroup(title: "\(metric.capitalized): \(label)", cards: rows)
    }
    private func reviewDetail(_ review: StatisticsReview) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LabeledContent("Reviewed", value: review.log.reviewedAt.formatted())
                    LabeledContent("Grade", value: String(describing: review.log.rating).capitalized)
                    LabeledContent("Deck", value: review.deckName)
                    LabeledContent("Skill", value: review.skill)
                    LabeledContent("Answer method", value: review.interaction)
                    LabeledContent("Elapsed days", value: review.log.elapsedDays.formatted())
                    if let state = review.after {
                        Text("Estimated forgetting curve after this review").font(.headline)
                        StatisticsForgettingCurve(memory: state)
                        Text(
                            "Illustrative curve uses population parameters and the recorded stability. It is an estimate, not a recall test."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Card history in the selected period").font(.headline)
                    ForEach(model.snapshot?.reviews.filter { $0.log.cardID == review.log.cardID } ?? []) {
                        item in
                        HStack {
                            Text(item.log.reviewedAt, format: .dateTime.month().day())
                            Spacer()
                            Text(String(describing: item.log.rating).capitalized)
                        }
                    }
                }.padding(24)
            }.navigationTitle("Review Details").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { selectedReview = nil } }
            }
        }.frame(minWidth: 300, minHeight: 400)
    }
    private func selectDay(_ date: Date) {
        let start = StudyDay.start(for: date.addingTimeInterval(12 * 3600), rolloverMinutes: model.rollover)
        selectInterval(
            DateInterval(
                start: start, end: StudyDay.nextRollover(after: start, rolloverMinutes: model.rollover)))
    }
    private func selectInterval(_ interval: DateInterval) {
        model.query.period = .custom
        model.query.customStart = interval.start
        model.query.customEnd = interval.end.addingTimeInterval(-1)
        selectedInterval = interval
        model.section = .activity
    }
    private func seconds(_ value: Double?) -> String {
        value.map { "\(($0/1000).formatted(.number.precision(.fractionLength(1))))s" } ?? "—"
    }
    private func years(_ s: StatisticsSnapshot) -> [Int] {
        Array(
            Calendar.current.component(
                .year, from: s.coverage.historyStartedAt ?? .now)...Calendar.current.component(
                    .year, from: .now)
        ).reversed()
    }
}

private struct StatisticsCardGroup: Identifiable {
    let id = UUID()
    let title: String
    let cards: [StatisticsCard]
}
private struct StatisticsCardInspector: View {
    let group: StatisticsCardGroup
    @Environment(\.dismiss) private var dismiss
    @State private var limit = 100
    var body: some View {
        NavigationStack {
            List {
                Text("\(group.cards.count) matching cards").font(.headline)
                ForEach(Array(group.cards.prefix(limit)), id: \.card.id) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Card \(entry.card.id.uuidString.prefix(8))").font(.headline)
                        Text(
                            "Stability \(entry.card.memory.stability.formatted()) days · difficulty \(entry.card.memory.difficulty.formatted()) · lapses \(entry.card.memory.lapses)"
                        ).font(.caption)
                        Text("Due \(entry.card.memory.due.formatted())").font(.caption).foregroundStyle(
                            .secondary)
                        if let url = URL(string: "neoanki2://item/\(entry.card.itemID)") {
                            Link("Open Item", destination: url)
                        }
                    }.padding(.vertical, 6)
                }
                if group.cards.count > limit { Button("Show more") { limit += 100 } }
            }.navigationTitle(group.title).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }.frame(minWidth: 300, minHeight: 400)
    }
}
