// Compile with the SwiftSyntax/SwiftParser libraries bundled in Xcode; see README.md.
import Foundation
import SwiftSyntax
import SwiftParser

struct Declaration: Codable {
    var id: String; var file: String; var kind: String; var name: String
    var parent: String?; var line: Int; var endLine: Int; var signature: String
    var inherited: [String]; var documented: Bool; var modifiers: String
}
struct Reference: Codable {
    var source: String; var name: String; var kind: String; var line: Int; var expression: String
}
struct SourceFile: Codable { var path: String; var lines: Int; var imports: [String]; var parseErrors: Bool }
struct Inventory: Codable { var files: [SourceFile]; var declarations: [Declaration]; var references: [Reference] }
final class Scanner: SyntaxAnyVisitor {
    let file: String; let locations: SourceLocationConverter
    var declarations: [Declaration] = []; var references: [Reference] = []; var imports: [String] = []
    var stack: [(SyntaxIdentifier, String)] = []
    init(file: String, tree: SourceFileSyntax) {
        self.file = file; self.locations = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }
    func add(_ node: Syntax, _ kind: String, _ name: String, _ signature: String,
             _ inherited: [String] = [], _ modifiers: String = "") {
        let line = locations.location(for: node.positionAfterSkippingLeadingTrivia).line
        let id = "\(file):\(node.positionAfterSkippingLeadingTrivia.utf8Offset):\(name)"
        declarations.append(.init(id: id, file: file, kind: kind, name: name, parent: stack.last?.1,
            line: line, endLine: locations.location(for: node.endPositionBeforeTrailingTrivia).line,
            signature: signature.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
            inherited: inherited, documented: node.leadingTrivia.description.contains("///") || node.leadingTrivia.description.contains("/**"), modifiers: modifiers))
        stack.append((node.id, id))
    }
    func header(_ node: Syntax, until position: AbsolutePosition?) -> String {
        let s = node.trimmedDescription
        guard let position else { return s }
        let count = position.utf8Offset - node.positionAfterSkippingLeadingTrivia.utf8Offset
        return String(decoding: Array(s.utf8.prefix(max(0, count))), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let n = node.as(ClassDeclSyntax.self) { add(node,"class",n.name.text,header(node,until:n.memberBlock.leftBrace.positionAfterSkippingLeadingTrivia),n.inheritanceClause?.inheritedTypes.map{$0.type.trimmedDescription} ?? [], n.modifiers.trimmedDescription) }
        else if let n = node.as(StructDeclSyntax.self) { add(node,"struct",n.name.text,header(node,until:n.memberBlock.leftBrace.positionAfterSkippingLeadingTrivia),n.inheritanceClause?.inheritedTypes.map{$0.type.trimmedDescription} ?? [], n.modifiers.trimmedDescription) }
        else if let n = node.as(EnumDeclSyntax.self) { add(node,"enum",n.name.text,header(node,until:n.memberBlock.leftBrace.positionAfterSkippingLeadingTrivia),n.inheritanceClause?.inheritedTypes.map{$0.type.trimmedDescription} ?? [], n.modifiers.trimmedDescription) }
        else if let n = node.as(ActorDeclSyntax.self) { add(node,"actor",n.name.text,header(node,until:n.memberBlock.leftBrace.positionAfterSkippingLeadingTrivia),n.inheritanceClause?.inheritedTypes.map{$0.type.trimmedDescription} ?? [], n.modifiers.trimmedDescription) }
        else if let n = node.as(ProtocolDeclSyntax.self) { add(node,"protocol",n.name.text,header(node,until:n.memberBlock.leftBrace.positionAfterSkippingLeadingTrivia),n.inheritanceClause?.inheritedTypes.map{$0.type.trimmedDescription} ?? [], n.modifiers.trimmedDescription) }
        else if let n = node.as(ExtensionDeclSyntax.self) { add(node,"extension",n.extendedType.trimmedDescription,header(node,until:n.memberBlock.leftBrace.positionAfterSkippingLeadingTrivia),n.inheritanceClause?.inheritedTypes.map{$0.type.trimmedDescription} ?? [], n.modifiers.trimmedDescription) }
        else if let n = node.as(FunctionDeclSyntax.self) { add(node,"function",n.name.text,header(node,until:n.body?.leftBrace.positionAfterSkippingLeadingTrivia),[],n.modifiers.trimmedDescription) }
        else if let n = node.as(InitializerDeclSyntax.self) { add(node,"initializer","init",header(node,until:n.body?.leftBrace.positionAfterSkippingLeadingTrivia),[],n.modifiers.trimmedDescription) }
        else if let n = node.as(DeinitializerDeclSyntax.self) { add(node,"deinitializer","deinit",header(node,until:n.body?.leftBrace.positionAfterSkippingLeadingTrivia)) }
        else if let n = node.as(SubscriptDeclSyntax.self) { add(node,"subscript","subscript",header(node,until:n.accessorBlock?.leftBrace.positionAfterSkippingLeadingTrivia),[],n.modifiers.trimmedDescription) }
        else if let n = node.as(TypeAliasDeclSyntax.self) { add(node,"typealias",n.name.text,n.trimmedDescription,[],n.modifiers.trimmedDescription) }
        else if let n = node.as(AssociatedTypeDeclSyntax.self) { add(node,"associatedtype",n.name.text,n.trimmedDescription) }
        else if let n = node.as(EnumCaseElementSyntax.self) { add(node,"case",n.name.text,n.trimmedDescription) }
        else if let n = node.as(VariableDeclSyntax.self) {
            // Bindings include stored/computed properties and local bindings. Keep initializers out of signatures.
            let sig = n.bindings.map { $0.pattern.trimmedDescription + ($0.typeAnnotation?.trimmedDescription ?? "") }.joined(separator:", ")
            add(node, "variable", n.bindings.map{$0.pattern.trimmedDescription}.joined(separator:", "), n.modifiers.trimmedDescription + " " + n.bindingSpecifier.text + " " + sig, [], n.modifiers.trimmedDescription)
        }
        if let n = node.as(ImportDeclSyntax.self) { imports.append(n.path.trimmedDescription) }
        if let n = node.as(IdentifierTypeSyntax.self) { ref(node,n.name.text,"type",n.trimmedDescription) }
        if let n = node.as(MemberTypeSyntax.self) { ref(node,n.name.text,"memberType",n.trimmedDescription) }
        if let n = node.as(DeclReferenceExprSyntax.self) { ref(node,n.baseName.text,"expression",n.trimmedDescription) }
        if let n = node.as(FunctionCallExprSyntax.self) {
            let name = n.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text ?? n.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? "<closure>"
            ref(node,name,"call",String(n.calledExpression.trimmedDescription.prefix(250)))
        }
        return .visitChildren
    }
    func ref(_ node: Syntax, _ name: String, _ kind: String, _ expression: String) {
        references.append(.init(source:stack.last?.1 ?? file,name:name,kind:kind,
            line:locations.location(for:node.positionAfterSkippingLeadingTrivia).line,expression:expression))
    }
    override func visitAnyPost(_ node: Syntax) { if stack.last?.0 == node.id { stack.removeLast() } }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let list = try String(contentsOfFile: CommandLine.arguments[2],encoding:.utf8).split(separator:"\n").map(String.init)
var inventory = Inventory(files:[],declarations:[],references:[])
for path in list where path.hasSuffix(".swift") {
    let source = try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8)
    let tree = Parser.parse(source:source)
    let scanner = Scanner(file:path,tree:tree); scanner.walk(tree)
    inventory.files.append(.init(path:path,lines:source.split(separator:"\n",omittingEmptySubsequences:false).count,imports:Array(Set(scanner.imports)).sorted(),parseErrors:tree.hasError))
    inventory.declarations += scanner.declarations; inventory.references += scanner.references
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
try encoder.encode(inventory).write(to:URL(fileURLWithPath:CommandLine.arguments[3]))
print("Parsed \(inventory.files.count) Swift files, \(inventory.declarations.count) declarations, \(inventory.references.count) reference occurrences")
