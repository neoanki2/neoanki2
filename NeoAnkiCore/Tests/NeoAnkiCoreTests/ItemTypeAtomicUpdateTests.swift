import Foundation
import Testing
@testable import NeoAnkiCore

private struct AtomicUpdateFixture {
    let root: URL
    let store: ItemStore
    let itemType: ItemType
    let item: Item
    let audioTemplateID: UUID
    let audioCardID: UUID
    let audioURL: URL
}

private func makeAtomicUpdateFixture() async throws -> AtomicUpdateFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-atomic-type-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let back = FieldDef(name: "Back", type: .text, isRequired: true)
    let notes = FieldDef(name: "Notes", type: .text, isRequired: false)
    let basic = try TemplateBuilder.makeRevealTemplate(
        name: "Basic",
        promptFieldID: front.id,
        answerFieldID: back.id,
        in: ItemType(name: "Fixture", fields: [front, back], templates: [])
    )
    let audio = Template(
        name: "Audio Submission",
        layout: .actionStage,
        components: [TemplateComponent(
            region: .primary,
            purpose: .question,
            source: .field(front.id)
        )],
        interaction: .audioSubmission,
        skill: Skill(input: .text, output: .audio, operation: .reproduce)
    )
    let itemType = ItemType(
        name: "Fixture",
        fields: [front, back, notes],
        templates: [basic, audio]
    )
    _ = try await store.createItemType(itemType)
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: front.id, value: .text("Question")),
            FieldValue(fieldID: back.id, value: .text("Answer")),
            FieldValue(fieldID: notes.id, value: .text("Context")),
        ]
    )
    _ = try await store.createItem(item)
    let audioCardID = try #require(
        try await store.cards().first { $0.templateID == audio.id }?.id
    )
    let audioURL = root.appendingPathComponent("response.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: audioURL)
    return AtomicUpdateFixture(
        root: root,
        store: store,
        itemType: itemType,
        item: item,
        audioTemplateID: audio.id,
        audioCardID: audioCardID,
        audioURL: audioURL
    )
}

@Test func generatedCardRetirementErrorCopyUsesActualCountAndGrammar() {
    #expect(
        ItemTypeUpdateError.generatedCardRetirementImpactChanged(expected: 0, actual: 1)
            .errorDescription ==
            "Generated cards changed after confirmation. Saving would now retire 1 card. Review the impact again."
    )
    #expect(
        ItemTypeUpdateError.generatedCardRetirementImpactChanged(expected: 1, actual: 2)
            .errorDescription ==
            "Generated cards changed after confirmation. Saving would now retire 2 cards. Review the impact again."
    )
}

@Test func guardedItemTypeUpdateRejectsStaleDefinitionWithoutOverwrite() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    var externalEdit = fixture.itemType
    externalEdit.name = "External edit"
    _ = try await fixture.store.updateItemType(externalEdit)

    var studioEdit = fixture.itemType
    studioEdit.name = "Studio edit"
    let authorization = ItemTypeUpdateAuthorization(
        expectedOriginal: fixture.itemType,
        expectedStudyResponseDeletionIDs: []
    )

    await #expect(throws: ItemTypeUpdateError.staleDefinition(fixture.itemType.id)) {
        try await fixture.store.updateItemType(studioEdit, authorization: authorization)
    }
    #expect(try await fixture.store.itemType(id: fixture.itemType.id) == externalEdit)
}

@Test func guardedItemTypeUpdateAuthorizesPrivateResponseImpactInsideTransaction() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var candidate = fixture.itemType
    candidate.templates.removeAll { $0.id == fixture.audioTemplateID }
    let authorization = try await fixture.store.prepareItemTypeUpdateAuthorization(
        from: fixture.itemType,
        to: candidate
    )
    _ = try await fixture.store.completeAudioSubmission(StudyResponseDraft(
        cardID: fixture.audioCardID,
        fileURL: fixture.audioURL,
        durationMilliseconds: 1_000,
        capturedAt: .now
    ))
    await #expect(throws: ItemTypeUpdateError.studyResponseImpactChanged(expected: 0, actual: 1)) {
        try await fixture.store.updateItemType(candidate, authorization: authorization)
    }

    #expect(try await fixture.store.itemType(id: fixture.itemType.id) == fixture.itemType)
    #expect(try await fixture.store.studyResponseCount(templateIDs: [fixture.audioTemplateID]) == 1)
    #expect(try await fixture.store.card(id: fixture.audioCardID).templateID == fixture.audioTemplateID)
}

