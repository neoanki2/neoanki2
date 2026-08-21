import Foundation
import XCTest

final class FunctionalUICoverageManifestTests: XCTestCase {
    private struct CIUIPlan: Decodable {
        let schemaVersion: Int
        let macos: [MacShard]
        let ios: [IOSShard]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case macos
            case ios
        }
    }

    private struct MacShard: Decodable {
        let id: String
        let tests: [String]
    }

    private struct IOSShard: Decodable {
        let id: String
        let device: String
        let workers: Int
        let tests: [String]
    }

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
        let root = repositoryRoot
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

    func testRequiredCIShardsCoverEveryUITestWithoutBehaviorDuplication() throws {
        let decoder = JSONDecoder()
        let plan = try decoder.decode(
            CIUIPlan.self,
            from: Data(contentsOf: repositoryRoot.appendingPathComponent("Config/ci-ui-shards.json"))
        )
        XCTAssertEqual(plan.schemaVersion, 1)
        XCTAssertEqual(plan.macos.count, 5)
        XCTAssertEqual(plan.ios.count, 3)

        let macSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "UITests/NeoAnki2UITests/FastFunctionalJourneyTests.swift"
            ),
            encoding: .utf8
        )
        let declaredMacTests = Set(captures(
            pattern: #"func (test[A-Za-z0-9_]+)\(\) throws"#,
            in: macSource
        ))
        let plannedMacTests = plan.macos.flatMap(\.tests).map {
            $0.replacingOccurrences(
                of: "NeoAnki2UITests/FastFunctionalJourneyTests/",
                with: ""
            )
        }
        XCTAssertEqual(Set(plannedMacTests), declaredMacTests)
        XCTAssertEqual(plannedMacTests.count, Set(plannedMacTests).count)
        XCTAssertEqual(Set(plan.macos.map(\.id)).count, plan.macos.count)

        let iosSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Platforms/iOSUITests/NeoAnki2MobileUITests.swift"
            ),
            encoding: .utf8
        )
        let declaredIOSTests = Set(captures(
            pattern: #"func (test[A-Za-z0-9_]+)\(\) throws"#,
            in: iosSource
        ))
        let declaredIOSIdentifiers = Set(iosTestMethodsByClass(in: iosSource).flatMap {
            testClass, methods in
            methods.map { "NeoAnki2MobileUITests/\(testClass)/\($0)" }
        })
        let plannedIOSIdentifiers = Set(plan.ios.flatMap(\.tests))
        XCTAssertEqual(plannedIOSIdentifiers, declaredIOSIdentifiers)
        let plannedIOS = plan.ios.flatMap { shard in
            shard.tests.map {
                (
                    test: String($0.split(separator: "/").last ?? ""),
                    device: shard.device
                )
            }
        }
        XCTAssertEqual(Set(plannedIOS.map(\.test)), declaredIOSTests)
        XCTAssertTrue(plan.ios.allSatisfy { (1...4).contains($0.workers) })
        XCTAssertEqual(Set(plan.ios.map(\.id)).count, plan.ios.count)

        let crossFormFactorTests = declaredIOSTests.filter {
            $0.contains("Accessibility")
                || $0 == "testLargestTypeDarkHighContrastReducedMotionInLandscape"
        }
        for test in declaredIOSTests {
            let assignments = plannedIOS.filter { $0.test == test }
            if crossFormFactorTests.contains(test) {
                XCTAssertEqual(
                    Set(assignments.map(\.device)),
                    ["iPhone 17e", "iPad Pro 13-inch (M5)"],
                    "\(test) must cover both compact and regular-width layouts"
                )
            } else {
                XCTAssertEqual(assignments.map(\.device), ["iPhone 17 Pro Max"])
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func captures(pattern: String, in source: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        }
    }

    private func iosTestMethodsByClass(in source: String) -> [String: [String]] {
        let expression = try! NSRegularExpression(
            pattern: #"final class ([A-Za-z0-9_]+): NeoAnki2MobileUITestCase"#
        )
        let sourceRange = NSRange(source.startIndex..., in: source)
        let matches = expression.matches(in: source, range: sourceRange)
        var result: [String: [String]] = [:]
        for (index, match) in matches.enumerated() {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let bodyStart = Range(match.range, in: source)?.upperBound
            else { continue }
            let bodyEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: source) {
                bodyEnd = nextRange.lowerBound
            } else {
                bodyEnd = source.endIndex
            }
            result[String(source[nameRange])] = captures(
                pattern: #"func (test[A-Za-z0-9_]+)\(\) throws"#,
                in: String(source[bodyStart..<bodyEnd])
            )
        }
        return result
    }
}
