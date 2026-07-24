import Foundation
import NeoAnkiCore

enum UserFacingError {
    static func message(from error: Error) -> String {
        if let dbError = error as? DatabaseError, case .requiredFieldEmpty(let field) = dbError {
            return "\(field) is required."
        }
        return "Something went wrong. Try again."
    }
}
