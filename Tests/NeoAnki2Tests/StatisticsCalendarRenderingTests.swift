import AppKit
import NeoAnkiCore
import SwiftUI
import Testing

@testable import NeoAnkiSharedUI

@Test("Study calendar paints daily cells for reviews and active minutes, including zero activity")
@MainActor func statisticsCalendarRendersDailyCells() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
    for series in ["Reviews", "Active minutes"] {
        for hasActivity in [true, false] {
            for chartWidth in [680.0, 1_000.0] {
                let points = (0..<365).map { day in
                    StatisticsPoint(
                        date: calendar.date(byAdding: .day, value: day, to: start)!,
                        series: series, value: hasActivity ? Double(day % 9) : 0)
                }
                let renderer = ImageRenderer(
                    content:
                        StatisticsHeatmap(points: points).calendarChart
                        .frame(width: chartWidth)
                        .accentColor(.blue)
                        .environment(\.colorScheme, .dark)
                        .background(Color.black)
                )
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                if let directory = ProcessInfo.processInfo.environment["NEOANKI_CALENDAR_RENDER_DIR"] {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let png = try #require(
                        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(
                        to: output.appendingPathComponent("\(series)-\(hasActivity)-\(Int(chartWidth)).png"))
                }
                // Inspect the plot itself, excluding the heading, export action, and
                // exact-value disclosure. Axis-only output cannot satisfy this check.
                let width = image.width
                let height = image.height
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try #require(
                        CGContext(
                            data: buffer.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                var paintedPixels = 0
                var weekdayRows = 0
                var previousRowPainted = false
                for y in 0..<max(0, height - 20) {
                    var rowPixels = 0
                    for x in 70..<min(650, width) {
                        let offset = (y * width + x) * 4
                        if Int(pixels[offset + 2]) > Int(pixels[offset]) + 20 {
                            rowPixels += 1
                        }
                    }
                    paintedPixels += rowPixels
                    let rowPainted = rowPixels > 100
                    if rowPainted && !previousRowPainted { weekdayRows += 1 }
                    previousRowPainted = rowPainted
                }
                #expect(
                    paintedPixels > 5_000,
                    "\(series), activity=\(hasActivity), width=\(chartWidth): the calendar must paint daily cells, not just axes (\(paintedPixels) pixels)"
                )
                #expect(weekdayRows == 7, "All seven weekday rows must be visible")
            }
        }
    }
}
