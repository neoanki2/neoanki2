import Foundation
import NeoAnkiCore

enum UserFacingError {
    static func message(from error: Error) -> String {
        if let dbError = error as? DatabaseError, case .requiredFieldEmpty(let field) = dbError {
            return "\(field) is required."
        }
        if let dbError = error as? DatabaseError,
           case .unsupportedSchemaVersion = dbError {
            return "This library was created by a newer version of NeoAnki2."
        }
        if let dbError = error as? DatabaseError,
           case .schemaVersionReadFailed = dbError {
            return "NeoAnki2 couldn't read this library. Its database may be damaged."
        }
        return "Something went wrong. Try again."
    }
}