@Test func guardedUpdateAuthorizesResponsesForRetainedSetupMadeUnavailable() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.store.completeAudioSubmission(StudyResponseDraft(
        cardID: fixture.audioCardID,
        fileURL: fixture.audioURL,
        durationMilliseconds: 1_000,
        capturedAt: .now
    ))
    var candidate = fixture.itemType
    let backID = try #require(candidate.field(named: "Back")?.id)
    let audioIndex = try #require(candidate.templates.firstIndex { $0.id == fixture.audioTemplateID })
    candidate.templates[audioIndex].generateWhen = .fieldEmpty(backID)

    let authorization = try await fixture.store.prepareItemTypeUpdateAuthorization(
        from: fixture.itemType,
        to: candidate
    )
    #expect(authorization.expectedGeneratedCardRetirementCount == 1)
    #expect(authorization.expectedStudyResponseDeletionCount == 1)
    _ = try await fixture.store.updateItemType(candidate, authorization: authorization)
    #expect(try await fixture.store.studyResponseCount(templateIDs: [fixture.audioTemplateID]) == 0)
    await #expect(throws: DatabaseError.self) {
        _ = try await fixture.store.card(id: fixture.audioCardID)
    }
}

@Test func guardedUpdateAuthorizesResponsesForRetainedClozeGroups() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-atomic-cloze-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()

    var original = BuiltInItemTypes.cloze.duplicated(name: "Cloze audit")
    let textID = try #require(original.field(named: "Text")?.id)
    let replacement = FieldDef(name: "Replacement", type: .cloze)
    original.fields.append(replacement)
    _ = try await store.createItemType(original)
    let item = Item(itemTypeID: original.id, fields: [
        FieldValue(
            fieldID: textID,
            value: .cloze(
                "alpha beta",
                blanks: [
                    ClozeSpan(group: 1, start: 0, length: 5),
                    ClozeSpan(group: 2, start: 6, length: 4),
                ]
            )
        ),
        FieldValue(fieldID: replacement.id, value: .empty),
    ])
    _ = try await store.createItem(item)
    let groupTwo = try #require(try await store.cards().first { $0.clozeGroup == 2 })
    let audioURL = root.appendingPathComponent("response.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: audioURL)
    // Study responses are normally accepted only for Audio Submission. Change
    // only the persisted definition (without reconciling cards) to construct a
    // legacy response attached to a cloze group, then restore the real type.
    let database = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite"))
    var responseEnabled = original
    responseEnabled.templates[0].interaction = .audioSubmission
    try await database.updateItemType(responseEnabled)
    _ = try await store.completeAudioSubmission(StudyResponseDraft(
        cardID: groupTwo.id,
        fileURL: audioURL,
        durationMilliseconds: 1_000,
        capturedAt: .now
    ))
    try await database.updateItemType(original)

    var candidate = original
    candidate.templates[0].components = candidate.templates[0].components.map { component in
        guard component.purpose == .question else { return component }
        var component = component
        component.source = .field(replacement.id)
        return component
    }
    let authorization = try await store.prepareItemTypeUpdateAuthorization(
        from: original,
        to: candidate
    )
    #expect(authorization.expectedGeneratedCardRetirementCount == 2)
    #expect(authorization.expectedStudyResponseDeletionCount == 1)
    _ = try await store.updateItemType(candidate, authorization: authorization)
    #expect(try await store.studyResponseCount(itemIDs: [item.id]) == 0)
    #expect(try await store.cards().filter { $0.itemID == item.id }.isEmpty)
}

