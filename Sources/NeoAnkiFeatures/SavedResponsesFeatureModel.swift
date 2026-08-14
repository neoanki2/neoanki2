import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

public enum SavedResponsesLoadState: Sendable, Equatable {
    case loading
    case ready
    case failed(UserFacingError)
}

/// Shared state for the persistent-response library. Recording and playback
/// remain platform-owned because AVFoundation lifecycle differs by platform.
@MainActor @Observable
public final class SavedResponsesFeatureModel {
    public private(set) var responses: [StudyResponse] = []
    public private(set) var loadState: SavedResponsesLoadState = .loading
    public private(set) var deletingIDs: Set<UUID> = []

    private let library: any LibraryStudyResponses
    private let errorMapper: any UserFacingErrorMapping

    public init(
        library: any LibraryStudyResponses,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper()
    ) {
        self.library = library
        self.errorMapper = errorMapper
    }

    public func load() async {
        loadState = .loading
        do {
            responses = try await library.studyResponses(matching: StudyResponseQuery(limit: 200))
            loadState = .ready
        } catch {
            loadState = .failed(errorMapper.map(error))
        }
    }

    public func reload() async {
        do {
            responses = try await library.studyResponses(matching: StudyResponseQuery(limit: 200))
            loadState = .ready
        } catch {
            loadState = .failed(errorMapper.map(error))
        }
    }

    public func audioData(for response: StudyResponse) async throws -> Data {
        (try await library.studyResponseMediaBytes(id: response.id)).2
    }

    public func delete(_ response: StudyResponse) async {
        guard deletingIDs.insert(response.id).inserted else { return }
        defer { deletingIDs.remove(response.id) }
        do {
            _ = try await library.deleteStudyResponse(id: response.id)
            responses.removeAll { $0.id == response.id }
        } catch {
            loadState = .failed(errorMapper.map(error))
        }
    }
}
