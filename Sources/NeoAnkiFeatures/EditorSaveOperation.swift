import NeoAnkiApplication
import Observation

/// The same save boundary for both native editors. The supplied operation may
/// prepare and commit a write; optional refresh and device effects belong after
/// that boundary. A saved operation cannot submit again while dismissal runs.
@MainActor @Observable
public final class EditorSaveOperation {
    public enum Phase: Equatable, Sendable {
        case editing
        case saving
        case saved
        case failed(UserFacingError)
    }

    public private(set) var phase: Phase = .editing
    private let errorMapper: any UserFacingErrorMapping

    public init(errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper()) {
        self.errorMapper = errorMapper
    }

    public var isSaving: Bool { phase == .saving }
    public var canDismiss: Bool { !isSaving }
    public var error: UserFacingError? {
        if case let .failed(error) = phase { return error }
        return nil
    }

    public func beginEditing() {
        guard !isSaving else { return }
        phase = .editing
    }

    public func perform<Value: Sendable>(
        _ commit: @MainActor () async throws -> Value
    ) async -> Value? {
        guard phase != .saving, phase != .saved else { return nil }
        phase = .saving
        do {
            let result = try await commit()
            phase = .saved
            return result
        } catch {
            // Errors already prepared for presentation must retain their
            // message/recovery, rather than becoming a description of a struct.
            phase = .failed((error as? UserFacingError) ?? errorMapper.map(error))
            return nil
        }
    }
}
