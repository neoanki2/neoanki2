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
    #expect(UserFacingError.message(from: error) == "Something went wrong. Try again.")
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
    #expect(UserFacingError.message(from: error) == "Something went wrong. Try again.")
}
