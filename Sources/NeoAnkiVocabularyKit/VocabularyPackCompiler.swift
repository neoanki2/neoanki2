import Foundation

public enum VocabularyPackCompiler {
    public struct Options: Sendable {
        public var limits: VocabularyPackLimits
        /// Optional local directory containing audio files referenced by JSONL entries.
        public var mediaDirectoryURL: URL?

        public init(
            limits: VocabularyPackLimits = .default,
            mediaDirectoryURL: URL? = nil
        ) {
            self.limits = limits
            self.mediaDirectoryURL = mediaDirectoryURL
        }
    }

    /// Streams newline-delimited `LexicalEntry` JSON into an indexed, read-only `.neovocab` package.
    /// The destination must not already exist.
    @discardableResult
    public static func compile(
        jsonlURL: URL,
        to destinationURL: URL,
        descriptor: VocabularyPackDescriptor,
        options: Options = Options()
    ) throws -> VocabularyPackManifest {
        guard jsonlURL.isFileURL, destinationURL.isFileURL else {
            throw VocabularyPackError.nonLocalURL
        }
        guard destinationURL.pathExtension.lowercased() == "neovocab" else {
            throw VocabularyPackError.invalidPackage("Destination must use the .neovocab extension.")
        }
        try validate(descriptor: descriptor)
        try FileSafety.requireRegularFile(jsonlURL.standardizedFileURL, label: "JSONL source")
        if let media = options.mediaDirectoryURL {
            guard media.isFileURL else { throw VocabularyPackError.nonLocalURL }
            try FileSafety.requireDirectory(media.standardizedFileURL, label: "media source")
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            throw VocabularyPackError.invalidPackage("Destination already exists.")
        }
        let parent = destinationURL.deletingLastPathComponent().standardizedFileURL
        try FileSafety.requireDirectory(parent, label: "destination parent")
        let stagingURL = parent.appendingPathComponent(".neovocab-\(UUID().uuidString).tmp", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw VocabularyPackError.ioFailure(error.localizedDescription)
        }
        var shouldRemoveStaging = true
        defer { if shouldRemoveStaging { try? fileManager.removeItem(at: stagingURL) } }

        let databaseURL = stagingURL.appendingPathComponent("lexicon.sqlite", isDirectory: false)
        let database = try VocabularySQLiteDatabase(url: databaseURL, readOnly: false)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var entryCount = 0
        var audioPaths = Set<String>()
        do {
            try database.createSchema()
            try database.setMaximumDatabaseBytes(options.limits.maximumPackBytes)
            try database.begin()
            let reader = try JSONLineReader(url: jsonlURL, maximumLineBytes: options.limits.maximumJSONLineBytes)
            while let record = try reader.next() {
                if record.data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
                entryCount += 1
                guard entryCount <= options.limits.maximumEntries else {
                    throw VocabularyPackError.limitExceeded("more than \(options.limits.maximumEntries) entries")
                }
                let entry: LexicalEntry
                do { entry = try decoder.decode(LexicalEntry.self, from: record.data) }
                catch {
                    throw VocabularyPackError.malformedEntry(line: record.number, reason: error.localizedDescription)
                }
                do { try validate(entry: entry, limits: options.limits, audioPaths: &audioPaths) }
                catch let error as VocabularyPackError {
                    throw VocabularyPackError.malformedEntry(
                        line: record.number,
                        reason: error.errorDescription ?? String(describing: error)
                    )
                }
                let encoded = try encoder.encode(entry)
                guard encoded.count <= options.limits.maximumEncodedEntryBytes else {
                    throw VocabularyPackError.malformedEntry(line: record.number, reason: "encoded entry is too large")
                }
                try database.insert(entry, encoded: encoded)
                if entryCount.isMultiple(of: 1_000),
                   try FileSafety.fileSize(databaseURL) > options.limits.maximumPackBytes {
                    throw VocabularyPackError.limitExceeded("compiled database is too large")
                }
            }
            try database.commit()
            try database.close()
        } catch {
            database.rollback()
            try? database.close()
            throw error
        }

        let mediaFiles = try copyReferencedMedia(
            audioPaths,
            from: options.mediaDirectoryURL,
            to: stagingURL,
            limits: options.limits
        )
        guard try packageByteSize(stagingURL) <= options.limits.maximumPackBytes else {
            throw VocabularyPackError.limitExceeded("compiled package is too large")
        }

        let manifest = VocabularyPackManifest(
            id: descriptor.id,
            title: descriptor.title,
            summary: descriptor.summary,
            languages: descriptor.languages,
            capabilities: descriptor.capabilities,
            provenance: descriptor.provenance,
            entryCount: entryCount,
            databaseSHA256: try SHA256File.hexDigest(of: databaseURL),
            mediaFiles: mediaFiles
        )
        let manifestURL = stagingURL.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try manifestEncoder.encode(manifest)
            guard data.count <= options.limits.maximumManifestBytes else {
                throw VocabularyPackError.limitExceeded("manifest is too large")
            }
            try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            guard try packageByteSize(stagingURL) <= options.limits.maximumPackBytes else {
                throw VocabularyPackError.limitExceeded("compiled package is too large")
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL.standardizedFileURL)
            shouldRemoveStaging = false
        } catch let error as VocabularyPackError { throw error }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        return manifest
    }

    private static func validate(descriptor: VocabularyPackDescriptor) throws {
        guard !descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VocabularyPackError.invalidPackage("Pack ID is empty.")
        }
        guard !descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VocabularyPackError.invalidPackage("Pack title is empty.")
        }
        guard descriptor.languages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw VocabularyPackError.invalidPackage("Pack contains an empty language identifier.")
        }
    }

    private static func validate(
        entry: LexicalEntry,
        limits: VocabularyPackLimits,
        audioPaths: inout Set<String>
    ) throws {
        guard !entry.id.isEmpty else { throw VocabularyPackError.invalidPackage("entry ID is empty") }
        guard !entry.language.isEmpty else { throw VocabularyPackError.invalidPackage("entry language is empty") }
        guard !entry.canonicalForm.text.value.isEmpty else {
            throw VocabularyPackError.invalidPackage("canonical form is empty")
        }
        try requireByteLimit(entry.id, maximum: limits.maximumIndexedTextBytes, label: "entry ID")
        try requireByteLimit(entry.language, maximum: limits.maximumIndexedTextBytes, label: "entry language")
        try requireByteLimit(
            entry.canonicalForm.text.value,
            maximum: limits.maximumIndexedTextBytes,
            label: "canonical form"
        )
        guard entry.forms.count <= limits.maximumFormsPerEntry else {
            throw VocabularyPackError.limitExceeded("too many forms in entry \(entry.id)")
        }
        guard entry.senses.count <= limits.maximumSensesPerEntry else {
            throw VocabularyPackError.limitExceeded("too many senses in entry \(entry.id)")
        }
        guard entry.pronunciations.count <= limits.maximumPronunciationsPerEntry else {
            throw VocabularyPackError.limitExceeded("too many pronunciations in entry \(entry.id)")
        }
        if let frequency = entry.frequency, !frequency.isFinite {
            throw VocabularyPackError.invalidPackage("frequency is not finite")
        }
        try validate(provenance: entry.provenance)
        for form in [entry.canonicalForm] + entry.forms {
            guard !form.text.value.isEmpty else {
                throw VocabularyPackError.invalidPackage("entry contains an empty form")
            }
            guard form.grammaticalFeatures.count <= limits.maximumTraitsPerForm else {
                throw VocabularyPackError.limitExceeded("form contains too many grammatical traits")
            }
            try requireByteLimit(form.text.value, maximum: limits.maximumIndexedTextBytes, label: "form text")
            try validate(provenance: form.provenance)
        }
        let identifiedForms = [entry.canonicalForm] + entry.forms
        let formIDs = identifiedForms.compactMap(\.id)
        guard Set(formIDs).count == formIDs.count, formIDs.allSatisfy({ !$0.isEmpty }) else {
            throw VocabularyPackError.invalidPackage("form IDs must be non-empty and unique when present")
        }
        let knownFormIDs = Set(formIDs)
        var senseIDs = Set<String>()
        for sense in entry.senses {
            guard !sense.id.isEmpty, senseIDs.insert(sense.id).inserted else {
                throw VocabularyPackError.invalidPackage("sense IDs must be non-empty and unique")
            }
        }
        var pronunciationIDs = Set<String>()
        for pronunciation in entry.pronunciations {
            try validate(provenance: pronunciation.provenance)
            if let id = pronunciation.id {
                guard !id.isEmpty, pronunciationIDs.insert(id).inserted else {
                    throw VocabularyPackError.invalidPackage("pronunciation IDs must be non-empty and unique when present")
                }
            }
            guard !pronunciation.scheme.isEmpty else {
                throw VocabularyPackError.invalidPackage("pronunciation scheme is empty")
            }
            guard pronunciation.representations.count <= limits.maximumRepresentationsPerPronunciation else {
                throw VocabularyPackError.limitExceeded("pronunciation contains too many representations")
            }
            guard Set(pronunciation.formIDs).count == pronunciation.formIDs.count,
                  pronunciation.formIDs.allSatisfy(knownFormIDs.contains)
            else {
                throw VocabularyPackError.invalidPackage("pronunciation references an unknown or duplicate form ID")
            }
            guard Set(pronunciation.senseIDs).count == pronunciation.senseIDs.count,
                  pronunciation.senseIDs.allSatisfy(senseIDs.contains)
            else {
                throw VocabularyPackError.invalidPackage("pronunciation references an unknown or duplicate sense ID")
            }
            for representation in pronunciation.representations {
                switch representation {
                case let .text(text):
                    guard !text.value.isEmpty else {
                        throw VocabularyPackError.invalidPackage("pronunciation text is empty")
                    }
                case let .audio(audio):
                    guard FileSafety.isSafeRelativePath(audio.path) else {
                        throw VocabularyPackError.invalidPackage("unsafe audio path")
                    }
                    try requireByteLimit(audio.path, maximum: limits.maximumAudioPathBytes, label: "audio path")
                    if audioPaths.insert(audio.path).inserted,
                       audioPaths.count > limits.maximumMediaFiles {
                        throw VocabularyPackError.limitExceeded("too many media files")
                    }
                }
            }
        }
        for sense in entry.senses {
            try validate(provenance: sense.provenance)
            guard sense.examples.count <= limits.maximumExamplesPerSense else {
                throw VocabularyPackError.limitExceeded("too many examples in sense \(sense.id)")
            }
            guard sense.definitions.count <= limits.maximumDefinitionsPerSense else {
                throw VocabularyPackError.limitExceeded("too many definitions in sense \(sense.id)")
            }
            guard sense.labels.count <= limits.maximumLabelsPerSense else {
                throw VocabularyPackError.limitExceeded("too many labels in sense \(sense.id)")
            }
            guard sense.definitions.allSatisfy({ !$0.text.value.isEmpty }) else {
                throw VocabularyPackError.invalidPackage("definition text is empty")
            }
            for definition in sense.definitions {
                try validate(provenance: definition.provenance)
            }
            var exampleIDs = Set<String>()
            for example in sense.examples {
                if let id = example.id {
                    guard !id.isEmpty, exampleIDs.insert(id).inserted else {
                        throw VocabularyPackError.invalidPackage(
                            "example IDs must be non-empty and unique within a sense when present"
                        )
                    }
                }
                try validate(provenance: example.provenance)
                try validate(example: example)
            }
        }
    }

    private static func requireByteLimit(_ value: String, maximum: Int, label: String) throws {
        guard value.utf8.count <= maximum else {
            throw VocabularyPackError.limitExceeded("\(label) exceeds byte limit")
        }
    }

    private static func validate(provenance: Provenance?) throws {
        guard let provenance else { return }
        guard !provenance.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VocabularyPackError.invalidPackage("provenance sourceID is empty")
        }
    }

    private static func validate(example: UsageExample) throws {
        guard !example.text.value.isEmpty else {
            throw VocabularyPackError.invalidPackage("example text is empty")
        }
        guard let target = example.target else { return }
        guard !target.exactText.isEmpty else {
            throw VocabularyPackError.invalidPackage("example target is empty")
        }
        let scalars = Array(example.text.value.unicodeScalars)
        if let range = target.scalarRange {
            guard range.location >= 0, range.length > 0,
                  range.location <= scalars.count,
                  range.length <= scalars.count - range.location
            else {
                throw VocabularyPackError.invalidPackage("example target scalar range is out of bounds")
            }
            let selected = String(String.UnicodeScalarView(scalars[range.location..<(range.location + range.length)]))
            guard selected == target.exactText else {
                throw VocabularyPackError.invalidPackage("example target range does not match exactText")
            }
        } else {
            guard occurrenceCount(of: target.exactText, in: example.text.value) == 1 else {
                throw VocabularyPackError.invalidPackage(
                    "example targets that occur more than once require a scalar range"
                )
            }
        }
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: needle, range: start ..< text.endIndex) {
            count += 1
            start = text.index(after: range.lowerBound)
        }
        return count
    }

    private static func copyReferencedMedia(
        _ paths: Set<String>,
        from sourceDirectory: URL?,
        to stagingURL: URL,
        limits: VocabularyPackLimits
    ) throws -> [VocabularyPackMediaFile] {
        guard !paths.isEmpty else { return [] }
        guard let sourceDirectory else {
            throw VocabularyPackError.invalidPackage("Audio references require a local media directory.")
        }
        guard paths.count <= limits.maximumMediaFiles else {
            throw VocabularyPackError.limitExceeded("too many media files")
        }
        let sourceRoot = sourceDirectory.standardizedFileURL
        let resolvedRoot = sourceRoot.resolvingSymlinksInPath()
        let targetRoot = stagingURL.appendingPathComponent("media", isDirectory: true)
        do { try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: false) }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        var byteCount: Int64 = 0
        var result: [VocabularyPackMediaFile] = []
        for path in paths.sorted() {
            guard FileSafety.isSafeRelativePath(path) else {
                throw VocabularyPackError.invalidPackage("Unsafe media path.")
            }
            let source = sourceRoot.appendingPathComponent(path).standardizedFileURL
            let resolvedSource = source.resolvingSymlinksInPath()
            guard resolvedSource.path.hasPrefix(resolvedRoot.path + "/") else {
                throw VocabularyPackError.invalidPackage("Media path escapes its source directory.")
            }
            try FileSafety.requireNoSymlinkComponents(relativePath: path, below: sourceRoot)
            try FileSafety.requireRegularFile(source, label: "media source")
            let target = targetRoot.appendingPathComponent(path).standardizedFileURL
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: target)
            } catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
            let copiedSize = try FileSafety.fileSize(target)
            let (newByteCount, overflow) = byteCount.addingReportingOverflow(copiedSize)
            guard !overflow, newByteCount <= limits.maximumMediaBytes else {
                throw VocabularyPackError.limitExceeded("media exceeds byte limit")
            }
            byteCount = newByteCount
            result.append(
                VocabularyPackMediaFile(
                    path: path,
                    byteSize: copiedSize,
                    sha256: try SHA256File.hexDigest(of: target)
                )
            )
        }
        return result
    }

    private static func packageByteSize(_ root: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw VocabularyPackError.ioFailure("Cannot enumerate compiled package.") }
        var result: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw VocabularyPackError.invalidPackage("Compiled package contains a symbolic link.")
            }
            if values.isRegularFile == true {
                let (newResult, overflow) = result.addingReportingOverflow(Int64(values.fileSize ?? 0))
                guard !overflow else {
                    throw VocabularyPackError.limitExceeded("compiled package size overflow")
                }
                result = newResult
            }
        }
        return result
    }
}

