import Darwin
import NeoAnkiVocabularyCLI

@main
struct NeoAnkiVocabularyCommand {
    static func main() async {
        let code = await VocabularyCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
