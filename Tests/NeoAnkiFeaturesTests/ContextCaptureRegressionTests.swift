import Foundation
@preconcurrency import AVFoundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing
@testable import NeoAnkiFeatures

private actor CaptureProbeGenerator: ContextGenerating {
    private let output: [ContextExample]
    private let held: Bool
    private let unavailableLanguages: Set<String>
    private var pending: CheckedContinuation<[ContextExample], Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requests: [ContextTarget] = []
    private(set) var exclusions: [[String]] = []
    init(output: [ContextExample], held: Bool = false, unavailableLanguages: Set<String> = []) {
        self.output = output; self.held = held; self.unavailableLanguages = unavailableLanguages
    }
    func availability(language: String) async -> ContextCapability {
        unavailableLanguages.contains(language) ? .unavailable("No model for this language") : .available
    }
    func examples(for target: ContextTarget, count: Int, excluding: [String], simpler: Bool) async throws -> [ContextExample] {
        requests.append(target); exclusions.append(excluding)
        guard held else { return output }
        return await withCheckedContinuation { continuation in
            pending = continuation; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { pending?.resume(returning: output); pending = nil }
}

private struct CaptureNoSpeech: ContextSpeechSynthesizing {
    func availability(language: String) async -> ContextCapability { .unavailable("No installed voice") }
    func audio(text: String, language: String) async throws -> ContextSpeechAsset {
        throw ContextAuthoringError.message("No installed voice")
    }
}

@MainActor private final class CaptureSpeechProbe: ContextSpeechSynthesizing {
    private let data: Data
    private let heldFirst: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requests: [String] = []
    init(heldFirst: Bool = false) throws {
        self.heldFirst = heldFirst
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("context-probe-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80))
        buffer.frameLength = 80
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 80)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        data = try Data(contentsOf: url)
    }
    func availability(language: String) async -> ContextCapability {
        language == "en" ? .available : .unavailable("No installed voice")
    }
    func audio(text: String, language: String) async throws -> ContextSpeechAsset {
        requests.append(language)
        if heldFirst, requests.count == 1 {
            await withCheckedContinuation { continuation in
                pending = continuation; waiter?.resume(); waiter = nil
            }
        }
        return ContextSpeechAsset(data: data, voiceID: "fixture-\(language)")
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finishFirst() { pending?.resume(); pending = nil }
}

private func captureExample(_ sentence: String = "We take into account the cost.", expression: String = "take into account",
                            meaning: String = "consider when deciding", language: String = "en") -> ContextExample {
    .init(sentence: sentence, spans: ContextOccurrences.find(target: .init(expression: expression, language: language), in: sentence).spans,
          meaning: meaning, language: language, provenance: .init(origin: .generated, sourceName: "Fixture"))
}

@MainActor private final class CaptureRegressionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-capture-regression-\(UUID())")
    let repository: SQLiteLibraryRepository
    let deck: Deck
    let model: LearnInContextModel
    init(generator: any ContextGenerating, speech: (any ContextSpeechSynthesizing)? = nil) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        deck = try await repository.createDeck(Deck(name: "Expressions"))
        model = LearnInContextModel(library: repository, rootURL: root.appendingPathComponent("packs"), generator: generator,
                                    speech: speech ?? CaptureNoSpeech())
        await model.start(deckID: deck.id)
    }
    func cleanup() { model.cancel(); try? FileManager.default.removeItem(at: root) }
    func install(_ entry: LexicalEntry) async throws {
        let jsonl = root.appendingPathComponent("entries.jsonl")
        try (JSONEncoder().encode(entry) + Data([10])).write(to: jsonl)
        let package = root.appendingPathComponent("fixture.neovocab")
        try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: package, descriptor: .init(
            id: "capture.fixture", title: "Capture fixture", languages: [entry.language], capabilities: [.lexicon, .corpus]))
        _ = try await InstalledVocabularyPackStore(rootURL: root.appendingPathComponent("packs")).install(from: package)
        await model.start(deckID: deck.id)
    }
}

