// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeoAnki2",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NeoAnki2", targets: ["NeoAnki2"]),
    ],
    dependencies: [
        .package(path: "NeoAnkiCore"),
    ],
    targets: [
        .executableTarget(
            name: "NeoAnki2",
            dependencies: [
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/NeoAnki2"
        ),
        .testTarget(
            name: "NeoAnki2Tests",
            dependencies: [
                "NeoAnki2",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Tests/NeoAnki2Tests"
        ),
    ]
)
