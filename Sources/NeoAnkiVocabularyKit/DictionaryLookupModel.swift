import Foundation
import Observation

/// Source text remains editable content; no subject-specific fields or card recipes are inferred.
public enum DictionaryEntryText {
    public static func render(_ entry: LexicalEntry) -> String {
        var seen = Set<String>()
        func unique(_ values: [String]) -> [String] {
            values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
        }
        let spellings = unique([entry.canonicalForm.text.value] + entry.forms.map { $0.text.value })
        let annotations = unique(entry.pronunciations.flatMap { pronunciation in
            pronunciation.representations.compactMap { representation in
                if case let .text(text) = representation { return text.value }
                return nil
            }
        })
        let definitions = unique(entry.senses.flatMap { $0.definitions.map { $0.text.value } })
        return ([spellings.joined(separator: "\n"), annotations.joined(separator: "\n")]
            + definitions).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// Only values still owned by autofill may be replaced or cleared.
public struct DictionaryAutofillState {
    public private(set) var lastText: String?
    public init() {}

    public mutating func apply(_ text: String, replacing current: String) -> String? {
        guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == lastText else { return nil }
        lastText = text
        return text
    }

    public mutating func clear(replacing current: String) -> String? {
        defer { lastText = nil }
        return lastText != nil && current == lastText ? "" : nil
    }
}

@MainActor
@Observable
public final class DictionaryLookupModel {
    public private(set) var results: [LexicalEntry] = []
    public private(set) var automaticText: String?
    public private(set) var errorMessage: String?
    public private(set) var isSearching = false
    public private(set) var hasSearched = false
    private var generation = 0
    private var cachedPack: (url: URL, pack: VocabularyPack)?
    private let delay: Duration
    private let searchOverride: (@Sendable (String, URL, VocabularySearchMode) async throws -> [LexicalEntry])?

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
        searchOverride = nil
    }

    init(delay: Duration, search: @escaping @Sendable (String, URL, VocabularySearchMode) async throws -> [LexicalEntry]) {
        self.delay = delay
        searchOverride = search
    }

    public func invalidate() {
        generation += 1
        results = []
        automaticText = nil
        errorMessage = nil
        isSearching = false
        hasSearched = false
    }

    public func lookup(query: String, packURL: URL?) async {
        invalidate()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let packURL else { return }
        let request = generation
        isSearching = true
        do {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            let exact = try await search(query, url: packURL, mode: .exact)
            let entries = exact.isEmpty ? try await search(query, url: packURL, mode: .prefix) : exact
            guard request == generation, !Task.isCancelled else { return }
            results = entries
            if exact.count == 1 { automaticText = DictionaryEntryText.render(exact[0]) }
            hasSearched = true
            isSearching = false
        } catch {
            guard request == generation else { return }
            isSearching = false
            if !Task.isCancelled, !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func search(_ query: String, url: URL, mode: VocabularySearchMode) async throws -> [LexicalEntry] {
        if let searchOverride { return try await searchOverride(query, url, mode) }
        let pack: VocabularyPack
        if let cachedPack, cachedPack.url == url { pack = cachedPack.pack }
        else {
            pack = try await VocabularyPack.open(at: url)
            cachedPack = (url, pack)
        }
        return try await pack.search(query: query, mode: mode, limit: 50)
    }
}
