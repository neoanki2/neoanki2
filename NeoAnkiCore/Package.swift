// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeoAnkiCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "NeoAnkiCore", targets: ["NeoAnkiCore"]),
        .library(name: "NeoAnkiTestSupport", targets: ["NeoAnkiTestSupport"]),
        .executable(name: "neoanki-deck", targets: ["NeoAnkiDeckCLI"]),
    ],
    targets: [
        .target(
            name: "NeoAnkiCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "NeoAnkiTestSupport",
            dependencies: ["NeoAnkiCore"]
        ),
        .executableTarget(
            name: "NeoAnkiDeckCLI",
            dependencies: ["NeoAnkiCore"]
        ),
        .testTarget(name: "NeoAnkiCoreTests", dependencies: ["NeoAnkiCore"]),
        .testTarget(
            name: "NeoAnkiFlowTests",
            dependencies: ["NeoAnkiCore", "NeoAnkiTestSupport"]
        ),
    ]
)
