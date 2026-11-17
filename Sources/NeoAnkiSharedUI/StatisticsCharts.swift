import Charts
import Foundation
import NeoAnkiCore
import SwiftUI

private struct StatisticsExportKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Void = { _ in }
}
extension EnvironmentValues {
    var statisticsExportCSV: @MainActor (String) -> Void {
        get { self[StatisticsExportKey.self] }
        set { self[StatisticsExportKey.self] = newValue }
    }
}

/// Hover/selection details occupy the same space in every state, so later
/// charts keep their positions as the pointer moves across a chart.
struct StatisticsChartSelection: View {
    let text: String?
    var onSelect: () -> Void = {}
    var body: some View {
        Group {
            if let text {
                Button(action: onSelect) {
                    Text(text).lineLimit(2, reservesSpace: true)
                }.buttonStyle(.plain).accessibilityHint("Show matching details")
                    .accessibilityIdentifier("statisticsSelectedValue")
            } else {
                Text("Select a value for details")
                    .lineLimit(2, reservesSpace: true).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
    }
    private var minimumHeight: CGFloat {
        #if os(macOS)
            28
        #else
            44
        #endif
    }

}

struct StatisticsTimeChart: View {
    @Environment(\.statisticsExportCSV) private var export
    let title: String
    let points: [StatisticsPoint]
    var lines = false
    var onSelect: ((DateInterval) -> Void)?
    @State private var selected: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Export") { export(StatisticsExport.points(points)) }.font(.caption)
            }
            if points.isEmpty {
                Text("No data in this period").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        if lines {
                            LineMark(x: .value("Date", point.date), y: .value(title, point.value))
                                .foregroundStyle(by: .value("Series", point.series))
                            PointMark(x: .value("Date", point.date), y: .value(title, point.value))
                                .foregroundStyle(by: .value("Series", point.series)).symbolSize(14)
                        } else {
                            BarMark(x: .value("Date", point.date), y: .value(title, point.value))
                                .foregroundStyle(by: .value("Series", point.series))
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected date", selected)).foregroundStyle(.secondary)
                    }
                }
                .chartForegroundStyleScale(
                    domain: Array(Set(points.map(\.series))).sorted(),
                    range: Array(Set(points.map(\.series))).sorted().map { seriesColor($0) }
                )
                .chartXSelection(value: $selected)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: axisDayStride)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 220)
                StatisticsChartSelection(text: selectedDescription) {
                    if let date = selectedDate {
                        onSelect?(
                            DateInterval(
                                start: date,
                                end: points.first(where: { $0.date == date })?.intervalEnd
                                    ?? Calendar.current.date(byAdding: .day, value: 1, to: date)!))
                    }
                }
                DisclosureGroup("Data table") {
                    ForEach(points.suffix(400)) { point in
                        HStack {
                            Text(point.date, format: .dateTime.year().month().day())
                            Text(point.series)
                            Spacer()
                            Text(point.value, format: .number.precision(.fractionLength(0...1)))
                        }.font(.caption)
                    }
                }.font(.caption)
            }
        }.accessibilityElement(children: .contain)
    }
    private var axisDayStride: Int {
        let dates = points.map(\.date)
        let days = (dates.max() ?? .now).timeIntervalSince(dates.min() ?? .now) / 86400
        return max(1, Int(ceil(days / 5)))
    }
    private var selectedDate: Date? {
        guard let selected else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
        }?.date
    }
    private var selectedDescription: String? {
        guard let date = selectedDate else { return nil }
        return "\(date.formatted(date: .abbreviated, time: .omitted)): "
            + points.filter { $0.date == date }.map {
                "\($0.series) \($0.value.formatted(.number.precision(.fractionLength(0...1))))"
            }.joined(separator: ", ")
    }

}

private func seriesColor(_ series: String) -> Color {
    switch series {
    case "New": .gray
    case "Learning": .orange
    case "Review": .blue
    case "Relearning": .red
    default: .blue
    }
}

