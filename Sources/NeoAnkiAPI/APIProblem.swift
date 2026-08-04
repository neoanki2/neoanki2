import Foundation
import NeoAnkiCore

public struct APIFieldProblem: Codable, Sendable, Equatable {
    public let pointer: String
    public let code: String
}

public struct APIProblem: Codable, Sendable, Equatable {
    public let type: String
    public let title: String
    public let status: Int
    public let code: String
    public let detail: String
    public let requestId: String
    public let errors: [APIFieldProblem]?
    public let requiredScope: String?
    public let impact: APIImpactSummary?
    public let impactToken: String?

    public init(
        status: Int,
        code: String,
        title: String,
        detail: String,
        requestID: String,
        errors: [APIFieldProblem]? = nil,
        requiredScope: String? = nil,
        impact: APIImpactSummary? = nil,
        impactToken: String? = nil
    ) {
        type = "https://neoanki.example/problems/\(code.replacingOccurrences(of: "_", with: "-"))"
        self.title = title
        self.status = status
        self.code = code
        self.detail = detail
        requestId = requestID
        self.errors = errors
        self.requiredScope = requiredScope
        self.impact = impact
        self.impactToken = impactToken
    }
}

enum APIServiceError: Error, Sendable {
    case problem(
        status: Int,
        code: String,
        title: String,
        detail: String,
        errors: [APIFieldProblem]? = nil,
        requiredScope: String? = nil,
        headers: [String: String] = [:],
        impact: APIImpactSummary? = nil,
        impactToken: String? = nil
    )

    static func validation(
        _ detail: String,
        pointer: String? = nil,
        fieldCode: String = "invalid"
    ) -> APIServiceError {
        .problem(
            status: 422,
            code: "validation_failed",
            title: "Request validation failed",
            detail: detail,
            errors: pointer.map { [APIFieldProblem(pointer: $0, code: fieldCode)] }
        )
    }

    static func notFound(_ detail: String) -> APIServiceError {
        .problem(
            status: 404,
            code: "resource_not_found",
            title: "Resource not found",
            detail: detail
        )
    }

    static func from(_ error: Error) -> APIServiceError {
        if let service = error as? APIServiceError { return service }
        if error is ImportError || error is AuthoredDeckError
            || error is AuthoredDeckDiagnostic || error is PortableDeckError
        {
            return validation(error.localizedDescription)
        }
        if let media = error as? MediaError {
            switch media {
            case .fileTooLarge:
                return .problem(
                    status: 413,
                    code: "payload_too_large",
                    title: "Payload too large",
                    detail: "The media upload exceeds its byte limit."
                )
            default:
                return validation("The media bytes or declared media kind are invalid.")
            }
        }
        guard let database = error as? DatabaseError else {
            return .problem(
                status: 500,
                code: "internal_error",
                title: "Internal server error",
                detail: "The request could not be completed."
            )
        }
        switch database {
        case .deckNotFound, .itemTypeNotFound, .itemNotFound, .cardNotFound, .reviewLogNotFound,
             .templateNotFound, .studySessionNotFound:
            return notFound("The requested resource does not exist.")
        case .idempotencyConflict:
            return .problem(
                status: 409,
                code: "idempotency_conflict",
                title: "Idempotency conflict",
                detail: "The idempotency key was already used for different input."
            )
        case .requiredFieldEmpty, .invalidItemType, .invalidItem, .invalidDeck,
             .invalidMediaAsset:
            return validation(database.localizedDescription)
        case let .resourceInUse(detail):
            return .problem(
                status: 409,
                code: "resource_in_use",
                title: "Resource in use",
                detail: detail
            )
        case let .studyConflict(detail):
            return .problem(
                status: 409,
                code: "study_conflict",
                title: "Study conflict",
                detail: detail
            )
        default:
            return .problem(
                status: 500,
                code: "internal_error",
                title: "Internal server error",
                detail: "The request could not be completed."
            )
        }
    }
}
