#!/usr/bin/env swift

import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

struct Manifest: Decodable {
    let schemaVersion: Int
    let requiredScreenshotFeatureIDs: [String]
    let inventory: Inventory
    let features: [Feature]
}

struct Inventory: Decodable {
    let sourceRoots: [String]
    let fullyMappedSourceRoots: [String]
    let sourceMarkers: [String]
    let testRoots: [String]
    let testMarkers: [String]
    let excludedFiles: [String]
}

struct Feature: Decodable {
    let id: String
    let name: String
    let article: String
    let sources: [String]
    let tests: [String]
    let screenshot: String?
}

struct ClaimsRegistry: Decodable {
    struct Evidence: Decodable {
        let article: String
        let source: String
    }

    struct ArticleAssertion: Decodable {
        let article: String
        let contains: [String]
    }

    struct HistoryClaim: Decodable {
        let article: String
        let source: String
        let reviewLogRetention: String
    }

    let schemaVersion: Int
    let media: Evidence
    let itemImport: Evidence
    let portableDeck: Evidence
    let authoredDeck: Evidence
    let scheduling: Evidence
    let dailyNewCards: Evidence
    let scheduler: Evidence
    let appData: Evidence
    let history: HistoryClaim
    let compatibility: Evidence
    let articleAssertions: [ArticleAssertion]

    var evidence: [Evidence] {
        [
            media, itemImport, portableDeck, authoredDeck, scheduling, dailyNewCards,
            scheduler, appData,
            Evidence(article: history.article, source: history.source),
            compatibility,
        ]
    }
}

struct ScreenshotManifest: Decodable {
    struct Entry: Decodable {
        let filename: String
        let width: Int
        let height: Int
        let sha256: String
        let scenario: String
        let expectedVisibleIdentifiers: [String]
    }

    let schemaVersion: Int
    let sourceSHA: String
    let capturedAt: String
    let appearance: String
    let screenshots: [Entry]
}

