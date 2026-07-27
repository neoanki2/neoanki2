import Darwin
import Foundation
import NeoAnkiCore

@main
struct NeoAnkiDeckCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            writeError("Usage: neoanki-deck validate <path.neoanki>\n")
            writeError("       neoanki-deck generate-ui-fixtures <output-directory>\n")
            exit(EXIT_FAILURE)
        }

        switch command {
        case "validate":
            guard arguments.count == 2 else {
                writeError("Usage: neoanki-deck validate <path.neoanki>\n")
                exit(EXIT_FAILURE)
            }
            validateAuthoredDeck(at: arguments[1])
        case "generate-ui-fixtures":
            guard arguments.count == 2 else {
                writeError("Usage: neoanki-deck generate-ui-fixtures <output-directory>\n")
                exit(EXIT_FAILURE)
            }
            do {
                try await generateUIFixtures(into: arguments[1])
            } catch {
                writeError("\(error.localizedDescription)\n")
                exit(EXIT_FAILURE)
            }
        default:
            writeError("Unknown command: \(command)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func validateAuthoredDeck(at path: String) {
        let source = URL(fileURLWithPath: path, isDirectory: true)
        let diagnostics = AuthoredDeck.validate(at: source)
        guard diagnostics.isEmpty else {
            for diagnostic in diagnostics {
                writeError("\(source.path)/\(diagnostic.localizedDescription)\n")
            }
            exit(EXIT_FAILURE)
        }
        print("Valid authored deck: \(source.path)")
    }

    private static func generateUIFixtures(into outputPath: String) async throws {
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-ui-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let source = try await makeStore(in: work.appendingPathComponent("source", isDirectory: true))
        let deck = try await source.createDeck(Deck(name: "Portable Import"))
        _ = try await source.createItem(
            Item(
                itemTypeID: BuiltInItemTypes.basicID,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Imported Front")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Imported Back")),
                ],
                deckID: deck.id
            )
        )
        let minimalURL = output.appendingPathComponent("minimal.neodeck")
        try await PortableDeck.export(deckID: deck.id, from: source, to: minimalURL)

        let conflictSource = try await makeStore(in: work.appendingPathComponent("conflict-source", isDirectory: true))
        var customType = try ItemTypeBuilder.makeItemType(
            name: "Portable Custom",
            fields: [
                FieldDef(name: "Prompt", type: .text, isRequired: true),
                FieldDef(name: "Answer", type: .text, isRequired: true),
            ]
        )
        _ = try await conflictSource.createItemType(customType)
        let conflictDeck = try await conflictSource.createDeck(Deck(name: "Conflict Deck"))
        _ = try await conflictSource.createItem(
            Item(
                itemTypeID: customType.id,
                fields: [
                    FieldValue(fieldID: customType.fields[0].id, value: .text("Conflict Q")),
                    FieldValue(fieldID: customType.fields[1].id, value: .text("Conflict A")),
                ],
                deckID: conflictDeck.id
            )
        )
        let firstURL = work.appendingPathComponent("conflict-first.neodeck")
        try await PortableDeck.export(deckID: conflictDeck.id, from: conflictSource, to: firstURL)

        customType.name = "Portable Custom Revised"
        _ = try await conflictSource.updateItemType(customType)
        let conflictURL = output.appendingPathComponent("conflict.neodeck")
        try await PortableDeck.export(deckID: conflictDeck.id, from: conflictSource, to: conflictURL)

        let firstOutput = output.appendingPathComponent("conflict-first.neodeck")
        try FileManager.default.copyItem(at: firstURL, to: firstOutput)

        let basicJSON = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "Fixture Question", "Back": "Fixture Answer" }
          ]
        }
        """
        try basicJSON.write(
            to: output.appendingPathComponent("basic-item-type.json"),
            atomically: true,
            encoding: .utf8
        )

        let mediaJSON = """
        {
          "itemType": "Basic",
          "rows": [
            { "Front": "Media Question", "Back": "Media Answer" }
          ]
        }
        """
        try mediaJSON.write(
            to: output.appendingPathComponent("import-with-media.json"),
            atomically: true,
            encoding: .utf8
        )

        print("Generated UI fixtures in \(output.path)")
    }

    private static func makeStore(in directory: URL) async throws -> ItemStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = try MediaStore(rootDirectory: directory)
        let store = try ItemStore(
            databaseURL: directory.appendingPathComponent("library.sqlite"),
            mediaStore: media
        )
        try await store.bootstrap()
        return store
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