struct StatisticsBarChart: View {
    @Environment(\.statisticsExportCSV) private var export
    let title: String
    let bins: [StatisticsBin]
    var percent = false
    var onSelect: ((String) -> Void)?
    @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Export") { export(StatisticsExport.bins(bins, title: title)) }.font(
                    .caption)
            }
            if bins.isEmpty || bins.allSatisfy({ $0.value == 0 && (!percent || $0.count == 0) }) {
                Text("Not enough data yet").foregroundStyle(.secondary)
            } else {
                if horizontal {
                    Chart(bins) { bin in
                        BarMark(
                            x: .value(title, bin.value), y: .value("Category", bin.label),
                            height: .fixed(18)
                        )
                        .foregroundStyle(Color.accentColor)
                        if percent {
                            PointMark(x: .value(title, bin.value), y: .value("Category", bin.label))
                                .foregroundStyle(Color.accentColor).symbolSize(12)
                        }
                    }
                    .chartYScale(domain: Array(bins.map(\.label)))
                    .chartYSelection(value: $selected)
                    .chartYAxis {
                        AxisMarks(preset: .aligned, position: .leading, values: bins.map(\.label)) {
                            value in
                            AxisValueLabel {
                                if let label = value.as(String.self) {
                                    Text(label).font(.caption2).lineLimit(2).frame(
                                        width: 130, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .frame(height: max(180, CGFloat(bins.count) * 26))
                } else {
                    Chart(bins) { bin in
                        BarMark(x: .value("Category", bin.label), y: .value(title, bin.value))
                            .foregroundStyle(Color.accentColor)
                        if percent {
                            PointMark(x: .value("Category", bin.label), y: .value(title, bin.value))
                                .foregroundStyle(Color.accentColor).symbolSize(12)
                        }
                    }.chartXSelection(value: $selected).frame(height: 180)
                }
                StatisticsChartSelection(text: selectedDescription) {
                    if let selected { onSelect?(selected) }
                }
                DisclosureGroup("Data table") {
                    ForEach(bins) { bin in
                        HStack {
                            Text(bin.label)
                            Spacer()
                            Text(bin.value, format: .number.precision(.fractionLength(0...1)))
                            if bin.count > 0 { Text("n=\(bin.count)").foregroundStyle(.secondary) }
                        }.font(.caption)
                    }
                }.font(.caption)
            }
        }
    }
    private var horizontal: Bool {
        bins.count > 6 || bins.contains { $0.label.count > 18 }
    }
    private var selectedDescription: String? {
        guard let selected, let bin = bins.first(where: { $0.label == selected }) else {
            return nil
        }
        return
            "\(bin.label): \(bin.value.formatted(.number.precision(.fractionLength(0...1))))\(percent ? "%" : "")\(bin.count > 0 ? " · \(bin.count) samples" : "")"
    }

}

struct StatisticsHeatmap: View {
    @Environment(\.statisticsExportCSV) private var export
    let points: [StatisticsPoint]
    var onSelect: ((Date) -> Void)?
    @State private var selectedWeek: Double?
    @State private var selectedWeekday: Double?
    private var unit: String {
        points.first?.series == "Active minutes" ? "active minutes" : "reviews"
    }
    private let calendar = Calendar.autoupdatingCurrent
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Study calendar").font(.headline)
                Spacer()
                Button("Export") { export(StatisticsExport.points(points)) }.font(.caption)
            }
            StatisticsCalendarPlot(
                points: points, selectedWeek: $selectedWeek, selectedWeekday: $selectedWeekday)
            HStack(spacing: 6) {
                Text("Daily \(unit)")
                Spacer()
                Text("Less")
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.12), Color.accentColor],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 72, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
                Text("More")
            }.font(.caption2).foregroundStyle(.secondary)
            StatisticsChartSelection(
                text: selectedPoint.map {
                    "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
                }
            ) {
                if let point = selectedPoint { onSelect?(point.date) }
            }
            if !points.isEmpty && points.allSatisfy({ $0.value == 0 }) {
                Text("No \(unit) recorded in \(points[0].date.formatted(.dateTime.year())).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Days and exact values") {
                ForEach(points.filter { $0.value > 0 }.reversed()) { point in
                    Button {
                        onSelect?(point.date)
                    } label: {
                        HStack {
                            Text(point.date, format: .dateTime.year().month().day())
                            Spacer()
                            Text(
                                "\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
                            )
                        }
                    }.font(.caption)
                }
            }.font(.caption)
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("statisticsStudyCalendar")
    }
    private var selectedPoint: StatisticsPoint? {
        guard let selectedWeek, let selectedWeekday else { return nil }
        return points.first {
            layout.column($0.date) == Int(selectedWeek.rounded())
                && layout.row($0.date) == Int(selectedWeekday.rounded())
        }
    }
    private var layout: StatisticsCalendarLayout { .init(points: points, calendar: calendar) }

}

