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

    static func importMessage(from error: Error) -> String {
        if let importError = error as? ImportError {
            switch importError {
            case let .invalidFormat(detail):
                return "This file couldn’t be imported. \(detail)"
            case let .unknownField(name):
                return "This file has a field named “\(name)” that isn’t in the selected item type."
            case .emptyPayload:
                return "This file doesn’t contain any items."
            case let .itemTypeNotFound(name):
                return "There is no item type named “\(name)”. Create it first or update the JSON file."
            }
        }
        if let dbError = error as? DatabaseError, case .requiredFieldEmpty(let field) = dbError {
            return "Every imported row needs a value for \(field)."
        }
        if let clozeError = error as? ClozeValidationError {
            return clozeError.localizedDescription
        }
        if let mediaError = error as? MediaError {
            return mediaError.localizedDescription
        }
        if error is CocoaError {
            return "NeoAnki2 couldn’t read the selected file. Check that it still exists and try again."
        }
        return "NeoAnki2 couldn’t import this file. Check the file and try again."
    }
}
