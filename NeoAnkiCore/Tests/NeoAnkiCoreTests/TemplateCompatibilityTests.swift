import Foundation
import Testing
@testable import NeoAnkiCore

private let compatibilityFrontID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
private let compatibilityBackID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
private let compatibilityMediaID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
private let compatibilityTemplateID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!

private func compatibilityItemType() -> ItemType {
    ItemType(
        id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
        name: "Contract Type",
        fields: [
            FieldDef(id: compatibilityFrontID, name: "Front", type: .text, isRequired: true),
            FieldDef(id: compatibilityBackID, name: "Back", type: .richText, isRequired: true),
            FieldDef(id: compatibilityMediaID, name: "Media", type: .audio, isRequired: false),
        ],
        templates: [
            Template(
                id: compatibilityTemplateID,
                name: "Unusual Card",
                layout: .mediaAside,
                components: [
                    // Purpose, not region, owns the API answer projection. Keep
                    // this deliberately noncanonical to catch normalization.
                    TemplateComponent(
                        id: UUID(uuidString: "21000000-0000-4000-8000-000000000001")!,
                        region: .primary,
                        purpose: .expectedAnswer,
                        source: .field(compatibilityBackID),
                        presentation: Presentation(reveal: .blurred)
                    ),
                    TemplateComponent(
                        id: UUID(uuidString: "21000000-0000-4000-8000-000000000002")!,
                        region: .label,
                        purpose: .supporting,
                        source: .literal("Listen first")
                    ),
                    TemplateComponent(
                        id: UUID(uuidString: "21000000-0000-4000-8000-000000000003")!,
                        region: .media,
                        purpose: .question,
                        source: .field(compatibilityMediaID),
                        presentation: Presentation(media: .playOnTap)
                    ),
                    TemplateComponent(
                        id: UUID(uuidString: "21000000-0000-4000-8000-000000000004")!,
                        region: .supporting,
                        purpose: .supporting,
                        source: .field(compatibilityFrontID)
                    ),
                ],
                interaction: .type,
                skill: Skill(input: .audio, output: .freeResponse, operation: .recall),
                generateWhen: .all([
                    .fieldNotEmpty(compatibilityFrontID),
                    .any([
                        .fieldNotEmpty(compatibilityMediaID),
                        .fieldEmpty(compatibilityBackID),
                    ]),
                ])
            ),
        ]
    )
}

@Test func persistedTemplateWireShapeAndCanonicalDigestRemainStable() throws {
    let itemType = compatibilityItemType()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(itemType.templates[0])
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(json == #"{"components":[{"id":"21000000-0000-4000-8000-000000000001","presentation":{"media":"default","reveal":"blurred"},"purpose":"expectedAnswer","region":"primary","source":{"field":{"_0":"10000000-0000-4000-8000-000000000002"}}},{"id":"21000000-0000-4000-8000-000000000002","presentation":{"media":"default","reveal":"always"},"purpose":"supporting","region":"label","source":{"literal":{"_0":"Listen first"}}},{"id":"21000000-0000-4000-8000-000000000003","presentation":{"media":"playOnTap","reveal":"always"},"purpose":"question","region":"media","source":{"field":{"_0":"10000000-0000-4000-8000-000000000003"}}},{"id":"21000000-0000-4000-8000-000000000004","presentation":{"media":"default","reveal":"always"},"purpose":"supporting","region":"supporting","source":{"field":{"_0":"10000000-0000-4000-8000-000000000001"}}}],"generateWhen":{"all":{"_0":[{"fieldNotEmpty":{"_0":"10000000-0000-4000-8000-000000000001"}},{"any":{"_0":[{"fieldNotEmpty":{"_0":"10000000-0000-4000-8000-000000000003"}},{"fieldEmpty":{"_0":"10000000-0000-4000-8000-000000000002"}}]}}]}},"id":"20000000-0000-4000-8000-000000000001","interaction":"type","layout":"mediaAside","name":"Unusual Card","skill":{"input":"audio","operation":"recall","output":"freeResponse"}}"#)
    let digest = try itemType.portableSchemaDigest()
    #expect(digest == "324214e3048d4249c1123d807f0b09a1af3f6457bccbbe15728e755e193e83d1")

    let decoded = try JSONDecoder().decode(Template.self, from: encoded)
    #expect(decoded == itemType.templates[0])
    #expect(decoded.components.map(\.id) == itemType.templates[0].components.map(\.id))
    #expect(decoded.prompt.slots.map(\.source) == [
        .literal("Listen first"),
        .field(compatibilityMediaID),
        .field(compatibilityFrontID),
    ])
    #expect(decoded.answer.slots.map(\.source) == [.field(compatibilityBackID)])
}
