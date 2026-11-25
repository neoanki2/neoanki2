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

@Test func olderTemplateDefinitionsDefaultFitStudyAreaToOff() throws {
    let data = Data(#"{"id":"20000000-0000-4000-8000-000000000001","name":"Old","layout":"focus","components":[],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}"#.utf8)
    let decoded = try JSONDecoder().decode(Template.self, from: data)
    #expect(!decoded.fitStudyArea)

    var optedIn = decoded
    optedIn.fitStudyArea = true
    let roundTrip = try JSONDecoder().decode(Template.self, from: JSONEncoder().encode(optedIn))
    #expect(roundTrip.fitStudyArea)
}

@Test func persistedTemplateWireShapeAndCanonicalDigestRemainStable() throws {
    let itemType = compatibilityItemType()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(itemType.templates[0])
    let json = try #require(String(data: encoded, encoding: .utf8))

#expect(json.contains(#""fitStudyArea":false"#))
    let digest = try itemType.portableSchemaDigest()
    #expect(digest == "034d81aa2558b64050e1f088d99b61cda657104ec7d9ba64083f76a40f579b2a")

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
