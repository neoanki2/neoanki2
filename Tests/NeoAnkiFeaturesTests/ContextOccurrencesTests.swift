import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
@testable import NeoAnkiFeatures

@Test func contextFindsSeparatedAndInflectedPhrasesAsCandidates() {
    let target = ContextTarget(expression: "take off", language: "en", meaning: "remove clothing")
    let match = ContextOccurrences.find(target: target, in: "She took her coat off.")
    #expect(match.uncertain)
    #expect(match.spans == [.init(start: 4, length: 4), .init(start: 18, length: 3)])
    let spans = ContextOccurrences.richText("She took her coat off.", spans: match.spans)
    #expect(spans.filter { $0.styles.contains(.bold) }.map(\.text) == ["took", "off"])
    #expect(ContextOccurrences.find(target: .init(expression: "art", language: "en"), in: "The party started.").spans.isEmpty)
    #expect(!ContextOccurrences.find(target: .init(expression: "学校", language: "ja"), in: "毎日学校へ行きます。").spans.isEmpty)
}

@Test func contextJapaneseSubstringIsNotAnAuthoritativeWordMatch() {
    #expect(ContextOccurrences.find(target: .init(expression: "学", language: "ja"), in: "学校へ行きます。").spans.isEmpty)
    #expect(!ContextOccurrences.find(target: .init(expression: "学校", language: "ja"), in: "学校へ行きます。").spans.isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NEOANKI_CONTEXT_LIVE_EVALUATION"] == "1"))
func contextAppleLiveCapabilityAndLatencyEvaluation() async throws {
    let generator = AppleContextGenerator(), clock = ContinuousClock()
    if let reason = await generator.availability(language: "en").reason {
        print("CONTEXT_EVAL generation_unavailable=\(reason)")
        return
    }
    for attempt in 1...2 {
        let started = clock.now
        let examples = try await generator.examples(
            for: .init(expression: "take into account", language: "en", meaning: "consider when deciding"),
            count: 1, excluding: [], simpler: false
        )
        #expect(examples.count == 1)
        #expect(examples.allSatisfy { !($0.meaning ?? "").isEmpty })
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("CONTEXT_EVAL attempt=\(attempt) elapsed=\(started.duration(to: clock.now)) valid_examples=\(examples.count) runner_peak_resident_bytes=\(usage.ru_maxrss)")
    }
}
