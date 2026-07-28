import Foundation
import Testing

@testable import NeoAnki2
@testable import NeoAnkiCore

@Test func userFacingErrorMapsRequiredField() {
    let error = DatabaseError.requiredFieldEmpty("Back")
    #expect(UserFacingError.message(from: error) == "Back is required.")
}

@Test func userFacingErrorMapsGenericDatabaseError() {
    let error = DatabaseError.openFailed("test")
    #expect(
        UserFacingError.message(from: error)
            == "NeoAnki2 couldn't open your library. Check that its folder is available, then try again."
    )
}

@Test func userFacingErrorMapsUnknownError() {
    struct SampleError: Error {}
    #expect(UserFacingError.message(from: SampleError()) == "Something went wrong. Try again.")
}

@Test func userFacingErrorExplainsNewerLibrary() {
    let error = DatabaseError.unsupportedSchemaVersion(999)
    #expect(
        UserFacingError.message(from: error)
            == "This library was created by a newer version of NeoAnki2."
    )
}

@Test func userFacingErrorExplainsUnreadableSchema() {
    #expect(
        UserFacingError.message(from: DatabaseError.schemaVersionReadFailed)
            == "NeoAnki2 couldn't read this library. Its database may be damaged."
    )
}

@Test func userFacingErrorMapsInvalidItemType() {
    let error = DatabaseError.invalidItemType("Template is invalid.")
    #expect(UserFacingError.message(from: error) == "This item type isn't valid. Check its fields and templates.")
}

@Test func userFacingErrorMapsMediaErrorsWithoutTechnicalDetails() {
    #expect(
        UserFacingError.message(from: MediaError.fileTooLarge(.audio, maxBytes: 20_000_000))
            == "Choose an audio file smaller than 20 MB."
    )
    #expect(
        UserFacingError.message(from: MediaError.readFailed)
            == "That media file couldn't be read. Check that it still exists and try again."
    )
}

@Test func userFacingErrorMapsClozeErrorsToRecoverySteps() {
    #expect(
        UserFacingError.message(from: ClozeValidationError.blankOutOfBounds)
            == "That blank no longer matches the text. Mark it again."
    )
    #expect(
        UserFacingError.message(from: ClozeValidationError.overlappingBlanks)
            == "Blanks can't overlap."
    )
}

@Test func userFacingErrorDoesNotExposeImportParserDetails() {
    let message = UserFacingError.message(
        from: ImportError.invalidFormat("NSCocoaErrorDomain Code=3840")
    )
    #expect(message == "This import file couldn't be read. Check its format and try again.")
    #expect(!message.contains("NSCocoaErrorDomain"))
}

@Test func userFacingErrorExplainsImportFormatProblem() {
    let error = ImportError.invalidFormat(
        "CSV cannot import the structured field \"Image\". Use JSON for cloze and media fields."
    )
    #expect(
        UserFacingError.importMessage(from: error)
            == "This file couldn’t be imported. CSV cannot import the structured field \"Image\". Use JSON for cloze and media fields."
    )
}

@Test func userFacingErrorExplainsMissingImportItemType() {
    let error = ImportError.itemTypeNotFound("Vocabulary")
    #expect(
        UserFacingError.importMessage(from: error)
            == "There is no item type named “Vocabulary”. Create it first or update the JSON file."
    )
}

@Test func importMessageMapsClozeAndMediaErrorsToPlainLanguage() {
    // These previously leaked raw `localizedDescription` text through the import path.
    #expect(
        UserFacingError.importMessage(from: ClozeValidationError.overlappingBlanks)
            == "Blanks can't overlap."
    )
    #expect(
        UserFacingError.importMessage(from: MediaError.fileTooLarge(.image, maxBytes: 10_000_000))
            == "Choose an image file smaller than 10 MB."
    )
    #expect(
        UserFacingError.importMessage(from: MediaError.unsupportedFormat(.video))
            == "Choose a supported video file."
    )
}
