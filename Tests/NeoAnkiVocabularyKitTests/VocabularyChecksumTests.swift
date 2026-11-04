import Darwin
import Foundation
import Testing
@testable import NeoAnkiVocabularyKit

private func checksumResidentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    #expect(status == KERN_SUCCESS)
    return info.resident_size
}

@Test func vocabularyChecksumReleasesReadBuffersBeforeReturning() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-memory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 128 * 1_024 * 1_024)
    try handle.close()
    // A task can keep its surrounding autorelease pool alive across multiple
    // pack validations. The old loop retained 384 MiB inside this scope.
    try autoreleasepool {
        let before = try checksumResidentBytes()
        var digest: String?
        for _ in 0..<3 {
            let next = try SHA256File.hexDigest(of: file)
            if let digest { #expect(next == digest) }
            digest = next
        }
        let after = try checksumResidentBytes()
        #expect(after < before + 96 * 1_024 * 1_024)
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
