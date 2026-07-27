#!/usr/bin/env swift

import Foundation

struct Manifest: Decodable {
    let schemaVersion: Int
    let inventory: Inventory
    let features: [Feature]
}

struct Inventory: Decodable {
    let sourceRoots: [String]
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

    let schemaVersion: Int
    let media: Evidence
    let itemImport: Evidence
    let portableDeck: Evidence
    let authoredDeck: Evidence
    let scheduling: Evidence
    let scheduler: Evidence
    let appData: Evidence
    let history: Evidence
    let compatibility: Evidence
    let articleAssertions: [ArticleAssertion]

    var evidence: [Evidence] {
        [
            media, itemImport, portableDeck, authoredDeck, scheduling,
            scheduler, appData, history, compatibility,
        ]
    }
}

struct ScreenshotManifest: Decodable {
    struct Entry: Decodable {
        let filename: String
        let width: Int
        let height: Int
        let scenario: String
        let expectedVisibleIdentifiers: [String]
    }

    let schemaVersion: Int
    let sourceSHA: String
    let capturedAt: String
    let screenshots: [Entry]
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let docs = root.appendingPathComponent("docs", isDirectory: true)
let manifestURL = docs.appendingPathComponent("features.json")
let claimsURL = docs.appendingPathComponent("claims.json")
let generatedURL = docs.appendingPathComponent("features.md")
let arguments = Set(CommandLine.arguments.dropFirst())
let writeGenerated = arguments.contains("--write")
let requireScreenshots = arguments.contains("--require-screenshots")
var failures: [String] = []

func exists(_ relativePath: String, under base: URL = root) -> Bool {
    fileManager.fileExists(atPath: base.appendingPathComponent(relativePath).standardizedFileURL.path)
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

if requireScreenshots {
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
    if screenshotManifest.sourceSHA.range(
        of: #"^[0-9a-f]{40}$"#,
        options: .regularExpression
    ) == nil {
        fail("Screenshot manifest sourceSHA must be a 40-character lowercase Git SHA")
    }
    if ISO8601DateFormatter().date(from: screenshotManifest.capturedAt) == nil {
        fail("Screenshot manifest capturedAt must be an ISO-8601 timestamp")
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
        if entry.width <= 0 || entry.height <= 0 {
            fail("Screenshot \(entry.filename) has invalid dimensions in manifest")
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
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["diff", "--name-only", "\(baseRef)...HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let changedData = pipe.fileHandleForReading.readDataToEndOfFile()
            let changed = Set(String(decoding: changedData, as: UTF8.self).split(separator: "\n").map(String.init))
            for feature in manifest.features where !changed.isDisjoint(with: Set(feature.sources)) {
                let articlePath = "docs/\(feature.article)"
                if !changed.contains(articlePath) {
                    fail("Feature '\(feature.id)' changed without reviewing and updating \(articlePath)")
                }
                if let screenshot = feature.screenshot {
                    let screenshotPath = "docs/\(screenshot)"
                    if !changed.contains(screenshotPath)
                        || !changed.contains("docs/assets/screenshots/manifest.json") {
                        fail(
                            "Feature '\(feature.id)' changed without refreshing \(screenshotPath) and its screenshot manifest"
                        )
                    }
                }
            }
            for claim in claims.evidence where changed.contains(claim.source) {
                let articlePath = "docs/\(claim.article)"
                if !changed.contains("docs/claims.json") || !changed.contains(articlePath) {
                    fail(
                        "High-risk claims source \(claim.source) changed; update docs/claims.json and \(articlePath)"
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