@Test func guardedUpdateRejectsEqualCountReplacementOfRetiredCardIdentity() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let notesID = try #require(fixture.itemType.field(named: "Notes")?.id)
    let basicID = try #require(
        fixture.itemType.templates.first { $0.interaction == .reveal }?.id
    )
    var candidate = fixture.itemType
    let basicIndex = try #require(candidate.templates.firstIndex { $0.id == basicID })
    candidate.templates[basicIndex].generateWhen = .fieldEmpty(notesID)
    let authorization = try await fixture.store.prepareItemTypeUpdateAuthorization(
        from: fixture.itemType,
        to: candidate
    )
    #expect(authorization.expectedGeneratedCardRetirementCount == 1)
    #expect(authorization.expectedStudyResponseDeletionCount == 0)
    #expect(authorization.expectedSchemaImpactState == .none)

    var changedOriginal = fixture.item
    changedOriginal.fields = changedOriginal.fields.map { field in
        field.fieldID == notesID ? FieldValue(fieldID: notesID, value: .empty) : field
    }
    _ = try await fixture.store.updateItem(changedOriginal)
    let replacement = Item(itemTypeID: fixture.itemType.id, fields: fixture.item.fields)
    _ = try await fixture.store.createItem(replacement)

    await #expect(
        throws: ItemTypeUpdateError.generatedCardRetirementImpactChanged(expected: 1, actual: 1)
    ) {
        try await fixture.store.updateItemType(candidate, authorization: authorization)
    }
    #expect(try await fixture.store.itemType(id: fixture.itemType.id) == fixture.itemType)
}

@Test func guardedUpdateRejectsEqualCountSchemaStateReplacement() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backID = try #require(fixture.itemType.field(named: "Back")?.id)
    var candidate = fixture.itemType
    candidate.fields.removeAll { $0.id == backID }
    candidate.templates = candidate.templates.map { template in
        var template = template
        template.components = template.components.map { component in
            guard case let .field(id) = component.source, id == backID else {
                return component
            }
            var component = component
            component.source = .literal("Replacement")
            return component
        }
        return template
    }
    let authorization = try await fixture.store.prepareItemTypeUpdateAuthorization(
        from: fixture.itemType,
        to: candidate
    )
    #expect(authorization.schemaChangeImpact.affectedItemCount == 1)

    var externalItem = fixture.item
    externalItem.fields = externalItem.fields.map { field in
        field.fieldID == backID
            ? FieldValue(fieldID: backID, value: .text("Different answer"))
            : field
    }
    _ = try await fixture.store.updateItem(externalItem)

    await #expect(throws: ItemTypeUpdateError.schemaImpactChanged(expected: 1, actual: 1)) {
        try await fixture.store.updateItemType(candidate, authorization: authorization)
    }
    #expect(try await fixture.store.itemType(id: fixture.itemType.id) == fixture.itemType)
}

@Test func guardedNoOpChecksAuthorizationWithoutEmittingChanges() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let authorization = try await fixture.store.prepareItemTypeUpdateAuthorization(
        from: fixture.itemType,
        to: fixture.itemType
    )
    let baseline = try await fixture.store.currentChangeCursor()
    _ = try await fixture.store.updateItemType(
        fixture.itemType,
        authorization: authorization
    )
    #expect(try await fixture.store.currentChangeCursor() == baseline)
    #expect(try await fixture.store.libraryChanges(after: baseline).isEmpty)
}

@Test func concurrentGuardedUpdatesAllowExactlyOneExpectedOriginal() async throws {
    let fixture = try await makeAtomicUpdateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let authorization = ItemTypeUpdateAuthorization(
        expectedOriginal: fixture.itemType,
        expectedStudyResponseDeletionIDs: []
    )
    var first = fixture.itemType
    first.name = "First"
    var second = fixture.itemType
    second.name = "Second"

    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for candidate in [first, second] {
            group.addTask {
                do {
                    _ = try await fixture.store.updateItemType(
                        candidate,
                        authorization: authorization
                    )
                    return true
                } catch ItemTypeUpdateError.staleDefinition(_) {
                    return false
                } catch {
                    Issue.record("Unexpected update failure: \(error)")
                    return false
                }
            }
        }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
    }

    #expect(results.filter { $0 }.count == 1)
    #expect([first, second].contains(try await fixture.store.itemType(id: fixture.itemType.id)))
}
