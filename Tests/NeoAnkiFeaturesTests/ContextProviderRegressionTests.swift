import Foundation
import NeoAnkiApplication
import Testing
@testable import NeoAnkiFeatures

@Suite struct ContextProviderRegressionTests {
    @Test func inferredPhraseCannotCrossASentenceBoundary() {
        let target = ContextTarget(expression: "take off", language: "en")
        #expect(ContextOccurrences.find(target: target, in: "She took the train. His coat was off.").spans.isEmpty)
        #expect(ContextOccurrences.find(target: target, in: "She took the train\nHis coat was off.").spans.isEmpty)
    }

    @Test func aMatchingFinalWordDoesNotBypassThePhraseGapLimit() {
        let target = ContextTarget(expression: "take off", language: "en")
        let text = "She took " + String(repeating: "a", count: 150) + " off."
        #expect(ContextOccurrences.find(target: target, in: text).spans.isEmpty)
        #expect(ContextOccurrences.find(target: .init(expression: "take into account", language: "en"),
            in: "They took the train into town and opened an account.").spans.isEmpty)
    }

    @Test func explicitSlotsAndInflectedTargetsAreMatchedWithoutManualMarking() {
        let target = ContextTarget(expression: "take [something] into account", language: "en")
        let sentence = "We took your proposal into account."
        let match = ContextOccurrences.find(target: target, in: sentence)
        #expect(ContextOccurrences.richText(sentence, spans: match.spans).filter { $0.styles.contains(.bold) }.map(\.text) == ["took", "into", "account"])
        let changedForm = ContextOccurrences.find(target: .init(expression: "bogged down", language: "en"),
                                                  in: "The details are bogging down the discussion.")
        #expect(!changedForm.spans.isEmpty)
    }

    @Test func everySeparatedOrInflectedOccurrenceIsIncludedInCloze() {
        let target = ContextTarget(expression: "take off", language: "en")
        let sentence = "She took her coat off, and he took his shoes off."
        let match = ContextOccurrences.find(target: target, in: sentence)
        #expect(ContextOccurrences.richText(sentence, spans: match.spans).filter { $0.styles.contains(.bold) }.map(\.text) == ["took", "off", "took", "off"])
        let partial = ContextExample(sentence: sentence, spans: Array(match.spans.prefix(2)), provenance: .init(origin: .manual, sourceName: "Fixture"))
        #expect(ContextOccurrences.clozeSpans(for: partial, target: target) == match.spans)

        let mixed = "I take off my coat while she took her jacket off."
        let all = ContextOccurrences.find(target: target, in: mixed)
        #expect(ContextOccurrences.richText(mixed, spans: all.spans).filter { $0.styles.contains(.bold) }.map(\.text) == ["take off", "took", "off"])
    }

    @Test func generatedFragmentsAndMissingContextNeverBecomeCards() {
        let target = ContextTarget(expression: "take off", language: "en")
        #expect(ContextGeneratedValidation.example(sentence: "Take off!", meaning: "leave", language: "en", target: target) == nil)
        #expect(ContextGeneratedValidation.example(sentence: "Please take off your coat", meaning: "remove", language: "en", target: target) == nil)
        #expect(ContextGeneratedValidation.example(sentence: "Please take off your coat.", meaning: "  ", language: "en", target: target) == nil)
        #expect(ContextGeneratedValidation.example(sentence: "Please take off your coat.", meaning: "remove clothing", language: "en", target: target) != nil)
    }

    @Test func aSupportedButIncorrectOutputLanguageCannotMislabelSpeech() {
        let target = ContextTarget(expression: "take into account", language: "en")
        let sentence = "Please take into account the cost of sending all those packages."
        #expect(ContextGeneratedValidation.example(sentence: sentence, meaning: "consider", language: "ja", target: target) == nil)
        #expect(ContextGeneratedValidation.example(sentence: sentence, meaning: "consider", language: "en-US", target: target)?.language == "en-US")
    }

    @Test func japaneseHighlightsRemainUnicodeSafeWithCanonicalLocaleCodes() {
        let target = ContextTarget(expression: "学校", language: "JA_jp")
        let sentence = "👩🏽‍💻 毎朝、私は学校へ歩いて通っています。"
        let example = ContextGeneratedValidation.example(sentence: sentence, meaning: "勉強する場所", language: "JA_jp", target: target)
        #expect(example?.language == "ja-JP")
        #expect(example.map { ContextOccurrences.validated($0.spans, in: sentence) } == true)
        #expect(example.map { ContextOccurrences.richText(sentence, spans: $0.spans).filter { $0.styles.contains(.bold) }.map(\.text) } == ["学校"])
    }

    @Test func voiceLocaleNormalizationAcceptsStandardAppleVariants() {
        #expect(ContextGeneratedValidation.languageCode(" EN_us ") == "en-US")
        #expect(ContextGeneratedValidation.languageCode("zh_hant_tw") == "zh-Hant-TW")
        #expect(ContextGeneratedValidation.languageCode("english") == nil)
        #expect(ContextGeneratedValidation.languageCode("en; instructions") == nil)
    }

    @Test @MainActor func blankSpeechFailsWithoutWaitingForAudioCallbacks() async {
        do {
            _ = try await AppleContextSpeech().audio(text: " \n ", language: "en")
            Issue.record("Blank speech must fail before contacting the synthesizer")
        } catch {
            #expect(error.localizedDescription == "There is no sentence to speak.")
        }
    }
}

enum ContextResponseFailure: Error, Sendable, CaseIterable, Equatable {
    case refusal, unsupportedLanguage, transport
}

