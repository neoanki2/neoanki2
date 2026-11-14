import Foundation
import CryptoKit
import NaturalLanguage
import NeoAnkiApplication
import NeoAnkiCore

public struct ContextTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public init(id: UUID = UUID(), text: String, start: Double, end: Double) {
        self.id = id; self.text = text; self.start = start; self.end = end
    }
}

public struct ContextSource: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var language: String
    public var filename: String
    public var kind: MediaKind
    public var segments: [ContextTranscriptSegment]
    public var transcriptionComplete: Bool
    public var transcriptionOffset: Double?
    public init(id: UUID = UUID(), name: String, language: String, filename: String, kind: MediaKind,
                segments: [ContextTranscriptSegment] = [], transcriptionComplete: Bool = false) {
        self.id = id; self.name = name; self.language = language; self.filename = filename; self.kind = kind
        self.segments = segments; self.transcriptionComplete = transcriptionComplete
    }
}

public enum ContextSubtitles {
    public static func parse(_ text: String) throws -> [ContextTranscriptSegment] {
        guard text.utf8.count <= 20_000_000 else { throw ContextAuthoringError.message("The subtitle file is too large (maximum 20 MB).") }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [ContextTranscriptSegment] = [], index = 0
        while index < lines.count {
            let line = lines[index]; index += 1
            guard line.contains("-->") else { continue }
            let times = line.components(separatedBy: "-->")
            guard times.count == 2, let start = timestamp(times[0]), let end = timestamp(times[1]),
                  start >= 0, end > start else { throw ContextAuthoringError.message("A subtitle has invalid timing. Correct the file and import it again.") }
            var content: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                content.append(lines[index]); index += 1
            }
            let sentence = content.joined(separator: " ").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { cues.append(.init(text: sentence, start: start, end: end)) }
        }
        guard !cues.isEmpty, cues.count <= 100_000 else { throw ContextAuthoringError.message("No usable SRT or VTT subtitles were found, or the file has more than 100,000 cues.") }
        return joined(cues)
    }
    private static func timestamp(_ raw: String) -> Double? {
        guard let value = raw.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
              numbers.last! < 60, numbers[numbers.count - 2] < 60 else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }
    public static func joined(_ cues: [ContextTranscriptSegment]) -> [ContextTranscriptSegment] {
        var output: [ContextTranscriptSegment] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            if var last = output.last,
               !endsSentence(last.text),
               cue.start - last.end <= 1.5, cue.start >= last.start, cue.end - last.start <= 20,
               last.text.count + cue.text.count < 300 {
                last.text += " " + cue.text; last.end = max(last.end, cue.end); output[output.count - 1] = last
            } else { output.append(cue) }
        }
        return output
    }
    private static func endsSentence(_ text: String) -> Bool {
        let closing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’」』）)]}"))
        guard let last = text.trimmingCharacters(in: closing).last else { return false }
        return ".?!。？！".contains(last)
    }
}

