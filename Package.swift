// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeoAnki2",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NeoAnki2", targets: ["NeoAnki2"]),
        .library(name: "NeoAnkiDeckBuilderKit", targets: ["NeoAnkiDeckBuilderKit"]),
        .library(name: "PoemDeckBuilder", targets: ["PoemDeckBuilder"]),
    ],
    dependencies: [
        .package(path: "NeoAnkiCore"),
    ],
    targets: [
        .executableTarget(
            name: "NeoAnki2",
            dependencies: [
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                "NeoAnkiDeckBuilderKit",
                "PoemDeckBuilder",
            ],
            path: "Sources/NeoAnki2"
        ),
        .target(
            name: "NeoAnkiDeckBuilderKit",
            path: "Sources/NeoAnkiDeckBuilderKit"
        ),
        .target(
            name: "PoemDeckBuilder",
            dependencies: [
                "NeoAnkiDeckBuilderKit",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/PoemDeckBuilder"
        ),
        .testTarget(
            name: "NeoAnki2Tests",
            dependencies: [
                "NeoAnki2",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                .product(name: "NeoAnkiTestSupport", package: "NeoAnkiCore"),
                "NeoAnkiDeckBuilderKit",
                "PoemDeckBuilder",
            ],
            path: "Tests/NeoAnki2Tests"
        ),
        .testTarget(
            name: "PoemDeckBuilderTests",
            dependencies: [
                "PoemDeckBuilder",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Tests/PoemDeckBuilderTests"
        ),
    ]
)
