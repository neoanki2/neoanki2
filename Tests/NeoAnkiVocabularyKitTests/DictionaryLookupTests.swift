import Foundation
import Observation
import Testing
@testable import NeoAnkiVocabularyKit

private func dictionaryEntry(_ word: String, id: String = "word") -> LexicalEntry {
    LexicalEntry(id: id, language: "uk", canonicalForm: .init(text: .init(word)),
                 senses: [.init(id: "meaning", definitions: [.init(text: .init("A definition."))])])
}

@Test func dictionaryTextPreservesSourceFormsAnnotationsAndDefinitions() {
    var entry = dictionaryEntry("абажур")
    entry.forms = [.init(text: .init("АБАЖУ\u{301}Р")), .init(text: .init("абажур"))]
    entry.pronunciations = [.init(scheme: "arbitrary-scheme", representations: [
        .text(.init("АБАЖУ\u{301}Р")), .text(.init("/abɑˈʒur/")), .audio(.init(path: "word.wav"))
    ])]
    #expect(DictionaryEntryText.render(entry) == "абажур\nАБАЖУ\u{301}Р\n\n/abɑˈʒur/\n\nA definition.")
    entry.senses = []
    #expect(DictionaryEntryText.render(entry).contains("АБАЖУ\u{301}Р"))
    #expect(!DictionaryEntryText.render(entry).contains("word.wav"))
}

@Test func dictionaryAutofillPreservesManualEditsAndClearsOnlyOwnedContent() {
    var state = DictionaryAutofillState()
    #expect(state.apply("First", replacing: "") == "First")
    #expect(state.apply("Second", replacing: "First") == "Second")
    #expect(state.apply("Third", replacing: "My own definition") == nil)
    #expect(state.clear(replacing: "My own definition") == nil)
    #expect(state.apply("Stress only", replacing: "") == "Stress only")
    #expect(state.clear(replacing: "Stress only") == "")
}

@Test @MainActor func dictionaryLookupAutofillsUniqueExactButNotAmbiguousOrPrefixMatches() async {
    let url = URL(fileURLWithPath: "/unused.neovocab")
    let model = DictionaryLookupModel(delay: .zero) { query, _, mode in
        switch query {
        case "exact": [dictionaryEntry("exact")]
        case "ambiguous": [dictionaryEntry("ambiguous", id: "one"), dictionaryEntry("ambiguous", id: "two")]
        case "pre": mode == .exact ? [] : [dictionaryEntry("prefix")]
        default: []
        }
    }
    await model.lookup(query: "exact", packURL: url)
    #expect(model.automaticText == "exact\n\nA definition.")
    await model.lookup(query: "ambiguous", packURL: url)
    #expect(model.results.count == 2)
    #expect(model.automaticText == nil)
    await model.lookup(query: "pre", packURL: url)
    #expect(model.results.count == 1)
    #expect(model.automaticText == nil)
    await model.lookup(query: "missing", packURL: url)
    #expect(model.hasSearched && model.results.isEmpty && !model.isSearching)
    await model.lookup(query: "", packURL: url)
    #expect(!model.hasSearched)
}

