import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

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