struct StatisticsForecastChart: View {
    @Environment(\.statisticsExportCSV) private var export
    let forecast: StatisticsForecast
    var baseline: StatisticsForecast?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Simulated reviews · median and 10th–90th percentile").font(.headline)
                Spacer()
                Button("Export") {
                    var csv = StatisticsExport.forecast(forecast)
                    if let baseline {
                        csv +=
                            "\n"
                            + StatisticsExport.forecast(baseline, prefix: "Current settings: ")
                            .split(
                                separator: "\n"
                            ).dropFirst().joined(separator: "\n")
                    }
                    export(csv)
                }.font(.caption)
            }
            Chart {
                ForEach(forecast.points) { point in
                    AreaMark(
                        x: .value("Day", point.date), yStart: .value("Lower", point.lower),
                        yEnd: .value("Upper", point.upper)
                    ).foregroundStyle(Color.accentColor.opacity(0.18))
                    LineMark(x: .value("Day", point.date), y: .value("Reviews", point.median))
                        .foregroundStyle(Color.accentColor)
                }
                if let baseline {
                    ForEach(baseline.points) { point in
                        LineMark(
                            x: .value("Day", point.date), y: .value("Reviews", point.median),
                            series: .value("Scenario", "Current settings")
                        ).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [5, 3]))
                    }
                }
            }.frame(height: 230)
            if baseline != nil {
                Text("Solid: selected scenario · dashed: current settings").font(.caption)
            }
            Text(forecast.assumptions).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Daily forecast table") {
                ForEach(forecast.points) { point in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(point.date, format: .dateTime.month().day()).font(.subheadline)
                        Text(
                            "\(point.median.formatted(.number.precision(.fractionLength(0)))) reviews (\(point.lower.formatted(.number.precision(.fractionLength(0))))–\(point.upper.formatted(.number.precision(.fractionLength(0))))) · "
                                + (point.minutes.map {
                                    "\($0.formatted(.number.precision(.fractionLength(1)))) min"
                                } ?? "Time unavailable"))
                        Text(
                            "Backlog \(Int(point.backlog)) · estimated remembered \(Int(point.remembered))"
                        )
                    }.font(.caption).padding(.vertical, 4)
                }
            }.font(.caption)
        }
    }
}

struct StatisticsCohortChart: View {
    @Environment(\.statisticsExportCSV) private var export
    let points: [StatisticsPoint]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Introduction cohorts · reached Maintaining (%)").font(.headline)
                Spacer()
                Button("Export") { export(StatisticsExport.points(points)) }.font(.caption)
            }
            if points.isEmpty {
                Text("Cohorts appear after cards are introduced.").foregroundStyle(.secondary)
            } else {
                let months = Array(Set(points.map(\.date))).sorted()
                let lastAge = points.compactMap { Int($0.series) }.max() ?? 0
                let cells = points.map { point in
                    StatisticsMatrixCell(
                        column: Int(point.series) ?? 0,
                        row: months.firstIndex(of: point.date) ?? 0, value: point.value,
                        label:
                            "\(point.date.formatted(.dateTime.year().month())), month \(point.series), \(point.count) cards"
                    )
                }
                StatisticsMatrixPlot(
                    cells: cells, columns: (0...lastAge).map(String.init),
                    rows: months.map { $0.formatted(.dateTime.year().month(.abbreviated)) },
                    unit: "%", maximum: 100, height: max(160, CGFloat(months.count) * 24 + 32))
                Text(
                    "Each row groups cards by their first introduction month. Columns show how many reached their first Maintaining milestone by each month of age; later regressions do not erase this milestone."
                ).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Cohort table") {
                    ForEach(points) { point in
                        HStack {
                            Text(point.date, format: .dateTime.year().month())
                            Text("Month \(point.series)")
                            Spacer()
                            Text("\(Int(point.value))% · n=\(point.count)")
                        }.font(.caption)
                    }
                }
            }
        }
    }
}
