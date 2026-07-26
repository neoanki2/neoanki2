import Darwin
import Foundation
import NeoAnkiCore

@main
struct NeoAnkiDeckCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "validate" else {
            writeError("Usage: neoanki-deck validate <path.neoanki>\n")
            exit(EXIT_FAILURE)
        }

        let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let diagnostics = AuthoredDeck.validate(at: source)
        guard diagnostics.isEmpty else {
            for diagnostic in diagnostics {
                writeError("\(source.path)/\(diagnostic.localizedDescription)\n")
            }
            exit(EXIT_FAILURE)
        }
        print("Valid authored deck: \(source.path)")
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