private final class JSONLineReader {
    struct Record {
        let number: Int
        let data: Data
    }

    private let handle: FileHandle
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var reachedEOF = false
    private var lineNumber = 0

    init(url: URL, maximumLineBytes: Int) throws {
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        self.maximumLineBytes = maximumLineBytes
    }

    deinit { try? handle.close() }

    func next() throws -> Record? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                lineNumber += 1
                guard line.count <= maximumLineBytes else {
                    throw VocabularyPackError.limitExceeded("JSONL line is too large")
                }
                if line.last == 0x0D { line.removeLast() }
                if lineNumber == 1, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
                return Record(number: lineNumber, data: line)
            }
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                var line = buffer
                buffer.removeAll(keepingCapacity: false)
                lineNumber += 1
                guard line.count <= maximumLineBytes else {
                    throw VocabularyPackError.limitExceeded("JSONL line is too large")
                }
                if line.last == 0x0D { line.removeLast() }
                if lineNumber == 1, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
                return Record(number: lineNumber, data: line)
            }
            let chunk: Data
            do { chunk = try handle.read(upToCount: 64 * 1024) ?? Data() }
            catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
            if chunk.isEmpty { reachedEOF = true }
            else { buffer.append(chunk) }
            guard buffer.count <= maximumLineBytes || buffer.contains(0x0A) else {
                throw VocabularyPackError.limitExceeded("JSONL line is too large")
            }
        }
    }
}
