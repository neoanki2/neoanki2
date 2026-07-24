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
        .testTarget(name: "NeoAnkiCoreTests", dependencies: ["NeoAnkiCore"]),
        .testTarget(
            name: "NeoAnkiFlowTests",
            dependencies: ["NeoAnkiCore", "NeoAnkiTestSupport"]
        ),
    ]
)