private actor DictionarySearchGate {
    var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation {
            continuation = $0
            started = true
            let pending = entryWaiters
            entryWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
    func waitUntilEntered() async {
        guard !started else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func dictionaryLookupRejectsLateResultsFromSupersededRequest() async {
    let gate = DictionarySearchGate()
    let model = DictionaryLookupModel(delay: .zero) { query, _, _ in
        if query == "old" { await gate.pause() }
        return [dictionaryEntry(query)]
    }
    let url = URL(fileURLWithPath: "/unused.neovocab")
    let old = Task { await model.lookup(query: "old", packURL: url) }
    await gate.waitUntilEntered()
    await model.lookup(query: "new", packURL: url)
    await gate.resume()
    await old.value
    #expect(model.automaticText == "new\n\nA definition.")
}

private actor DictionaryDebounceGate {
    private var suspended: CheckedContinuation<Void, any Error>?
    private var entered = false
    private var cancelled = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDuration: Duration?

    func sleep(for duration: Duration) async throws {
        requestedDuration = duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                suspended = continuation
                entered = true
                let pending = entryWaiters
                entryWaiters.removeAll()
                pending.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    private func cancel() {
        cancelled = true
        suspended?.resume(throwing: CancellationError())
        suspended = nil
    }
}

@Test @MainActor func dictionaryLookupCancellationAndErrorsLeaveManualAuthoringAvailable() async {
    let debounce = DictionaryDebounceGate()
    let model = DictionaryLookupModel(delay: .seconds(10), debounceSleep: { try await debounce.sleep(for: $0) }) { _, _, _ in
        Issue.record("A canceled debounce must not reach the dictionary.")
        return []
    }
    let task = Task { await model.lookup(query: "word", packURL: URL(fileURLWithPath: "/unused.neovocab")) }
    await debounce.waitUntilEntered()
    #expect(model.isSearching)
    #expect(await debounce.requestedDuration == .seconds(10))
    task.cancel()
    await task.value
    #expect(model.errorMessage == nil && model.results.isEmpty && !model.isSearching)
    let failed = DictionaryLookupModel(delay: .zero) { _, _, _ in throw VocabularyPackError.nonLocalURL }
    await failed.lookup(query: "word", packURL: URL(fileURLWithPath: "/unused.neovocab"))
    #expect(failed.errorMessage != nil && !failed.isSearching)
}

@Test @MainActor func dictionaryLookupUsesRealOfflinePackAndRetainsCombiningStress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-lookup-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var entry = dictionaryEntry("абажур")
    entry.forms = [.init(text: .init("АБАЖУ\u{301}Р"))]
    let jsonl = root.appendingPathComponent("entries.jsonl")
    try (JSONEncoder().encode(entry) + Data([10])).write(to: jsonl)
    let pack = root.appendingPathComponent("Fixture.neovocab")
    try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: pack,
        descriptor: .init(id: "fixture", title: "Fixture", languages: ["uk"], capabilities: [.lexicon]))
    let model = DictionaryLookupModel(delay: .zero)
    await model.lookup(query: " АБАЖУР ", packURL: pack)
    #expect(model.errorMessage == nil)
    #expect(model.automaticText?.contains("АБАЖУ\u{301}Р") == true)
    await model.lookup(query: "аба", packURL: pack)
    #expect(model.results.count == 1 && model.automaticText == nil)
}

private actor DictionaryPackOpenGate {
    var count = 0
    var continuation: CheckedContinuation<Void, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func open() async {
        count += 1
        let pending = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        pending.forEach { $0.1.resume() }
        if count == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func waitForOpenCount(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private func waitForDictionaryState(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let ready = withObservationTracking { condition() } onChange: {
            continuation.yield(())
            continuation.finish()
        }
        if ready { continuation.finish(); return }
        var iterator = changes.makeAsyncIterator()
        _ = await iterator.next()
        continuation.finish()
    }
}

@Test @MainActor func dictionaryLookupSharesPendingPackValidationWhileTyping() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-pending-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var entry = dictionaryEntry("начинка")
    entry.pronunciations = [.init(scheme: "orthographic-respelling", representations: [.text(.init("НА\u{301}ЧИНКА"))])]
    let jsonl = root.appendingPathComponent("entries.jsonl")
    try (JSONEncoder().encode(entry) + Data([10])).write(to: jsonl)
    let pack = root.appendingPathComponent("Fixture.neovocab")
    try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: pack,
        descriptor: .init(id: "fixture", title: "Fixture", languages: ["uk"], capabilities: [.lexicon]))
    let gate = DictionaryPackOpenGate()
    let model = DictionaryLookupModel(delay: .zero, openPack: { url in
        await gate.open()
        return try await VocabularyPack.open(at: url)
    })
    let old = Task { await model.lookup(query: "на", packURL: pack) }
    await gate.waitForOpenCount(1)
    old.cancel()
    model.invalidate()
    let replacement = Task { await model.lookup(query: "начинка", packURL: pack) }
    await waitForDictionaryState { model.isSearching }
    #expect(await gate.count == 1)
    await gate.resume()
    await replacement.value
    await old.value
    #expect(await gate.count == 1)
    #expect(model.automaticText?.contains("НА\u{301}ЧИНКА") == true)
    await model.lookup(query: "нач", packURL: pack)
    #expect(await gate.count == 1)
    #expect(model.results.count == 1 && model.automaticText == nil)
}

@Test @MainActor func dictionaryLookupDoesNotRunPrefixSearchAfterCancellation() async {
    let gate = DictionarySearchGate()
    let model = DictionaryLookupModel(delay: .zero) { _, _, mode in
        if mode == .exact { await gate.pause() }
        else { Issue.record("Canceled exact lookup must not start a prefix query.") }
        return []
    }
    let old = Task { await model.lookup(query: "на", packURL: URL(fileURLWithPath: "/unused.neovocab")) }
    await gate.waitUntilEntered()
    old.cancel()
    await gate.resume()
    await old.value
    #expect(model.results.isEmpty && model.errorMessage == nil && !model.isSearching)
}
