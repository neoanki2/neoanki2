import Foundation
import XCTest

final class FunctionalUICoverageManifestTests: XCTestCase {
    private let functionalSuites = [
        "ScopeHomeAndBrowseUITests",
        "LibraryUITests",
        "DeckUITests",
        "AuthoringUITests",
        "TemplatesUITests",
        "TemplatesAdvancedUITests",
        "StudyUITests",
        "StudyExtendedUITests",
        "ImportExportUITests",
        "PortableDeckUITests",
        "NavigationGatingUITests",
    ]

    func testEveryLegacyUICheckIsMappedExactlyOnce() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiTests = root.appendingPathComponent("UITests/NeoAnki2UITests", isDirectory: true)
        let journeySource = try String(
            contentsOf: uiTests.appendingPathComponent("FastFunctionalJourneyTests.swift"),
            encoding: .utf8
        )

        let mapped = captures(
            pattern: #"runLegacyCheck\("([^"]+)""#,
            in: journeySource
        )
        XCTAssertEqual(mapped.count, 126)
        XCTAssertEqual(Set(mapped).count, mapped.count, "A legacy UI check is mapped more than once")

        var declared = Set<String>()
        for suite in functionalSuites {
            let source = try String(
                contentsOf: uiTests.appendingPathComponent("\(suite).swift"),
                encoding: .utf8
            )
            let suffixes = captures(
                pattern: #"func check\#(suite)([A-Za-z0-9_]+)\(\) throws"#,
                in: source
            )
            declared.formUnion(suffixes.map { "\(suite).test\($0)" })
        }

        XCTAssertEqual(declared.count, 126)
        XCTAssertEqual(Set(mapped), declared)

        let journeys = captures(
            pattern: #"func (test[A-Za-z0-9_]+Journey)\(\) throws"#,
            in: journeySource
        )
        XCTAssertEqual(journeys.count, 7)
        XCTAssertEqual(Set(journeys).count, 7)
    }

    private func captures(pattern: String, in source: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        }
    }
}
