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
    ],
    targets: [
        .target(name: "NeoAnkiCore"),
        .testTarget(name: "NeoAnkiCoreTests", dependencies: ["NeoAnkiCore"]),
    ]
)