@Suite struct ContextCaptureRegressionTests {
    @Test @MainActor func whitespaceAndBlurDoNotCancelPhraseGeneration() async throws {
        let generator = CaptureProbeGenerator(output: [captureExample()], held: true)
        let fixture = try await CaptureRegressionFixture(generator: generator)
        defer { fixture.cleanup() }
        let entered = "  take into account \n"
        fixture.model.updateExpression(entered)
        fixture.model.findExamples(); await generator.waitUntilRequested()
        #expect(fixture.model.draft.target.expression == entered)
        #expect(await generator.requests.first?.expression == "take into account")
        fixture.model.updateExpression(entered)
        #expect(fixture.model.isWorking)
        await generator.finish(); await fixture.model.waitForWork()
        #expect(fixture.model.canSave)
        await fixture.model.save()
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.model.lastSavedItems.first?.value(for: ContextExamplePreset.target.id) == .text("take into account", lang: "en"))
    }

    @Test @MainActor func dictionaryResolutionPreservesInputDuringBlur() async throws {
        let generator = CaptureProbeGenerator(output: [captureExample("They take off their coats.", expression: "take off", meaning: "remove clothing")], held: true)
        let fixture = try await CaptureRegressionFixture(generator: generator)
        defer { fixture.cleanup() }
        try await fixture.install(.init(id: "take-off", language: "en", canonicalForm: .init(text: .init("take off", language: "en")), senses: [
            .init(id: "remove", definitions: [.init(text: .init("remove clothing", language: "en"))], examples: [.init(text: .init("Please take off your coat.", language: "en"))])
        ]))
        let entered = " take off "
        fixture.model.updateExpression(entered)
        fixture.model.findExamples(); await generator.waitUntilRequested()
        #expect(fixture.model.draft.target.expression == entered)
        #expect(fixture.model.draft.target.senseID == "remove")
        fixture.model.updateExpression(entered)
        #expect(fixture.model.isWorking)
        await generator.finish(); await fixture.model.waitForWork()
        #expect(fixture.model.selectedExamples.count == 2)
        #expect(fixture.model.canSave)
    }

    @Test @MainActor func hiddenDraftCandidatesDoNotBlockAValidRetry() async throws {
        let example = captureExample()
        let generator = CaptureProbeGenerator(output: [example])
        let fixture = try await CaptureRegressionFixture(generator: generator)
        defer { fixture.cleanup() }
        fixture.model.updateExpression("take into account")
        var hidden = example; hidden.isSelected = false; hidden.needsMeaningCheck = true
        fixture.model.draft.examples = [hidden]
        fixture.model.findExamples(); await fixture.model.waitForWork()
        #expect(await generator.exclusions == [[]])
        #expect(fixture.model.draft.examples.count == 1)
        #expect(fixture.model.selectedExamples.count == 1)
        #expect(fixture.model.canSave)
    }

    @Test @MainActor func missingGeneratedMeaningProducesAnErrorInsteadOfDisabledAdd() async throws {
        let generator = CaptureProbeGenerator(output: [captureExample(meaning: "  ")])
        let fixture = try await CaptureRegressionFixture(generator: generator)
        defer { fixture.cleanup() }
        fixture.model.updateExpression("take into account")
        fixture.model.findExamples(); await fixture.model.waitForWork()
        #expect(fixture.model.selectedExamples.isEmpty)
        #expect(fixture.model.errorMessage != nil)
        #expect(!fixture.model.canSave)
    }

    @Test @MainActor func anUnusableRestoredRowCanBeReplacedWithoutManualAnnotation() async throws {
        let example = captureExample()
        let fixture = try await CaptureRegressionFixture(generator: CaptureProbeGenerator(output: [example]))
        defer { fixture.cleanup() }
        fixture.model.updateExpression("take into account")
        var invalid = example; invalid.spans = []
        fixture.model.draft.examples = [invalid]
        fixture.model.checkpoint()
        await fixture.model.start()
        #expect(fixture.model.selectedExamples.isEmpty)
        fixture.model.findExamples(); await fixture.model.waitForWork()
        #expect(fixture.model.selectedExamples.count == 1)
        #expect(fixture.model.canSave)
    }

    @Test @MainActor func interruptedSaveRetryDoesNotClaimAnotherDestinationDeck() async throws {
        let fixture = try await CaptureRegressionFixture(generator: CaptureProbeGenerator(output: []))
        defer { fixture.cleanup() }
        fixture.model.updateExpression("take into account")
        fixture.model.draft.examples = [captureExample()]
        let snapshot = fixture.model.draft
        await fixture.model.save()
        let id = try #require(fixture.model.lastSavedIDs.first)
        let other = try await fixture.repository.createDeck(Deck(name: "Another deck"))
        fixture.model.draft = snapshot; fixture.model.draft.deckID = other.id
        await fixture.model.save()
        #expect(fixture.model.errorMessage?.contains("another deck") == true)
        #expect(fixture.model.successMessage == nil)
        #expect(try await fixture.repository.item(id: id)?.item.deckID == fixture.deck.id)
    }

    @Test @MainActor func shortLatinWordDoesNotInheritAnUnsupportedLanguageBlock() async throws {
        let generator = CaptureProbeGenerator(output: [captureExample("The art is beautiful.", expression: "art", meaning: "creative work")], unavailableLanguages: ["uk"])
        let fixture = try await CaptureRegressionFixture(generator: generator)
        defer { fixture.cleanup() }
        fixture.model.draft.target.language = "uk"
        fixture.model.updateExpression("art")
        fixture.model.findExamples(); await fixture.model.waitForWork()
        #expect(await generator.requests.first?.language == "en")
        #expect(fixture.model.canSave)
    }

    @Test @MainActor func installedDictionarySuppliesLanguageWhenTheHintDoesNotMatch() async throws {
        let generator = CaptureProbeGenerator(output: [], unavailableLanguages: ["en", "uk"])
        let fixture = try await CaptureRegressionFixture(generator: generator)
        defer { fixture.cleanup() }
        try await fixture.install(.init(id: "uk:taksi", language: "uk", canonicalForm: .init(text: .init("таксі", language: "uk")), senses: [
            .init(id: "car", definitions: [.init(text: .init("Автомобіль для перевезення пасажирів.", language: "uk"))], examples: [.init(text: .init("Таксі вже чекає.", language: "uk"))])
        ]))
        fixture.model.draft.target.language = "en"
        fixture.model.updateExpression("таксі")
        fixture.model.findExamples(); await fixture.model.waitForWork()
        #expect(fixture.model.draft.target.language == "uk")
        #expect(fixture.model.selectedExamples.count == 1)
        #expect(fixture.model.canSave)
    }

    @Test @MainActor func eachExampleUsesItsOwnVoiceAvailabilityWhenSaving() async throws {
        let speech = try CaptureSpeechProbe()
        let fixture = try await CaptureRegressionFixture(generator: CaptureProbeGenerator(output: []), speech: speech)
        defer { fixture.cleanup() }
        fixture.model.draft.target = .init(expression: "OK", language: "uk")
        fixture.model.draft.examples = [
            captureExample("Everything is OK.", expression: "OK", meaning: "satisfactory", language: "en"),
            captureExample("Ми сказали OK.", expression: "OK", meaning: "згода", language: "uk")
        ]
        await fixture.model.refreshCapabilities()
        #expect(fixture.model.speechCapability != .available)
        #expect(fixture.model.speechAvailability(for: fixture.model.draft.examples[0]) == .available)
        #expect(fixture.model.speechAvailability(for: fixture.model.draft.examples[1]) != .available)
        await fixture.model.save()
        #expect(fixture.model.errorMessage == nil)
        #expect(speech.requests == ["en"])
        #expect(fixture.model.lastSavedItems.count == 2)
        #expect(fixture.model.lastSavedItems[0].value(for: ContextExamplePreset.audio.id)?.mediaReference != nil)
        #expect(fixture.model.lastSavedItems[1].isFieldEmpty(ContextExamplePreset.audio.id))
    }

    @Test @MainActor func cancelledQueuedSpeechDoesNotCallTheBusySynthesizer() async throws {
        let speech = try CaptureSpeechProbe(heldFirst: true)
        let fixture = try await CaptureRegressionFixture(generator: CaptureProbeGenerator(output: []), speech: speech)
        defer { fixture.cleanup() }
        let preview = Task { try await fixture.model.preparedAudio(for: captureExample()) }
        await speech.waitUntilStarted()
        // Both tasks are MainActor-bound. Cancel before yielding, so the second caller starts canceled.
        let queued = Task { try await fixture.model.preparedAudio(for: captureExample("Please take into account the weather.")) }
        queued.cancel()
        speech.finishFirst()
        _ = try await preview.value
        do { _ = try await queued.value; Issue.record("Canceled speech should not produce audio") }
        catch is CancellationError { }
        #expect(speech.requests == ["en"])
    }
}