struct InfrastructureChangeReview: Decodable {
    let schemaVersion: Int
    let diffSHA256: String
    let files: [String]
    let reason: String
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let docs = root.appendingPathComponent("docs", isDirectory: true)
let manifestURL = docs.appendingPathComponent("features.json")
let claimsURL = docs.appendingPathComponent("claims.json")
let infrastructureReviewURL = docs.appendingPathComponent("infrastructure-change-review.json")
let generatedURL = docs.appendingPathComponent("features.md")
let arguments = Set(CommandLine.arguments.dropFirst())
let writeGenerated = arguments.contains("--write")
let requireScreenshots = arguments.contains("--require-screenshots")
var failures: [String] = []

func exists(_ relativePath: String, under base: URL = root) -> Bool {
    fileManager.fileExists(atPath: base.appendingPathComponent(relativePath).standardizedFileURL.path)
}

func hasTransparentWindowCorners(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return false
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return false
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    func alpha(x: Int, y: Int) -> UInt8 {
        pixels[((y * width + x) * 4) + 3]
    }
    let transparentCorners = [
        alpha(x: 0, y: 0),
        alpha(x: width - 1, y: 0),
        alpha(x: 0, y: height - 1),
        alpha(x: width - 1, y: height - 1),
    ]
    let opaqueEdges = [
        alpha(x: width / 2, y: 0),
        alpha(x: width / 2, y: height - 1),
        alpha(x: 0, y: height / 2),
        alpha(x: width - 1, y: height / 2),
    ]
    return transparentCorners.allSatisfy { $0 == 0 }
        && opaqueEdges.allSatisfy { $0 == 255 }
}

func fail(_ message: String) {
    failures.append(message)
}

func exitWithFailuresIfNeeded() -> Never {
    for failure in failures {
        fputs("error: \(failure)\n", stderr)
    }
    exit(1)
}

func gitOutput(arguments: [String]) throws -> (status: Int32, data: Data) {
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

guard
    let data = try? Data(contentsOf: manifestURL),
    let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
else {
    fputs("Unable to decode docs/features.json\n", stderr)
    exit(1)
}

guard
    let claimsData = try? Data(contentsOf: claimsURL),
    let claims = try? JSONDecoder().decode(ClaimsRegistry.self, from: claimsData)
else {
    fputs("Unable to decode docs/claims.json\n", stderr)
    exit(1)
}

if manifest.schemaVersion != 1 {
    fail("Unsupported feature manifest schema version \(manifest.schemaVersion)")
}
if claims.schemaVersion != 1 {
    fail("Unsupported claims registry schema version \(claims.schemaVersion)")
}
for claim in claims.evidence {
    if !exists(claim.article, under: docs) {
        fail("Claim references missing article docs/\(claim.article)")
    }
    if !exists(claim.source) {
        fail("Claim references missing production source \(claim.source)")
    }
}
let historyBehaviorTest = root.appendingPathComponent(
    "NeoAnkiCore/Tests/NeoAnkiFlowTests/RevertReviewFlowTests.swift"
)
if claims.history.reviewLogRetention != "survives-item-and-card-deletion"
    || (try? String(contentsOf: historyBehaviorTest, encoding: .utf8))?
        .contains("deletingCardDoesNotDeleteReviewHistory") != true {
    fail("Review-log retention claim is not backed by its production behavior test")
}
for assertion in claims.articleAssertions {
    let articleURL = docs.appendingPathComponent(assertion.article)
    guard let article = try? String(contentsOf: articleURL, encoding: .utf8) else {
        fail("Claim assertion references unreadable article docs/\(assertion.article)")
        continue
    }
    for expectedText in assertion.contains where !article.contains(expectedText) {
        fail(
            "High-risk prose in docs/\(assertion.article) is missing registry text: \(expectedText)"
        )
    }
}

let authoredItemSchemaURL = docs.appendingPathComponent("schemas/authored-item.schema.json")
if let schemaData = try? Data(contentsOf: authoredItemSchemaURL),
   let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
   let definitions = schema["$defs"] as? [String: Any],
   let media = definitions["media"] as? [String: Any],
   let properties = media["properties"] as? [String: Any],
   let path = properties["path"] as? [String: Any],
   let pattern = path["pattern"] as? String,
   let expression = try? NSRegularExpression(pattern: pattern) {
    func schemaAccepts(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
    for valid in ["media/image.png", "media/subdirectory/audio.m4a"]
        where !schemaAccepts(valid) {
        fail("Authored media schema rejects valid confined path: \(valid)")
    }
    for invalid in [
        "media/./bad.png", "media/../bad.png", "media//bad.png",
        "media/sub/../bad.png", "/media/bad.png", "bad.png",
    ] where schemaAccepts(invalid) {
        fail("Authored media schema accepts unsafe path: \(invalid)")
    }
} else {
    fail("Could not validate authored media path schema")
}

var identifiers = Set<String>()
for feature in manifest.features {
    if feature.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
        fail("Feature ID '\(feature.id)' is not lowercase kebab-case")
    }
    if !identifiers.insert(feature.id).inserted {
        fail("Duplicate feature ID '\(feature.id)'")
    }
    if !exists(feature.article, under: docs) {
        fail("Feature '\(feature.id)' references missing article docs/\(feature.article)")
    }
    for path in feature.sources + feature.tests where !exists(path) {
        fail("Feature '\(feature.id)' references missing file \(path)")
    }
    if let screenshot = feature.screenshot, requireScreenshots, !exists(screenshot, under: docs) {
        fail("Feature '\(feature.id)' references missing screenshot docs/\(screenshot)")
    }
}

let requiredScreenshotFeatureIDs = Set(manifest.requiredScreenshotFeatureIDs)
if requiredScreenshotFeatureIDs.count != manifest.requiredScreenshotFeatureIDs.count
    || manifest.requiredScreenshotFeatureIDs != manifest.requiredScreenshotFeatureIDs.sorted() {
    fail("requiredScreenshotFeatureIDs must be unique and sorted")
}
let unknownScreenshotRequirements = requiredScreenshotFeatureIDs.subtracting(identifiers)
if !unknownScreenshotRequirements.isEmpty {
    fail(
        "Required screenshots reference unknown features: "
            + unknownScreenshotRequirements.sorted().joined(separator: ", ")
    )
}
for feature in manifest.features
    where requiredScreenshotFeatureIDs.contains(feature.id) && feature.screenshot == nil {
    fail("Feature '\(feature.id)' is required to provide a documentation screenshot")
}

if requireScreenshots {
    let screenshotStylesURL = docs.appendingPathComponent("assets/css/site.css")
    guard let screenshotStyles = try? String(contentsOf: screenshotStylesURL, encoding: .utf8)
    else {
        fail("Could not read documentation screenshot presentation styles")
        exitWithFailuresIfNeeded()
    }
    func screenshotPixelCap(named name: String) -> Int? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"--"# + escapedName + #"\s*:\s*([0-9]+)px\s*;"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: screenshotStyles,
                  range: NSRange(screenshotStyles.startIndex..., in: screenshotStyles)
              ),
              let range = Range(match.range(at: 1), in: screenshotStyles) else {
            return nil
        }
        return Int(screenshotStyles[range])
    }
    let screenshotDensityCaps = [
        (name: "documentation-screenshot-2x-max-width", density: 2),
        (name: "documentation-screenshot-3x-max-width", density: 3),
    ]
    let resolvedScreenshotDensityCaps = screenshotDensityCaps.compactMap { cap in
        screenshotPixelCap(named: cap.name).map { (width: $0, density: cap.density) }
    }
    if resolvedScreenshotDensityCaps.count != screenshotDensityCaps.count
        || !screenshotStyles.contains("@media (min-resolution: 2dppx)")
        || !screenshotStyles.contains("@media (min-resolution: 3dppx)")
        || !screenshotStyles.contains(#"a[href*="assets/screenshots/"] > img"#) {
        fail("Documentation screenshots must define enforced 2x and 3x display caps")
    }
    let screenshotManifestURL = docs.appendingPathComponent("assets/screenshots/manifest.json")
    guard
        let screenshotData = try? Data(contentsOf: screenshotManifestURL),
        let screenshotManifest = try? JSONDecoder().decode(
            ScreenshotManifest.self,
            from: screenshotData
        )
    else {
        fail("Missing or invalid docs/assets/screenshots/manifest.json")
        exitWithFailuresIfNeeded()
    }
    if screenshotManifest.schemaVersion != 1 {
        fail("Unsupported screenshot manifest schema version \(screenshotManifest.schemaVersion)")
    }
    if screenshotManifest.appearance != "dark" {
        fail("Documentation screenshots must use dark appearance")
    }
    if screenshotManifest.sourceSHA.range(
        of: #"^[0-9a-f]{40}$"#,
        options: .regularExpression
    ) == nil {
        fail("Screenshot manifest sourceSHA must be a 40-character lowercase Git SHA")
    }
    if ISO8601DateFormatter().date(from: screenshotManifest.capturedAt) == nil {
        fail("Screenshot manifest capturedAt must be an ISO-8601 timestamp")
    }
    let ancestryCheck = Process()
    ancestryCheck.currentDirectoryURL = root
    ancestryCheck.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    ancestryCheck.arguments = [
        "merge-base", "--is-ancestor", screenshotManifest.sourceSHA, "HEAD",
    ]
    do {
        try ancestryCheck.run()
        ancestryCheck.waitUntilExit()
        if ancestryCheck.terminationStatus != 0 {
            fail("Screenshot manifest sourceSHA is not an ancestor of the validated revision")
        }
    } catch {
        fail("Could not verify screenshot manifest source revision")
    }
    do {
        let changedSinceCapture = try gitOutput(
            arguments: ["diff", "--name-only", screenshotManifest.sourceSHA, "--"]
        )
        if changedSinceCapture.status != 0 {
            fail("Could not compare screenshot evidence with its source revision")
        } else {
            let changedPaths = Set(
                String(decoding: changedSinceCapture.data, as: UTF8.self)
                    .split(separator: "\n")
                    .map(String.init)
            )
            for feature in manifest.features where feature.screenshot != nil {
                let changedEvidenceSources = changedPaths.intersection(feature.sources)
                if !changedEvidenceSources.isEmpty {
                    fail(
                        "Screenshot for feature '\(feature.id)' is stale because its "
                            + "source changed after capture: "
                            + changedEvidenceSources.sorted().joined(separator: ", ")
                    )
                }
            }
        }
    } catch {
        fail("Could not run git for screenshot freshness: \(error.localizedDescription)")
    }
    let expectedFilenames = Set(
        manifest.features.compactMap(\.screenshot).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    )
    let entriesByName = Dictionary(
        screenshotManifest.screenshots.map { ($0.filename, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    if entriesByName.count != screenshotManifest.screenshots.count {
        fail("Screenshot manifest contains duplicate filenames")
    }
    if Set(entriesByName.keys) != expectedFilenames {
        fail("Screenshot manifest entries do not match feature screenshot coverage")
    }
    for entry in screenshotManifest.screenshots {
        let screenshotURL = docs
            .appendingPathComponent("assets/screenshots")
            .appendingPathComponent(entry.filename)
        guard let png = try? Data(contentsOf: screenshotURL), png.count >= 24,
              Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            fail("Screenshot \(entry.filename) is missing or is not a PNG")
            continue
        }
        func pngInteger(at offset: Int) -> Int {
            png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        if entry.width != pngInteger(at: 16) || entry.height != pngInteger(at: 20)
            || entry.width < 1_024 || entry.height < 680 {
            fail("Screenshot \(entry.filename) dimensions do not match its manifest")
        }
        for cap in resolvedScreenshotDensityCaps
            where entry.width < cap.width * cap.density {
            fail(
                "Screenshot \(entry.filename) is too narrow for the \(cap.density)x "
                    + "display cap (\(entry.width)px source for \(cap.width)px CSS)"
            )
        }
        let digest = SHA256.hash(data: png)
            .map { String(format: "%02x", $0) }
            .joined()
        if entry.sha256 != digest {
            fail("Screenshot \(entry.filename) SHA-256 does not match its manifest")
        }
        if !hasTransparentWindowCorners(screenshotURL) {
            fail(
                "Screenshot \(entry.filename) must have transparent rounded window corners"
            )
        }
        if entry.scenario.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.expectedVisibleIdentifiers.isEmpty {
            fail("Screenshot \(entry.filename) is missing scenario evidence")
        }
    }
}

let mappedSources = Set(manifest.features.flatMap(\.sources))
let mappedTests = Set(manifest.features.flatMap(\.tests))
let excludedInventoryFiles = Set(manifest.inventory.excludedFiles)

func inventoryFiles(under relativeRoot: String) -> [URL] {
    let directory = root.appendingPathComponent(relativeRoot, isDirectory: true)
    guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        fail("Feature inventory root does not exist: \(relativeRoot)")
        return []
    }
    return (enumerator.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
}

for sourceRoot in manifest.inventory.sourceRoots {
    for file in inventoryFiles(under: sourceRoot) {
        let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
        guard !excludedInventoryFiles.contains(relativePath),
              let text = try? String(contentsOf: file, encoding: .utf8),
              manifest.inventory.sourceMarkers.contains(where: text.contains)
        else {
            continue
        }
        if !mappedSources.contains(relativePath) {
            fail("User-facing source is missing from docs/features.json: \(relativePath)")
        }
    }
}

for sourceRoot in manifest.inventory.fullyMappedSourceRoots {
    for file in inventoryFiles(under: sourceRoot) {
        let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
        if !excludedInventoryFiles.contains(relativePath), !mappedSources.contains(relativePath) {
            fail("Required core/CLI source is missing from docs/features.json: \(relativePath)")
        }
    }
}

for testRoot in manifest.inventory.testRoots {
    for file in inventoryFiles(under: testRoot) {
        let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
        guard !excludedInventoryFiles.contains(relativePath),
              let text = try? String(contentsOf: file, encoding: .utf8),
              manifest.inventory.testMarkers.contains(where: text.contains)
        else {
            continue
        }
        if !mappedTests.contains(relativePath) {
            fail("User-facing test is missing from docs/features.json: \(relativePath)")
        }
    }
}

func featureIndex(_ features: [Feature]) -> String {
    var output = """
    ---
    title: Feature index
    description: Coverage map from every NeoAnki2 feature to its guide, implementation, tests, and screenshot.
    nav_order: 3
    permalink: /features/
    ---

    # Feature index

    Looking for an action rather than engineering evidence? Start with the
    [task index](../user/tasks/).

    This contributor-facing page is generated from [`features.json`](../features.json).
    Within its declared app-source and UI-test inventory boundary, each detected
    user-facing file must map to a guide, implementation evidence, and behavioral
    tests. The screenshot capture harness is explicitly excluded because it verifies
    documentation evidence rather than product behavior.

        Evidence links establish implementation and test ownership; they are not a
        conformance claim. In particular, the accessibility guide identifies which
        VoiceOver, text-size, contrast, and end-to-end checks still require manual testing.

    {% assign source_revision = site.data.build.commit_sha | default: site.documentation.revision %}

    | Feature | Guide | Implementation | Tests | Screenshot |
    | --- | --- | --- | --- | --- |
    """
    for feature in features.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
        let article = feature.article.replacingOccurrences(of: ".md", with: "/")
        let sourceLinks = feature.sources.map { "[`\($0.split(separator: "/").last!)`](https://github.com/neoanki2/neoanki2/blob/{{ source_revision }}/\($0))" }.joined(separator: "<br>")
        let testLinks = feature.tests.map { "[`\($0.split(separator: "/").last!)`](https://github.com/neoanki2/neoanki2/blob/{{ source_revision }}/\($0))" }.joined(separator: "<br>")
        let screenshot = feature.screenshot.map { "[View](../\($0))" } ?? "—"
        output += "\n| \(feature.name) | [Guide](../\(article)) | \(sourceLinks) | \(testLinks) | \(screenshot) |"
    }
    return output + "\n"
}

let expectedIndex = featureIndex(manifest.features)
if writeGenerated {
    do {
        try expectedIndex.write(to: generatedURL, atomically: true, encoding: .utf8)
    } catch {
        fail("Could not write docs/features.md: \(error.localizedDescription)")
    }
} else if (try? String(contentsOf: generatedURL, encoding: .utf8)) != expectedIndex {
    fail("docs/features.md is stale; run: swift Scripts/validate-docs.swift --write")
}

let enumerator = fileManager.enumerator(
    at: docs,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
)
let markdownFiles = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }

let linkPattern = try! NSRegularExpression(pattern: #"(!?)\[[^\]]*\]\(([^)]+)\)"#)
for file in markdownFiles {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        fail("Could not read \(file.path)")
        continue
    }
    let range = NSRange(text.startIndex..., in: text)
    for match in linkPattern.matches(in: text, range: range) {
        guard let targetRange = Range(match.range(at: 2), in: text) else { continue }
        let isImage = match.range(at: 1).length == 1
        var target = String(text[targetRange])
        if target.hasPrefix("#") {
            continue
        }
        target = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        target = target.removingPercentEncoding ?? target
        if target.isEmpty || target.hasPrefix("http://") || target.hasPrefix("https://")
            || target.hasPrefix("mailto:") || target.contains("{{") {
            continue
        }
        if !requireScreenshots && (isImage || target.contains("assets/screenshots/")) {
            continue
        }
        let candidate = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
        var valid = fileManager.fileExists(atPath: candidate.path)
        if !valid, target.hasSuffix("/") {
            valid = fileManager.fileExists(atPath: candidate.appendingPathComponent("index.md").path)
        }
        if !valid, target.hasSuffix(".html") {
            let markdownCandidate = candidate.deletingPathExtension().appendingPathExtension("md")
            valid = fileManager.fileExists(atPath: markdownCandidate.path)
        }
        if !valid {
            let outputDirectory = file.lastPathComponent == "index.md"
                ? file.deletingLastPathComponent()
                : file.deletingPathExtension()
            let outputCandidate = outputDirectory.appendingPathComponent(target).standardizedFileURL
            valid = fileManager.fileExists(atPath: outputCandidate.path)
                || fileManager.fileExists(atPath: outputCandidate.appendingPathComponent("index.md").path)
                || fileManager.fileExists(atPath: outputCandidate.path + ".md")
            if !valid, target.hasSuffix(".html") {
                valid = fileManager.fileExists(
                    atPath: outputCandidate.deletingPathExtension().appendingPathExtension("md").path
                )
            }
        }
        if !valid {
            let relativeFile = file.path.replacingOccurrences(of: docs.path + "/", with: "")
            fail("\(relativeFile) has a broken local link: \(target)")
        }
    }
}

if let baseIndex = CommandLine.arguments.firstIndex(of: "--base-ref"),
   CommandLine.arguments.indices.contains(baseIndex + 1) {
    let baseRef = CommandLine.arguments[baseIndex + 1]
    do {
        let changedResult = try gitOutput(
            arguments: ["diff", "--name-only", "\(baseRef)...HEAD"]
        )
        if changedResult.status == 0 {
            let changedData = changedResult.data
            let changed = Set(String(decoding: changedData, as: UTF8.self).split(separator: "\n").map(String.init))
            var reviewedInfrastructureFiles = Set<String>()
            if changed.contains("docs/infrastructure-change-review.json") {
                guard
                    let reviewData = try? Data(contentsOf: infrastructureReviewURL),
                    let review = try? JSONDecoder().decode(
                        InfrastructureChangeReview.self,
                        from: reviewData
                    )
                else {
                    fail("Missing or invalid docs/infrastructure-change-review.json")
                    exitWithFailuresIfNeeded()
                }
                if review.schemaVersion != 1 {
                    fail(
                        "Unsupported infrastructure change review schema version \(review.schemaVersion)"
                    )
                }
                let reviewFiles = Set(review.files)
                if reviewFiles.count != review.files.count || review.files != review.files.sorted() {
                    fail("Infrastructure change review files must be unique and sorted")
                }
                if review.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fail("Infrastructure change review must explain why user documentation is unchanged")
                }
                let mappedChangedSources = changed.intersection(mappedSources)
                if !reviewFiles.isSubset(of: mappedChangedSources) {
                    fail(
                        "Infrastructure change review may contain only changed, mapped source files"
                    )
                }
                let patchResult = try gitOutput(
                    arguments: [
                        "diff", "--binary", "\(baseRef)...HEAD", "--",
                    ] + review.files
                )
                if patchResult.status != 0 {
                    fail("Could not compute the reviewed infrastructure diff")
                } else {
                    let digest = SHA256.hash(data: patchResult.data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                    if digest != review.diffSHA256 {
                        fail(
                            "Infrastructure change review hash is stale; review the mapped source diff again"
                        )
                    } else {
                        reviewedInfrastructureFiles = reviewFiles
                    }
                }
            }
            let changedProductSources = changed.subtracting(reviewedInfrastructureFiles)
            for feature in manifest.features
                where !changedProductSources.isDisjoint(with: Set(feature.sources)) {
                let articlePath = "docs/\(feature.article)"
                if !changed.contains(articlePath) {
                    fail(
                        "Feature '\(feature.id)' changed without reviewing and updating "
                            + "\(articlePath). This is a good opportunity to make the "
                            + "relevant documentation slightly better."
                    )
                }
                if let screenshot = feature.screenshot {
                    let screenshotPath = "docs/\(screenshot)"
                    if !changed.contains(screenshotPath)
                        || !changed.contains("docs/assets/screenshots/manifest.json") {
                        fail(
                            "Feature '\(feature.id)' changed without refreshing "
                                + "\(screenshotPath) and its screenshot manifest. This is "
                                + "a good opportunity to make the relevant documentation "
                                + "slightly better."
                        )
                    }
                }
            }
            for claim in claims.evidence where changed.contains(claim.source) {
                let articlePath = "docs/\(claim.article)"
                if !changed.contains("docs/claims.json") || !changed.contains(articlePath) {
                    fail(
                        "High-risk claims source \(claim.source) changed; update "
                            + "docs/claims.json and \(articlePath). This is a good "
                            + "opportunity to make the relevant documentation slightly better."
                    )
                }
            }
        } else {
            fail("Could not compare documentation against base ref \(baseRef)")
        }
    } catch {
        fail("Could not run git for documentation freshness: \(error.localizedDescription)")
    }
}

if failures.isEmpty {
    print("Documentation validation passed (\(manifest.features.count) features).")
} else {
    for failure in failures {
        fputs("error: \(failure)\n", stderr)
    }
    exit(1)
}
