import Charts
import Foundation
import NeoAnkiCore
import SwiftUI

struct StatisticsMatrixCell: Identifiable, Sendable {
    let column: Int
    let row: Int
    let value: Double
    let label: String
    var id: String { "\(column):\(row)" }
}

/// Explicit numeric cell bounds avoid the tiny fallback marks that continuous
/// chart axes otherwise use. Swift Charts still owns scales, axes and rendering.
struct StatisticsMatrixPlot: View {
    let cells: [StatisticsMatrixCell]
    let columns: [String]
    let rows: [String]
    let unit: String
    var maximum: Double?
    var height: CGFloat = 200
    private var peak: Double { max(1, maximum ?? cells.map(\.value).max() ?? 0) }
    private var columnTicks: [Int] {
        let step = max(1, Int(ceil(Double(columns.count) / 8)))
        return Array(
            Set(Array(stride(from: 0, to: columns.count, by: step)) + [max(0, columns.count - 1)])
        ).sorted()
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            plot
            legend
        }
    }
    private func mark(_ cell: StatisticsMatrixCell) -> some ChartContent {
        let description = cell.value.formatted(.number.precision(.fractionLength(0...1))) + " " + unit
        return RectangleMark(
            xStart: .value("Column", Double(cell.column) - 0.44),
            xEnd: .value("Column", Double(cell.column) + 0.44),
            yStart: .value("Row", Double(cell.row) - 0.44),
            yEnd: .value("Row", Double(cell.row) + 0.44)
        )
        .foregroundStyle(by: .value(unit, cell.value))
        .accessibilityLabel(Text(cell.label))
        .accessibilityValue(Text(description))
    }
    private var plot: some View {
        Chart(cells) { cell in mark(cell) }
            .chartForegroundStyleScale(domain: 0...peak,
                range: Gradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor]))
            .chartLegend(.hidden)
            .chartXScale(domain: -0.5...(Double(max(1, columns.count)) - 0.5))
            .chartYScale(domain: [Double(max(1, rows.count)) - 0.5, -0.5])
            .chartXAxis {
                AxisMarks(values: columnTicks.map(Double.init)) { value in
                    AxisValueLabel {
                        if let index = value.as(Double.self), columns.indices.contains(Int(index)) {
                            Text(columns[Int(index)]).font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: rows.indices.map(Double.init)) { value in
                    AxisValueLabel {
                        if let index = value.as(Double.self), rows.indices.contains(Int(index)) {
                            Text(rows[Int(index)]).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: height)
    }
    private var legend: some View {
        HStack(spacing: 6) {
            Text("0")
            LinearGradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: 72, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(peak.formatted(.number.precision(.fractionLength(0...1))) + " " + unit)
        }.font(.caption2).foregroundStyle(.secondary)
    }
}

struct StatisticsHourChart: View {
    @Environment(\.statisticsExportCSV) private var export
    let points: [StatisticsPoint]
    var calendar: Calendar = .autoupdatingCurrent
    private var weekdayNumbers: [Int] { (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 } }
    private var cells: [StatisticsMatrixCell] {
        let values = Dictionary(grouping: points) { "\($0.series):\($0.count)" }
            .mapValues { $0.reduce(0) { $0 + $1.value } }
        return weekdayNumbers.enumerated().flatMap { row, weekday in
            (0..<24).map { hour in
                StatisticsMatrixCell(
                    column: hour, row: row, value: values["\(weekday):\(hour)", default: 0],
                    label: "\(calendar.weekdaySymbols[weekday - 1]) \(hour):00")
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reviews by weekday and hour").font(.headline)
                Spacer()
                Button("Export") {
                    export(
                        StatisticsExport.bins(
                            cells.map { .init($0.label, $0.value) }, title: "Weekday and hour"))
                }.font(.caption)
            }
            if points.isEmpty {
                Text("No reviews in this period").foregroundStyle(.secondary)
            } else {
                StatisticsMatrixPlot(
                    cells: cells, columns: (0..<24).map { String(format: "%02d", $0) },
                    rows: weekdayNumbers.map { calendar.shortWeekdaySymbols[$0 - 1] },
                    unit: "reviews",
                    height: 200)
                Text("Local hour of day. This describes when you studied, not when you learn best.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Data table") {
                    ForEach(cells.filter { $0.value > 0 }) { cell in
                        HStack {
                            Text(cell.label)
                            Spacer()
                            Text(cell.value, format: .number)
                        }.font(.caption)
                    }
                }.font(.caption)
            }
        }
    }
}

struct StatisticsDensityChart: View {
    @Environment(\.statisticsExportCSV) private var export
    let cards: [StatisticsCard]
    private var studied: [StatisticsCard] {
        cards.filter { $0.card.memory.reps > 0 && $0.card.memory.stability > 0 }
    }
    private var magnitudes: [Int] {
        let values = studied.map { Int(floor(log10(max(0.01, $0.card.memory.stability)))) }
        guard let low = values.min(), let high = values.max() else { return [] }
        return Array((low...high).reversed())
    }
    private func stabilityLabel(_ magnitude: Int) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        return
            "\(pow(10, Double(magnitude)).formatted(format))–\(pow(10, Double(magnitude + 1)).formatted(format))d"
    }
    private var cells: [StatisticsMatrixCell] {
        let groups = Dictionary(grouping: studied) {
            "\(Int($0.card.memory.difficulty)):\(Int(floor(log10(max(0.01, $0.card.memory.stability)))))"
        }
        return magnitudes.enumerated().flatMap { row, magnitude in
            (1...10).map { difficulty in
                StatisticsMatrixCell(
                    column: difficulty - 1, row: row,
                    value: Double(groups["\(difficulty):\(magnitude)"]?.count ?? 0),
                    label: "Difficulty \(difficulty), stability \(stabilityLabel(magnitude))")
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stability versus difficulty · current card density").font(.headline)
                Spacer()
                Button("Export") {
                    export(
                        StatisticsExport.bins(
                            cells.map { .init($0.label, $0.value) }, title: "Current card density"))
                }.font(.caption)
            }
            if studied.isEmpty {
                Text("No studied cards in this scope").foregroundStyle(.secondary)
            } else {
                StatisticsMatrixPlot(
                    cells: cells, columns: (1...10).map { $0 == 10 ? "10" : "\($0)–\($0 + 1)" },
                    rows: magnitudes.map(stabilityLabel), unit: "cards",
                    height: max(180, CGFloat(magnitudes.count) * 28 + 32))
                Text(
                    "Columns group difficulty into whole-number bands; rows show stability ranges in days. All studied cards, including suspended cards, are included."
                )
                .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Data table") {
                    ForEach(cells.filter { $0.value > 0 }) { cell in
                        HStack {
                            Text(cell.label)
                            Spacer()
                            Text("\(Int(cell.value)) cards")
                        }.font(.caption)
                    }
                }.font(.caption)
            }
        }
    }
}

struct StatisticsForgettingCurve: View {
    let memory: MemoryState
    var body: some View {
        Chart(0..<91, id: \.self) { day in
            LineMark(
                x: .value("Days", day),
                y: .value(
                    "Recall probability",
                    FSRSScheduler().retrievability(
                        elapsedDays: Double(day), stability: memory.stability)
                        * 100))
        }.chartYScale(domain: 0...100).frame(height: 220)
    }
}
