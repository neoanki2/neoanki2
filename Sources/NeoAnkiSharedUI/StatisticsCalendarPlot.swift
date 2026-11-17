import Charts
import Foundation
import NeoAnkiCore
import SwiftUI

/// Calendar coordinates use the user's first weekday, including partial weeks
/// at either end of the year. The chart library owns drawing and scrolling.
struct StatisticsCalendarLayout {
    let points: [StatisticsPoint]
    var calendar: Calendar = .autoupdatingCurrent
    private var yearStart: Date {
        calendar.dateInterval(of: .year, for: points.first?.date ?? .now)!.start
    }
    func row(_ date: Date) -> Int {
        (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
    }
    func column(_ date: Date) -> Int {
        ((calendar.ordinality(of: .day, in: .year, for: date) ?? 1) - 1 + row(yearStart)) / 7
    }
    var weekCount: Int { (points.last.map { column($0.date) } ?? 0) + 1 }
    var months: [StatisticsPoint] { points.filter { calendar.component(.day, from: $0.date) == 1 } }
    func weekday(_ row: Int) -> String {
        calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7]
    }
}

struct StatisticsCalendarMetrics {
    let visibleWeeks: Int
    let cellSide: CGFloat
    let height: CGFloat
    init(width: CGFloat, weeks: Int, minimumCell: CGFloat, axisWidth: CGFloat, axisHeight: CGFloat) {
        let plotWidth = max(minimumCell, width - axisWidth)
        visibleWeeks = min(weeks, max(1, Int(plotWidth / minimumCell)))
        cellSide = plotWidth / CGFloat(visibleWeeks)
        height = cellSide * 7 + axisHeight
    }
}

/// Measures from available width without a state update or a hover-dependent
/// height. Compact charts scroll natively; their weekday axis stays visible.
private struct CalendarSizing: Layout {
    let weeks: Int
    let minimumCell: CGFloat
    let axisWidth: CGFloat
    let axisHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? 680
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : 680
        let metrics = StatisticsCalendarMetrics(
            width: width, weeks: weeks, minimumCell: minimumCell,
            axisWidth: axisWidth, axisHeight: axisHeight)
        return CGSize(width: width, height: metrics.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(
                at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

struct StatisticsCalendarPlot: View {
    let points: [StatisticsPoint]
    var calendar: Calendar = .autoupdatingCurrent
    @Binding var selectedWeek: Double?
    @Binding var selectedWeekday: Double?
    @ScaledMetric(relativeTo: .caption2) private var minimumCell = 10.0
    @ScaledMetric(relativeTo: .caption2) private var axisWidth = 36.0
    @ScaledMetric(relativeTo: .caption2) private var axisHeight = 24.0
    private var layout: StatisticsCalendarLayout { .init(points: points, calendar: calendar) }
    var body: some View {
        CalendarSizing(
            weeks: layout.weekCount, minimumCell: minimumCell,
            axisWidth: axisWidth, axisHeight: axisHeight
        ) {
            GeometryReader { geometry in
                let metrics = StatisticsCalendarMetrics(
                    width: geometry.size.width, weeks: layout.weekCount,
                    minimumCell: minimumCell, axisWidth: axisWidth, axisHeight: axisHeight)
                let plot = chart(metrics: metrics)
                if metrics.visibleWeeks < layout.weekCount {
                    plot.chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: Double(metrics.visibleWeeks))
                        .chartScrollPosition(initialX: -0.5)
                } else {
                    plot
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statisticsCalendarPlot")
    }
    private func chart(metrics: StatisticsCalendarMetrics) -> some View {
        Chart(points) { point in
            let column = Double(layout.column(point.date))
            let row = Double(layout.row(point.date))
            RectangleMark(
                xStart: .value("Week", column - 0.42), xEnd: .value("Week", column + 0.42),
                yStart: .value("Weekday", row - 0.42), yEnd: .value("Weekday", row + 0.42)
            )
            .foregroundStyle(by: .value(point.series, point.value))
            .accessibilityLabel(point.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(
                "\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(point.series.lowercased())"
            )
        }
        .chartForegroundStyleScale(
            domain: 0...max(1, points.map(\.value).max() ?? 0),
            range: Gradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor])
        )
        .chartLegend(.hidden)
        .chartXScale(domain: -0.5...(Double(layout.weekCount) - 0.5))
        .chartYScale(domain: [6.5, -0.5])
        .chartXAxis {
            AxisMarks(position: .top, values: layout.months.map { Double(layout.column($0.date)) }) { value in
                if let column = value.as(Double.self),
                    let month = layout.months.first(where: { layout.column($0.date) == Int(column) })
                {
                    AxisValueLabel(anchor: .leading) {
                        Text(month.date, format: .dateTime.month(.abbreviated)).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 2, 4]) { value in
                AxisValueLabel {
                    if let row = value.as(Double.self) {
                        Text(layout.weekday(Int(row))).font(.caption2)
                    }
                }
            }
        }
        .chartPlotStyle { plot in plot.frame(height: metrics.cellSide * 7) }
        .chartXSelection(value: $selectedWeek)
        .chartYSelection(value: $selectedWeekday)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { event in
                proxy.selectXValue(at: event.location.x)
                proxy.selectYValue(at: event.location.y)
            }
        }
    }
}
