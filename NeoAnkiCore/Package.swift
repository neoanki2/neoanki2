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
        .executable(name: "neoanki-fsrs-benchmark", targets: ["NeoAnkiFSRSBenchmark"]),
    ],
    targets: [
        .target(name: "NeoAnkiFSRS", exclude: ["NOTICE.md"]),
        .target(
            name: "NeoAnkiCore",
            dependencies: ["NeoAnkiFSRS"],
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
        .executableTarget(
            name: "NeoAnkiFSRSBenchmark",
            dependencies: ["NeoAnkiFSRS"]
        ),
        .testTarget(name: "NeoAnkiCoreTests", dependencies: ["NeoAnkiCore", "NeoAnkiTestSupport"]),
        .testTarget(
            name: "NeoAnkiFSRSTests",
            dependencies: ["NeoAnkiFSRS"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "NeoAnkiFlowTests",
            dependencies: ["NeoAnkiCore", "NeoAnkiTestSupport"]
        ),
    ]
)
