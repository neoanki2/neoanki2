import Foundation
import Testing
@testable import NeoAnkiVocabularyKit

private final class ChecksumReadLifetime: NSObject {}

@Test func vocabularyChecksumReleasesReadBuffersBeforeReturning() throws {
    // Stand in for FileHandle's autoreleased bridged read storage. Unlike RSS,
    // this observes only this loop's pool and cannot count another test's memory.
    weak var previousRead: ChecksumReadLifetime?
    var reads = 0
    try autoreleasepool {
        let digest = try SHA256File.hexDigest {
            #expect(previousRead == nil, "The previous read must drain before another chunk is read.")
            let lifetime = ChecksumReadLifetime()
            previousRead = lifetime
            _ = Unmanaged.passRetained(lifetime).autorelease()
            reads += 1
            return reads <= 3 ? Data([UInt8(96 + reads)]) : Data()
        }
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(reads == 4)
        #expect(previousRead == nil, "The final read must drain before the checksum returns.")
    }
}

@Test func vocabularyChecksumMatchesKnownDigest() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-content-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    #expect(try SHA256File.hexDigest(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func vocabularyChecksumHonorsCancellation() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try SHA256File.hexDigest(of: file)
    }
    do {
        _ = try await task.value
        Issue.record("Canceled dictionary validation must stop without becoming an I/O failure.")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}