/// Long sources and transcript indexes are device-local, separate from saved card media.
public actor ContextSourceLibrary: LocalContextRetrieving {
    public let rootURL: URL
    private struct WordIndex: Codable {
        var digest: String
        var passages: [String: [Int]]
    }
    private var indexes: [UUID: WordIndex] = [:]
    private var indexedSegments: [UUID: [ContextTranscriptSegment]] = [:]
    public init(rootURL: URL) { self.rootURL = rootURL }
    public func sources() throws -> [ContextSource] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ContextSource.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func save(_ source: ContextSource, replacing expected: ContextSource? = nil) throws {
        if let expected {
            let current = try JSONDecoder().decode(ContextSource.self, from: Data(contentsOf: rootURL.appendingPathComponent("\(source.id).json")))
            guard current == expected else { throw ContextAuthoringError.message("This transcript changed elsewhere. Reopen it before saving so new passages are preserved.") }
        }
        guard source.filename == URL(fileURLWithPath: source.filename).lastPathComponent,
              source.segments.count <= 100_000,
              source.segments.reduce(0, { $0 + $1.text.utf8.count }) <= 20_000_000,
              source.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.text.count <= 10_000 }) else {
            throw ContextAuthoringError.message("The source transcript is invalid.")
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(source).write(to: rootURL.appendingPathComponent("\(source.id).json"), options: .atomic)
        // Indexes are derived: a failed index write leaves the source recoverable and is rebuilt on lookup.
        _ = try index(for: source)
    }
    public func importMedia(_ url: URL, language: String, subtitleText: String? = nil) throws -> ContextSource {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2_000_000_000 else {
            throw ContextAuthoringError.message("Choose a regular audio or video file smaller than 2 GB.")
        }
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "m4a", "mp3", "wav", "aac", "caf"].contains(ext) else {
            throw ContextAuthoringError.message("Choose an MP4, MOV, M4V, M4A, MP3, WAV, AAC, or CAF file.")
        }
        let id = UUID(), filename = "\(UUID()).\(ext)"
        let segments = try subtitleText.map(ContextSubtitles.parse) ?? []
        let source = ContextSource(id: id, name: url.deletingPathExtension().lastPathComponent, language: language,
                                   filename: filename, kind: ["mp4", "m4v", "mov"].contains(ext) ? .video : .audio,
                                   segments: segments, transcriptionComplete: subtitleText != nil)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let destination = rootURL.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: url, to: destination)
        do { try save(source) } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return source
    }
    public func mediaURL(for source: ContextSource) throws -> URL {
        guard source.filename == URL(fileURLWithPath: source.filename).lastPathComponent else { throw ContextAuthoringError.message("The source path is invalid.") }
        return rootURL.appendingPathComponent(source.filename)
    }
    public func remove(_ source: ContextSource) throws {
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("\(source.id).json"))
        try? FileManager.default.removeItem(at: mediaURL(for: source))
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent("\(source.id).contextindex"))
        indexes[source.id] = nil
        indexedSegments[source.id] = nil
    }
    public func examples(for target: ContextTarget, limit: Int) async throws -> [ContextExample] {
        var results: [ContextExample] = []
        for source in try sources() where source.language == target.language {
            let index = try index(for: source)
            let queryTokens = Set(([target.expression] + target.forms).flatMap { tokens(in: $0, language: target.language).prefix(1) })
            let candidates = Set(queryTokens.flatMap { index.passages[$0] ?? [] }).sorted()
            for position in candidates where source.segments.indices.contains(position) {
                let segment = source.segments[position]
                try Task.checkCancellation()
                let match = ContextOccurrences.find(target: target, in: segment.text)
                guard !match.spans.isEmpty else { continue }
                var example = ContextExample(sentence: segment.text, spans: match.spans,
                    provenance: .init(origin: .localMedia, sourceName: source.name, sourceID: "\(source.id)/\(segment.id)"),
                    needsMeaningCheck: true)
                example.mediaURL = try mediaURL(for: source); example.mediaKind = source.kind
                example.clipStart = segment.start; example.clipEnd = segment.end
                results.append(example)
                if results.count >= limit { return results }
            }
        }
        return results
    }
    private func index(for source: ContextSource) throws -> WordIndex {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let input = try encoder.encode(source.segments)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        if let cached = indexes[source.id], cached.digest == digest { return cached }
        let url = rootURL.appendingPathComponent("\(source.id).contextindex")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(WordIndex.self, from: data), saved.digest == digest {
            indexes[source.id] = saved; indexedSegments[source.id] = source.segments; return saved
        }
        let previous = indexedSegments[source.id] ?? []
        let appending = !previous.isEmpty && source.segments.starts(with: previous)
        var passages: [String: [Int]] = appending ? indexes[source.id]?.passages ?? [:] : [:]
        for (offset, segment) in source.segments.enumerated().dropFirst(appending ? previous.count : 0) {
            for token in Set(tokens(in: segment.text, language: source.language)) { passages[token, default: []].append(offset) }
        }
        let built = WordIndex(digest: digest, passages: passages)
        try? encoder.encode(built).write(to: url, options: .atomic)
        indexes[source.id] = built
        indexedSegments[source.id] = source.segments
        return built
    }
    private func tokens(in text: String, language: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: language))
        let tagger = NLTagger(tagSchemes: [.lemma]); tagger.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(ContextOccurrences.key(String(text[range])))
            if let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue {
                result.append(ContextOccurrences.key(lemma))
            }
            return true
        }
        return result
    }
}
