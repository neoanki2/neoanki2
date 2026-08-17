import Foundation
import NeoAnkiTemplateMigration

enum NeoAnkiTemplateMigratorCLI {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, ["plan", "apply", "verify"].contains(command) else {
                throw CLIError.usage
            }
            let databaseURL = try databaseURL(arguments: Array(arguments.dropFirst()))
            switch command {
            case "plan": printReport(try TemplateDefinitionMigrator.plan(databaseURL: databaseURL))
            case "apply": printReport(try TemplateDefinitionMigrator.apply(databaseURL: databaseURL))
            case "verify": printVerification(try TemplateDefinitionMigrator.verify(databaseURL: databaseURL))
            default: throw CLIError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func databaseURL(arguments: [String]) throws -> URL {
        if arguments.count == 2, arguments[0] == "--database" {
            return URL(fileURLWithPath: arguments[1]).standardizedFileURL
        }
        if arguments.count == 1 {
            return URL(fileURLWithPath: arguments[0]).standardizedFileURL
        }
        throw CLIError.usage
    }

    private static func printReport(_ report: TemplateMigrationReport) {
        print(report.alreadyMigrated ? "Template definitions already use format 2." : "Migration plan is valid.")
        print("Item types: \(report.itemTypeCount); templates: \(report.templateCount)")
        for mapping in report.mappings {
            print("- \(mapping.itemTypeID.uuidString.lowercased()) / \(mapping.templateID.uuidString.lowercased()): \(mapping.layout.rawValue); questions=\(mapping.questionCount), answers=\(mapping.answerCount), supporting=\(mapping.supportingCount), media=\(mapping.mediaCount)")
        }
    }

    private static func printVerification(_ value: TemplateMigrationVerification) {
        print("Template definition format 2 verified; SQLite integrity: ok")
        print("itemTypes=\(value.itemTypeCount) items=\(value.itemCount) cards=\(value.cardCount) reviews=\(value.reviewLogCount) responses=\(value.responseCount) media=\(value.mediaCount) quarantines=\(value.quarantineCount)")
    }
}

NeoAnkiTemplateMigratorCLI.main()

private enum CLIError: Error, LocalizedError {
    case usage
    var errorDescription: String? {
        "Usage: neoanki-template-migrator <plan|apply|verify> --database <path>"
    }
}
