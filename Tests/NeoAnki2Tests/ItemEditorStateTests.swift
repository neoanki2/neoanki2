import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@Test func itemEditorStateHydratesEveryContentKind() {
    let plain = FieldDef(name: "Plain", type: .text, isRequired: true)
    let rich = FieldDef(name: "Rich", type: .richText)
    let number = FieldDef(name: "Number", type: .number)
    let image = FieldDef(name: "Image", type: .image)
    let cloze = FieldDef(name: "Cloze", type: .cloze)
    let itemType = ItemType(name: "Mixed", fields: [plain, rich, number, image, cloze], templates: [])
    let media = MediaRef(
        kind: .image,
        assetHash: String(repeating: "a", count: 64),
        fileExtension: "png",
        altText: "A labeled diagram"
    )
    let blank = ClozeSpan(group: 1, start: 0, length: 5, hint: "first word")
    let richSpans = [Span("Bold", styles: [.bold]), Span(" text")]
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: plain.id, value: .text("Question", lang: "en")),
            FieldValue(fieldID: rich.id, value: .rich(richSpans)),
            FieldValue(fieldID: number.id, value: .number(42.5)),
            FieldValue(fieldID: image.id, value: .media(media)),
            FieldValue(fieldID: cloze.id, value: .cloze("Alpha beta", blanks: [blank])),
        ]
    )

    let snapshot = ItemEditorState.hydrated(from: item, itemType: itemType)

    #expect(snapshot.fieldSpans[plain.id] == [Span("Question")])
    #expect(snapshot.fieldSpans[rich.id] == richSpans)
    #expect(snapshot.fieldText[number.id] == "42.5")
    #expect(snapshot.fieldMedia[image.id] == media)
    #expect(snapshot.fieldMediaAltText[image.id] == "A labeled diagram")
    #expect(snapshot.fieldText[cloze.id] == "Alpha beta")
    #expect(snapshot.fieldClozeBlanks[cloze.id] == [blank])
}

@Test func itemEditorStateValidatesRequiredFieldsAndImageDescriptions() {
    let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
    let image = FieldDef(name: "Image", type: .image)
    let audio = FieldDef(name: "Audio", type: .audio)
    let itemType = ItemType(name: "Media", fields: [prompt, image, audio], templates: [])
    let imageRef = MediaRef(
        kind: .image,
        assetHash: String(repeating: "b", count: 64),
        fileExtension: "png"
    )
    let audioRef = MediaRef(
        kind: .audio,
        assetHash: String(repeating: "c", count: 64),
        fileExtension: "mp3"
    )
    var snapshot = ItemEditorState.empty(for: itemType)

    #expect(ItemEditorState.canSave(snapshot, itemType: itemType) == false)
    snapshot.fieldSpans[prompt.id] = [Span("Question")]
    snapshot.fieldMedia[audio.id] = audioRef
    #expect(ItemEditorState.canSave(snapshot, itemType: itemType))

    snapshot.fieldMedia[image.id] = imageRef
    #expect(ItemEditorState.canSave(snapshot, itemType: itemType) == false)
    snapshot.fieldMediaAltText[image.id] = "   "
    #expect(ItemEditorState.canSave(snapshot, itemType: itemType) == false)
    snapshot.fieldMediaAltText[image.id] = "Map of France"
    #expect(ItemEditorState.canSave(snapshot, itemType: itemType))
}

@Test func itemEditorSnapshotUsesSharedDiscardDecision() {
    let itemType = ItemType(
        name: "Basic",
        fields: [FieldDef(name: "Prompt", type: .text, isRequired: true)],
        templates: []
    )
    let initial = ItemEditorState.empty(for: itemType)
    var changed = initial
    changed.fieldSpans[itemType.fields[0].id] = [Span("Changed")]

    #expect(EditorDecisionState.dismissalDecision(initial: initial, current: initial) == .dismiss)
    #expect(
        EditorDecisionState.dismissalDecision(initial: initial, current: changed)
            == .confirmDiscard
    )
}

@Test func mediaFieldPolicyRequiresDescriptionsOnlyForVisualMedia() {
    #expect(MediaFieldPolicy.requiresDescription(kind: .image, hasMedia: true))
    #expect(MediaFieldPolicy.requiresDescription(kind: .gif, hasMedia: true))
    #expect(MediaFieldPolicy.requiresDescription(kind: .audio, hasMedia: true) == false)
    #expect(MediaFieldPolicy.requiresDescription(kind: .video, hasMedia: true) == false)
    #expect(MediaFieldPolicy.requiresDescription(kind: .image, hasMedia: false) == false)
    #expect(MediaFieldPolicy.descriptionLabel(for: .image) == "Image description (required)")
    #expect(MediaFieldPolicy.descriptionLabel(for: .gif) == "Image description (required)")
    #expect(MediaFieldPolicy.descriptionLabel(for: .audio) == "Description (optional)")
    #expect(MediaFieldPolicy.descriptionLabel(for: .video) == "Description (optional)")
}

@Test func mediaPickerOffersOnlyFormatsAcceptedByCoreValidation() throws {
    for kind in [MediaKind.audio, .image, .gif, .video] {
        let acceptedExtensions = MediaValidation.allowedExtensions(for: kind)
        let offeredExtensions = MediaFieldPolicy.allowedFilenameExtensions(for: kind)
        #expect(
            MediaFieldPolicy.allowedContentTypes(for: kind).count == offeredExtensions.count,
            "Every offered extension must resolve to a system content type"
        )
        for fileExtension in offeredExtensions {
            #expect(
                acceptedExtensions.contains(fileExtension),
                "Picker offers \(fileExtension) for \(kind.rawValue), but core rejects it"
            )
        }
    }
}
