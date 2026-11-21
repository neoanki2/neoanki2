import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
@Test func finderAuthoredDeckRequestsWaitForAWindowAndDeduplicatePendingOpens() {
    let requests = AuthoredDeckOpenRequests()
    let first = URL(fileURLWithPath: "/tmp/First.NEOANKI", isDirectory: true)
    let second = URL(fileURLWithPath: "/tmp/Second.neoanki", isDirectory: true)
    let portable = URL(fileURLWithPath: "/tmp/Skip.neodeck")
    let remote = URL(string: "https://example.com/Skip.neoanki")!

    requests.enqueue([portable, remote, first, first, second])
    #expect(requests.next == first)
    #expect(requests.claimNext() == first)
    requests.enqueue([first, second])
    #expect(requests.claimNext() == nil)

    requests.finish(first)
    #expect(requests.claimNext() == second)
    requests.finish(second)
    #expect(requests.next == nil)
}

@MainActor
@Test func finderAuthoredDeckRequestCanReturnToTheQueueWhenItsWindowCloses() {
    let requests = AuthoredDeckOpenRequests()
    let source = URL(fileURLWithPath: "/tmp/Examples.neoanki", isDirectory: true)

    requests.enqueue([source])
    #expect(requests.claimNext() == source)
    requests.release(source)
    #expect(requests.claimNext() == source)
    requests.finish(source)
    #expect(requests.next == nil)
}

@Test func portableDeckImportSelectionAcceptsNeoankiDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-import-selection-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("Example.neoanki", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(PortableDeckImportSelection.isValid(bundle))
}

@Test func portableDeckImportSelectionAcceptsNeodeckFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-import-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("Example.neodeck")
    try Data("deck".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(PortableDeckImportSelection.isValid(file))
}

@Test func portableDeckImportSelectionRejectsPlainDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-import-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(PortableDeckImportSelection.isValid(root) == false)
}

@Test func portableDeckImportSelectionRejectsNeoankiFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-import-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("Example.neoanki")
    try Data("deck".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(PortableDeckImportSelection.isValid(file) == false)
}
