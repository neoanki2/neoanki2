import Foundation
import Testing

@testable import NeoAnki2

private struct AppDocumentationClaims: Decodable {
    struct AppData: Decodable {
        let libraryDirectory: String
    }

    struct Compatibility: Decodable {
        let minimumMacOS: Int
        let swiftToolsVersion: String
    }

    let appData: AppData
    let compatibility: Compatibility
}

private func appDocumentationClaims() throws -> AppDocumentationClaims {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try JSONDecoder().decode(
        AppDocumentationClaims.self,
        from: Data(contentsOf: root.appendingPathComponent("docs/claims.json"))
    )
}

@Test func documentationClaimsMatchAppStorageAndPackageRequirements() throws {
    let claims = try appDocumentationClaims()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let documentedDirectory = claims.appData.libraryDirectory
        .replacingOccurrences(of: "~", with: home)
    #expect(
        AppDatabase.productionURL.deletingLastPathComponent().standardizedFileURL.path
            == URL(fileURLWithPath: documentedDirectory).standardizedFileURL.path
    )

    let package = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    #expect(package.contains("// swift-tools-version: \(claims.compatibility.swiftToolsVersion)"))
    #expect(package.contains(".macOS(.v\(claims.compatibility.minimumMacOS))"))
}
