import AppKit
import NeoAnkiCore
import SwiftUI
import Testing

@testable import NeoAnkiSharedUI

private func calendarFixture(series: String, active: Bool) throws -> [StatisticsPoint] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
    return (0..<365).map { day in
        StatisticsPoint(
            date: calendar.date(byAdding: .day, value: day, to: start)!,
            series: series, value: active ? Double(day % 9) : 0)
    }
}

@Test("Calendar full context renders labels, square cells, and continuous intensity")
func statisticsCalendarRendersDailyCells() async throws {
    for series in ["Reviews", "Active minutes"] {
        for active in [true, false] {
            for width in [659.0, 1_000.0] {
                for scheme in [ColorScheme.dark, .light] {
                    let points = try calendarFixture(series: series, active: active)
                    // Only SwiftUI capture needs the main actor. CPU-heavy pixel
                    // analysis must leave concurrent UI-model/sync tests free to run.
                    let image = try await MainActor.run {
                        let renderer = ImageRenderer(
                            content:
                                StatisticsHeatmap(points: points)
                                .frame(width: width).accentColor(.blue)
                                .padding(24)
                                .environment(\.colorScheme, scheme)
                                .background(scheme == .dark ? Color(white: 0.2) : .white))
                        renderer.scale = 2
                        let image = try #require(renderer.cgImage)
                        if let directory = ProcessInfo.processInfo.environment["NEOANKI_CALENDAR_RENDER_DIR"]
                        {
                            let output = URL(fileURLWithPath: directory, isDirectory: true)
                            try FileManager.default.createDirectory(
                                at: output, withIntermediateDirectories: true)
                            let png = try #require(
                                NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                            try png.write(
                                to: output.appendingPathComponent(
                                    "\(series)-\(active)-\(Int(width))-\(scheme).png"))
                        }
                        return image
                    }
                    // Inspect complete rendered cell components, not just the
                    // presence of some blue pixels in an isolated plot.
                    let components = try calendarCellComponents(image)
                    #expect(components.count == 365, "Every day must be visible in the full-year layout")
                    #expect(
                        components.allSatisfy { $0.aspect >= 0.75 && $0.aspect <= 1.3 },
                        "Daily cells must stay approximately square")
                    if active {
                        #expect(
                            Set(components.map(\.color)).count >= 8,
                            "Different daily values must have different intensities")
                    }
                }
            }
        }
    }
}

private struct CalendarCellComponent {
    let aspect: Double
    let color: UInt32
}
private func calendarCellComponents(_ image: CGImage) throws -> [CalendarCellComponent] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    func blue(_ index: Int) -> Bool {
        let offset = index * 4
        return Int(pixels[offset + 2]) > Int(pixels[offset]) + 15
            && Int(pixels[offset + 2]) > Int(pixels[offset + 1]) + 8
    }
    var seen = [Bool](repeating: false, count: width * height)
    var result: [CalendarCellComponent] = []
    for index in seen.indices where !seen[index] && blue(index) {
        var queue = [index]
        var cursor = 0
        seen[index] = true
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let x = current % width
            let y = current / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            for next in [
                x > 0 ? current - 1 : -1, x + 1 < width ? current + 1 : -1,
                y > 0 ? current - width : -1, y + 1 < height ? current + width : -1,
            ] {
                if next >= 0 && !seen[next] && blue(next) {
                    seen[next] = true
                    queue.append(next)
                }
            }
        }
        let w = maxX - minX + 1
        let h = maxY - minY + 1
        guard w >= 8, h >= 8, Double(w) / Double(h) < 3 else { continue }
        let offset = (((minY + maxY) / 2) * width + (minX + maxX) / 2) * 4
        result.append(
            .init(
                aspect: Double(w) / Double(h),
                color: UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8
                    | UInt32(pixels[offset + 2])))
    }
    return result
}

@Test("Hover details reserve equal height for no selection, short values and long values")
@MainActor func statisticsSelectionKeepsFollowingChartsStationary() throws {
    for width in [280.0, 659.0] {
        let sizes = try [
            nil, "Nov 17: 3 reviews", String(repeating: "A long series label with values, ", count: 10),
        ].map { text in
            let renderer = ImageRenderer(
                content:
                    VStack(alignment: .leading, spacing: 12) {
                        StatisticsChartSelection(text: text)
                        Color.red.frame(height: 20)
                    }.frame(width: width))
            return try #require(renderer.cgImage).height
        }
        #expect(Set(sizes).count == 1, "Hovering must not move following charts")
    }
}

@Test("Calendar honors weekday order, year boundaries, and compact scrolling metrics")
func statisticsCalendarLayoutCoordinates() throws {
    let points = try calendarFixture(series: "Reviews", active: true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    let layout = StatisticsCalendarLayout(points: points, calendar: calendar)
    #expect(layout.row(points[0].date) == 3)
    #expect(layout.months.count == 12)
    #expect(layout.weekCount == 53)
    #expect(Set(points.map { layout.column($0.date) * 7 + layout.row($0.date) }).count == 365)
    let compact = StatisticsCalendarMetrics(
        width: 330, weeks: 53, minimumCell: 10, axisWidth: 36, axisHeight: 24)
    #expect(compact.visibleWeeks < 53)
    let desktop = StatisticsCalendarMetrics(
        width: 659, weeks: 53, minimumCell: 10, axisWidth: 36, axisHeight: 24)
    #expect(desktop.visibleWeeks == 53)
}
