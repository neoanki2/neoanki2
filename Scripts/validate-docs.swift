#!/usr/bin/env swift

import Foundation

struct Manifest: Decodable {
    let schemaVersion: Int
    let features: [Feature]
}

struct Feature: Decodable {
    let id: String
    let name: String
    let article: String
    let sources: [String]
    let tests: [String]
    let screenshot: String?
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let docs = root.appendingPathComponent("docs", isDirectory: true)
let manifestURL = docs.appendingPathComponent("features.json")
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

guard
    let data = try? Data(contentsOf: manifestURL),
    let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
else {
    fputs("Unable to decode docs/features.json\n", stderr)
    exit(1)
}

if manifest.schemaVersion != 1 {
    fail("Unsupported feature manifest schema version \(manifest.schemaVersion)")
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

func featureIndex(_ features: [Feature]) -> String {
    var output = """
    ---
    title: Feature index
    description: Coverage map from every NeoAnki2 feature to its guide, implementation, tests, and screenshot.
    nav_order: 3
    permalink: /features/
    ---

    # Feature index

    This page is generated from [`features.json`](../features.json). It makes
    documentation ownership explicit: each user-facing feature points to its guide,
    implementation evidence, and behavioral tests.

    | Feature | Guide | Implementation | Tests | Screenshot |
    | --- | --- | --- | --- | --- |
    """
    for feature in features.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
        let article = feature.article.replacingOccurrences(of: ".md", with: "/")
        let sourceLinks = feature.sources.map { "[`\($0.split(separator: "/").last!)`](https://github.com/neoanki2/neoanki2/blob/main/\($0))" }.joined(separator: "<br>")
        let testLinks = feature.tests.map { "[`\($0.split(separator: "/").last!)`](https://github.com/neoanki2/neoanki2/blob/main/\($0))" }.joined(separator: "<br>")
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
            if !changed.contains("docs/features.json") {
                for feature in manifest.features where !changed.isDisjoint(with: Set(feature.sources)) {
                    let articlePath = "docs/\(feature.article)"
                    if !changed.contains(articlePath) {
                        fail("Feature '\(feature.id)' changed without updating \(articlePath) or docs/features.json")
                    }
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
