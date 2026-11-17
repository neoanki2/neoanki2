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
                Chart(points) { point in
                    if lines {
                        LineMark(x: .value("Date", point.date), y: .value(title, point.value))
                            .foregroundStyle(by: .value("Series", point.series))
                    } else {
                        BarMark(x: .value("Date", point.date), y: .value(title, point.value))
                            .foregroundStyle(by: .value("Series", point.series))
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
                .frame(height: 220)
                if let selected {
                    let date = points.min {
                        abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
                    }?.date
                    if let date {
                        Button(
                            "\(date.formatted(date:.abbreviated,time:.omitted)): "
                                + points.filter { $0.date == date }.map {
                                    "\($0.series) \($0.value.formatted(.number.precision(.fractionLength(0...1))))"
                                }.joined(separator: ", ")
                        ) {
                            onSelect?(
                                DateInterval(
                                    start: date,
                                    end: points.first(where: { $0.date == date })?.intervalEnd ?? Calendar
                                        .current.date(byAdding: .day, value: 1, to: date)!))
                        }
                        .buttonStyle(.plain).font(.caption).accessibilityHint("Show matching reviews")
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
                Button("Export") { export(StatisticsExport.bins(bins, title: title)) }.font(.caption)
            }
            if bins.isEmpty {
                Text("Not enough data yet").foregroundStyle(.secondary)
            } else {
                Chart(bins) { bin in
                    BarMark(x: .value("Category", bin.label), y: .value(title, bin.value))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(bin.label)
                        .accessibilityValue(
                            "\(bin.value.formatted())\(percent ? " percent" : ""), \(bin.count) samples")
                }.chartXSelection(value: $selected).frame(height: 180)
                if let selected, let bin = bins.first(where: { $0.label == selected }) {
                    Button(
                        "\(bin.label): \(bin.value.formatted(.number.precision(.fractionLength(0...1))))\(percent ? "%" : "")\(bin.count > 0 ? " · \(bin.count) samples" : "")"
                    ) { onSelect?(selected) }.buttonStyle(.plain).font(.caption)
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
}

struct StatisticsHeatmap: View {
    @Environment(\.statisticsExportCSV) private var export
    let points: [StatisticsPoint]
    var onSelect: ((Date) -> Void)?
    @State private var selectedWeek: Double?
    @State private var selectedWeekday: Double?
    private var unit: String { points.first?.series == "Active minutes" ? "active minutes" : "reviews" }
    private let calendar = Calendar.autoupdatingCurrent
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Study calendar").font(.headline)
                Spacer()
                Button("Export") { export(StatisticsExport.points(points)) }.font(.caption)
            }
            ScrollView(.horizontal) {
                calendarChart
            }
            if let selectedWeek, let selectedWeekday,
                let point = points.first(where: {
                    week($0.date) == Int(selectedWeek.rounded())
                        && calendar.component(.weekday, from: $0.date) == Int(selectedWeekday.rounded())
                })
            {
                Button(
                    "\(point.date.formatted(date:.abbreviated,time:.omitted)): \(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
                ) { onSelect?(point.date) }.buttonStyle(.plain).font(.caption)
            }
            Text("One cell per day; weeks across, weekdays down. Darker cells indicate more \(unit).").font(
                .caption
            )
            .foregroundStyle(.secondary)
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
                                "\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                        }
                    }.font(.caption)
                }
            }.font(.caption)
        }
    }
    var calendarChart: some View {
        Chart(points) { point in
            // Explicit bounds give each day area on continuous week/day scales.
            // Ratio dimensions have no categorical band to size against here.
            let column = Double(week(point.date))
            let row = Double(calendar.component(.weekday, from: point.date))
            RectangleMark(
                xStart: .value("Week", column - 0.42),
                xEnd: .value("Week", column + 0.42),
                yStart: .value("Weekday", row - 0.42),
                yEnd: .value("Weekday", row + 0.42)
            )
            .foregroundStyle(by: .value(unit.capitalized, point.value))
            .accessibilityLabel(point.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(
                "\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
        }
        .chartForegroundStyleScale(
            domain: 0...max(1, points.map(\.value).max() ?? 0),
            range: [Color.accentColor.opacity(0.12), Color.accentColor]
        )
        .chartXScale(domain: -0.5...(Double(lastWeek) + 0.5))
        .chartYScale(domain: [7.5, 0.5])
        .chartYAxis {
            AxisMarks(values: [1.0, 3, 5, 7]) { value in
                AxisValueLabel {
                    if let weekday = value.as(Double.self) {
                        Text(calendar.shortWeekdaySymbols[Int(weekday) - 1])
                    }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: 4)) }
        .chartXSelection(value: $selectedWeek)
        .chartYSelection(value: $selectedWeekday)
        .frame(minWidth: 680).frame(height: 160)
    }
    private var lastWeek: Int { points.last.map { week($0.date) } ?? 0 }
    private func week(_ date: Date) -> Int {
        guard let start = points.first?.date else { return 0 }
        return
            (calendar.ordinality(of: .day, in: .year, for: date)! - 1
            + calendar.component(.weekday, from: start) - 1) / 7
    }
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
                            + StatisticsExport.forecast(baseline, prefix: "Current settings: ").split(
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
            if baseline != nil { Text("Solid: selected scenario · dashed: current settings").font(.caption) }
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
                        Text("Backlog \(Int(point.backlog)) · estimated remembered \(Int(point.remembered))")
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
                Chart(points) { point in
                    RectangleMark(
                        x: .value("Months since introduction", Int(point.series) ?? 0),
                        y: .value("Introduction month", point.date.formatted(.dateTime.year().month()))
                    )
                    .foregroundStyle(by: .value("Reached Maintaining (%)", point.value))
                    .accessibilityValue("\(point.value.formatted()) percent of \(point.count) cards")
                }.chartForegroundStyleScale(
                    domain: 0...100, range: [Color.accentColor.opacity(0.1), Color.accentColor]
                ).frame(height: 220)
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
