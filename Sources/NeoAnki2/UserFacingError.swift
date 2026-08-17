import Foundation
import NeoAnkiCore

enum UserFacingError {
    static func message(from error: Error) -> String {
        if let error = error as? DatabaseError {
            return databaseMessage(error)
        }
        if let error = error as? MediaError {
            return mediaMessage(error)
        }
        if let error = error as? ClozeValidationError {
            return clozeMessage(error)
        }
        if let error = error as? ImportError {
            return safeImportMessage(error)
        }
        return "Something went wrong. Try again."
    }

    static func importMessage(from error: Error) -> String {
        if let importError = error as? ImportError {
            return importMessage(importError)
        }
        if let dbError = error as? DatabaseError, case .requiredFieldEmpty(let field) = dbError {
            return "Every imported row needs a value for \(field)."
        }
        if let dbError = error as? DatabaseError {
            return databaseMessage(dbError)
        }
        if let clozeError = error as? ClozeValidationError {
            return clozeMessage(clozeError)
        }
        if let mediaError = error as? MediaError {
            return mediaMessage(mediaError)
        }
        if error is CocoaError {
            return "NeoAnki2 couldn’t read the selected file. Check that it still exists and try again."
        }
        return "NeoAnki2 couldn’t import this file. Check the file and try again."
    }

    private static func databaseMessage(_ error: DatabaseError) -> String {
        switch error {
        case .openFailed:
            "NeoAnki2 couldn't open your library. Check that its folder is available, then try again."
        case .executeFailed, .encodingFailed:
            "Your changes couldn't be saved. Try again."
        case .queryFailed:
            "Your library couldn't be loaded. Try again."
        case .itemTypeNotFound:
            "This item type could not be found."
        case .itemNotFound:
            "This item could not be found."
        case .cardNotFound:
            "This card could not be found."
        case .reviewLogNotFound:
            "There is no recent review to undo."
        case .studyResponseNotFound:
            "This saved response could not be found."
        case .templateNotFound:
            "This template could not be found."
        case .deckNotFound:
            "This deck could not be found."
        case let .requiredFieldEmpty(field):
            "\(field) is required."
        case .invalidItemType:
            "This item type isn't valid. Check its fields and templates."
        case .invalidItem:
            "This item isn't valid. Check its fields and tags."
        case .invalidDeck:
            "This deck isn't valid. Check its name and parent deck."
        case .resourceInUse:
            "This deck still contains items or subdecks. Move or delete them, then try again."
        case .invalidMediaAsset:
            "That media asset isn't valid."
        case .idempotencyConflict, .idempotencyRecordNotFound:
            "That request couldn't be safely retried. Try the action again."
        case .studySessionNotFound:
            "That study session no longer exists."
        case let .studyConflict(message):
            message
        case .decodingFailed:
            "Some library data couldn't be read. Restore a backup or contact support."
        case .unsupportedSchemaVersion:
            "This library was created by a newer version of NeoAnki2."
        case .schemaVersionReadFailed:
            "NeoAnki2 couldn't read this library. Its database may be damaged."
        case .templateDefinitionMigrationRequired:
            "This library needs its study templates migrated before NeoAnki2 can open it."
        }
    }

    private static func mediaMessage(_ error: MediaError) -> String {
        switch error {
        case let .fileTooLarge(kind, maxBytes):
            "Choose \(article(for: kind)) \(kind.rawValue) file smaller than \(maxBytes / 1_000_000) MB."
        case let .unsupportedFormat(kind):
            "Choose a supported \(kind.rawValue) file."
        case .ambiguousFormat:
            "That file matches more than one media format. Choose a standard audio, image, GIF, or video file."
        case .invalidPath:
            "That file location isn't valid. Choose the file again."
        case .readFailed:
            "That media file couldn't be read. Check that it still exists and try again."
        case .sandboxViolation:
            "That media file isn't in an allowed location."
        }
    }

    private static func article(for kind: MediaKind) -> String {
        switch kind {
        case .audio, .image: "an"
        case .gif, .video: "a"
        }
    }

    private static func clozeMessage(_ error: ClozeValidationError) -> String {
        switch error {
        case .emptyText:
            "Enter text before marking a blank."
        case .noBlanks:
            "Mark at least one blank."
        case .blankOutOfBounds:
            "That blank no longer matches the text. Mark it again."
        case .overlappingBlanks:
            "Blanks can't overlap."
        case .emptyBlank:
            "Select at least one character for the blank."
        }
    }

    private static func importMessage(_ error: ImportError) -> String {
        switch error {
        case let .invalidFormat(detail):
            "This file couldn’t be imported. \(detail)"
        case let .unknownField(name):
            "This file has a field named “\(name)” that isn’t in the selected item type."
        case .emptyPayload:
            "This file doesn’t contain any items."
        case let .itemTypeNotFound(name):
            "There is no item type named “\(name)”. Create it first or update the JSON file."
        }
    }

    private static func safeImportMessage(_ error: ImportError) -> String {
        if case .invalidFormat = error {
            return "This import file couldn't be read. Check its format and try again."
        }
        return importMessage(error)
    }
}