private actor RecordedContextResponses {
    private let batches: [ContextGeneratedBatch]
    private let failure: ContextResponseFailure?
    private let cancelAfterResponse: Bool
    private(set) var requests: [ContextGenerationRequest] = []
    init(_ batches: [ContextGeneratedBatch], failure: ContextResponseFailure? = nil, cancelAfterResponse: Bool = false) {
        self.batches = batches; self.failure = failure; self.cancelAfterResponse = cancelAfterResponse
    }
    func next(_ request: ContextGenerationRequest) throws -> ContextGeneratedBatch {
        requests.append(request)
        if let failure { throw failure }
        if cancelAfterResponse { withUnsafeCurrentTask { $0?.cancel() } }
        guard requests.count <= batches.count else {
            Issue.record("The collector requested more model responses than the fixture permits")
            return .init(language: "en", candidates: [])
        }
        return batches[requests.count - 1]
    }
}

@Suite struct ContextGeneratedCollectorTests {
    private let target = ContextTarget(expression: "take off", language: "en")
    private static let first = ContextGeneratedCandidate(sentence: "Please take off your coat.", meaning: "remove clothing")
    private static let second = ContextGeneratedCandidate(sentence: "The planes take off at noon.", meaning: "leave the ground")
    private static let third = ContextGeneratedCandidate(sentence: "I take off my shoes at the door.", meaning: "remove footwear")
    private static let malformed = ContextGeneratedCandidate(sentence: "Only unrelated words.", meaning: "no target")

    @Test func malformedAndDuplicateOutputGetsOneCorrectionForOnlyMissingExamples() async throws {
        let responses = RecordedContextResponses([
            .init(language: "en", candidates: [Self.malformed, Self.first, Self.first]),
            .init(language: "en", candidates: [Self.first, Self.second, Self.third])
        ])
        let examples = try await ContextGeneratedCollector.examples(for: target, count: 3, excluding: []) {
            try await responses.next($0)
        }
        let requests = await responses.requests
        #expect(requests.count == 2)
        #expect(requests[0].count == 3 && !requests[0].isCorrection)
        #expect(requests[1].count == 2 && requests[1].isCorrection)
        #expect(requests[1].excluding.contains(Self.first.sentence))
        #expect(requests[1].excluding.contains(Self.malformed.sentence))
        #expect(examples.map(\.sentence) == [Self.first.sentence, Self.second.sentence, Self.third.sentence])
        #expect(examples.allSatisfy { ContextOccurrences.validated($0.spans, in: $0.sentence) })
    }

    @Test func correctionCanRepairTheMeaningOfAPreviouslyInvalidSentence() async throws {
        let responses = RecordedContextResponses([
            .init(language: "en", candidates: [.init(sentence: Self.first.sentence, meaning: " ")]),
            .init(language: "en", candidates: [Self.first])
        ])
        let examples = try await ContextGeneratedCollector.examples(for: target, count: 1, excluding: []) {
            try await responses.next($0)
        }
        #expect(examples.map(\.sentence) == [Self.first.sentence])
        #expect(examples.first?.meaning == Self.first.meaning)
        #expect(await responses.requests.count == 2)
    }

    @Test func allInvalidOutputStopsAtTwoRequestsWithoutReturningInvalidCards() async throws {
        let invalid = ContextGeneratedBatch(language: "en", candidates: [Self.malformed])
        let responses = RecordedContextResponses([invalid, invalid])
        let examples = try await ContextGeneratedCollector.examples(for: target, count: 3, excluding: []) {
            try await responses.next($0)
        }
        #expect(examples.isEmpty)
        let requests = await responses.requests
        #expect(requests.count == 2)
    }

    @Test func sufficientDistinctOutputDoesNotRequestACorrection() async throws {
        let responses = RecordedContextResponses([.init(language: "en", candidates: [Self.first, Self.second, Self.third])])
        let examples = try await ContextGeneratedCollector.examples(for: target, count: 3, excluding: []) {
            try await responses.next($0)
        }
        #expect(examples.count == 3)
        let requests = await responses.requests
        #expect(requests.count == 1)
    }

    @Test func excludedExamplesStayExcludedInTheCorrection() async throws {
        let responses = RecordedContextResponses([
            .init(language: "en", candidates: [Self.first, Self.second]),
            .init(language: "en", candidates: [Self.first, Self.third])
        ])
        let examples = try await ContextGeneratedCollector.examples(for: target, count: 2, excluding: [Self.first.sentence]) {
            try await responses.next($0)
        }
        #expect(examples.map(\.sentence) == [Self.second.sentence, Self.third.sentence])
        let requests = await responses.requests
        #expect(requests.count == 2 && requests[1].count == 1)
        #expect(requests[1].excluding.contains(Self.first.sentence))
    }

    @Test(arguments: ContextResponseFailure.allCases)
    func refusalUnsupportedLanguageAndErrorsNeverTriggerCorrection(_ failure: ContextResponseFailure) async {
        let responses = RecordedContextResponses([], failure: failure)
        do {
            _ = try await ContextGeneratedCollector.examples(for: target, count: 3, excluding: []) {
                try await responses.next($0)
            }
            Issue.record("Model failures must propagate")
        } catch let error as ContextResponseFailure {
            #expect(error == failure)
        } catch { Issue.record("Unexpected error: \(error)") }
        let requests = await responses.requests
        #expect(requests.count == 1)
    }

    @Test func cancellationAfterResponseStopsBeforeCorrection() async {
        let responses = RecordedContextResponses([.init(language: "en", candidates: [Self.malformed])], cancelAfterResponse: true)
        let target = target
        let task = Task {
            try await ContextGeneratedCollector.examples(for: target, count: 3, excluding: []) {
                try await responses.next($0)
            }
        }
        do { _ = try await task.value; Issue.record("Canceled generation must not return examples") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected error: \(error)") }
        let requests = await responses.requests
        #expect(requests.count == 1)
    }
}
