import Foundation
import NeoAnkiVocabularyKit

public enum LexicalEntryDraftError: Error, Sendable, Equatable, LocalizedError {
    case invalidExampleTarget(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidExampleTarget(id):
            "Example \(id) has a target that does not align with complete characters."
        }
    }
}

public enum LexicalEntryDraftFactory {
    /// Converts source Unicode-scalar ranges to the grapheme-cluster offsets used by NeoAnki cloze fields.
    /// A range that starts or ends inside a user-perceived character is deliberately rejected.
    public static func graphemeRange(
        in text: String,
        target: ExampleTarget,
        exampleID: String
    ) throws -> (start: Int, length: Int) {
        if let scalarRange = target.scalarRange {
            guard scalarRange.location >= 0, scalarRange.length > 0 else {
                throw LexicalEntryDraftError.invalidExampleTarget(exampleID)
            }
            let scalars = text.unicodeScalars
            guard let scalarStart = scalars.index(
                scalars.startIndex,
                offsetBy: scalarRange.location,
                limitedBy: scalars.endIndex
            ),
                let scalarEnd = scalars.index(
                    scalarStart,
                    offsetBy: scalarRange.length,
                    limitedBy: scalars.endIndex
                ),
                let startIndex = String.Index(scalarStart, within: text),
                let endIndex = String.Index(scalarEnd, within: text)
            else {
                throw LexicalEntryDraftError.invalidExampleTarget(exampleID)
            }

            let characterBoundaries = Set(text.indices).union([text.endIndex])
            guard characterBoundaries.contains(startIndex), characterBoundaries.contains(endIndex),
                  startIndex < endIndex,
                  String(text[startIndex ..< endIndex]) == target.exactText
            else {
                throw LexicalEntryDraftError.invalidExampleTarget(exampleID)
            }
            return (
                start: text[..<startIndex].count,
                length: text[startIndex ..< endIndex].count
            )
        }

        let matches = allRanges(of: target.exactText, in: text)
        guard matches.count == 1, let range = matches.first else {
            throw LexicalEntryDraftError.invalidExampleTarget(exampleID)
        }
        return (start: text[..<range.lowerBound].count, length: text[range].count)
    }

    public static func makeInput(
        entry: LexicalEntry,
        pack: VocabularyPack,
        destinationDeckID: UUID? = nil,
        deckName: String = "Vocabulary"
    ) async throws -> VocabularyDeckInput {
        var pronunciations: [VocabularyPronunciationSelection] = []
        let initiallySelectedSenseIDs = Set(entry.senses.compactMap { sense in
            sense.definitions.contains { !$0.text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ? sense.id
                : nil
        })
        for (pronunciationIndex, pronunciation) in entry.pronunciations.enumerated() {
            for (representationIndex, representation) in pronunciation.representations.enumerated() {
                let sourceID = pronunciation.id ?? "anonymous"
                let uniqueID = "pronunciation-\(pronunciationIndex + 1)-representation-\(representationIndex + 1)-\(sourceID)"
                let label = pronunciation.label ?? pronunciation.scheme
                let appliesToSelectedSenses = pronunciation.senseIDs.isEmpty
                    || (!initiallySelectedSenseIDs.isEmpty
                        && initiallySelectedSenseIDs.isSubset(of: Set(pronunciation.senseIDs)))
                let appliesToCanonicalForm = pronunciation.formIDs.isEmpty
                    || entry.canonicalForm.id.map { pronunciation.formIDs.contains($0) } == true
                let isSelected = appliesToSelectedSenses && appliesToCanonicalForm
                switch representation {
                case let .text(text):
                    pronunciations.append(.init(
                        id: uniqueID,
                        scheme: pronunciation.scheme,
                        displayLabel: label,
                        content: .text(text.value),
                        language: text.language,
                        formIDs: Set(pronunciation.formIDs),
                        senseIDs: Set(pronunciation.senseIDs),
                        provenance: provenance(pronunciation.provenance),
                        isSelected: isSelected
                    ))
                case let .audio(reference):
                    let resolved = try await pack.mediaURL(for: reference)
                    let supported = supportedAudioExtensions.contains(resolved.pathExtension.lowercased())
                    pronunciations.append(.init(
                        id: uniqueID,
                        scheme: pronunciation.scheme,
                        displayLabel: label,
                        content: .audio(resolved),
                        formIDs: Set(pronunciation.formIDs),
                        senseIDs: Set(pronunciation.senseIDs),
                        provenance: provenance(pronunciation.provenance),
                        availabilityError: supported
                            ? nil
                            : "\(resolved.pathExtension.uppercased()) audio is not supported in generated NeoAnki decks.",
                        isSelected: isSelected && supported
                    ))
                }
            }
        }

        let senses = entry.senses.enumerated().map { senseIndex, sense in
            let senseID = sense.id.isEmpty ? "sense-\(senseIndex + 1)" : sense.id
            let definition = sense.definitions.map(\.text.value).joined(separator: "\n\n")
            let definitionLanguages = sense.definitions.map(\.text.language)
            let definitionLanguage = definitionLanguages.allSatisfy { $0 == definitionLanguages.first ?? nil }
                ? definitionLanguages.first ?? nil
                : nil
            let examples = sense.examples.enumerated().map { exampleIndex, example in
                let sourceExampleID = example.id ?? "anonymous"
                let exampleID = "sense-\(senseIndex + 1)-example-\(exampleIndex + 1)-\(sourceExampleID)"
                guard let target = example.target,
                      let range = try? graphemeRange(
                          in: example.text.value,
                          target: target,
                          exampleID: exampleID
                      )
                else {
                    return VocabularyExampleSelection(
                        id: exampleID,
                        sourceID: example.id,
                        text: example.text.value,
                        targetStart: 0,
                        targetLength: 0,
                        targetText: example.target?.exactText ?? "",
                        provenance: provenance(example.provenance),
                        isSelected: false
                    )
                }
                return VocabularyExampleSelection(
                    id: exampleID,
                    sourceID: example.id,
                    text: example.text.value,
                    targetStart: range.start,
                    targetLength: range.length,
                    targetText: target.exactText,
                    provenance: provenance(example.provenance)
                )
            }
            return VocabularySenseSelection(
                id: senseID,
                definition: definition,
                definitionLanguage: definitionLanguage,
                definitionIDs: sense.definitions.compactMap(\.id),
                definitionProvenances: sense.definitions.compactMap { provenance($0.provenance) },
                provenance: provenance(sense.provenance),
                examples: examples,
                isSelected: !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        return VocabularyDeckInput(
            destinationDeckID: destinationDeckID,
            deckName: deckName,
            language: entry.canonicalForm.text.language ?? entry.language,
            formID: entry.canonicalForm.id,
            form: entry.canonicalForm.text.value,
            pronunciations: pronunciations,
            senses: senses,
            sourceLabel: pack.manifest.title,
            sourceContext: .init(
                packID: pack.manifest.id,
                entryID: entry.id,
                pack: provenance(pack.manifest.provenance),
                entry: provenance(entry.provenance)
            )
        )
    }

    private static let supportedAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf"]

    private static func provenance(_ value: Provenance?) -> VocabularyProvenanceSelection? {
        value.map {
            VocabularyProvenanceSelection(
                sourceID: $0.sourceID,
                sourceName: $0.sourceName,
                recordID: $0.recordID,
                attribution: $0.attribution,
                license: $0.license,
                sourceURL: $0.sourceURL
            )
        }
    }

    private static func allRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart ..< text.endIndex) {
            ranges.append(range)
            searchStart = text.index(after: range.lowerBound)
        }
        return ranges
    }
}
