// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeoAnki2",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "NeoAnki2", targets: ["NeoAnki2"]),
        .library(name: "NeoAnkiFeatures", targets: ["NeoAnkiFeatures"]),
        .library(name: "NeoAnkiMobile", targets: ["NeoAnkiMobile"]),
        .library(name: "NeoAnkiAPI", targets: ["NeoAnkiAPI"]),
        .library(name: "NeoAnkiApplication", targets: ["NeoAnkiApplication"]),
        .library(name: "NeoAnkiSharedUI", targets: ["NeoAnkiSharedUI"]),
        .library(name: "NeoAnkiCloudSync", targets: ["NeoAnkiCloudSync"]),
        .library(name: "NeoAnkiDeckBuilderKit", targets: ["NeoAnkiDeckBuilderKit"]),
        .library(name: "NeoAnkiDeckBuilderCore", targets: ["NeoAnkiDeckBuilderCore"]),
        .library(name: "NeoAnkiVocabularyKit", targets: ["NeoAnkiVocabularyKit"]),
        .library(name: "NeoAnkiVocabularyCLI", targets: ["NeoAnkiVocabularyCLI"]),
        .library(name: "VocabularyDeckBuilder", targets: ["VocabularyDeckBuilder"]),
        .executable(name: "neoanki-vocab", targets: ["neoanki-vocab"]),
        .executable(
            name: "neoanki-api-reference",
            targets: ["NeoAnkiAPIReferenceGenerator"]
        ),
        .executable(
            name: "neoanki-template-migrator",
            targets: ["NeoAnkiTemplateMigrator"]
        ),
        .library(
            name: "NeoAnkiTemplateMigration",
            targets: ["NeoAnkiTemplateMigration"]
        ),
        .library(name: "PoemDeckBuilder", targets: ["PoemDeckBuilder"]),
    ],
    dependencies: [
        .package(path: "NeoAnkiCore"),
    ],
    targets: [
        .target(
            name: "NeoAnkiFeatures",
            dependencies: [
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                "NeoAnkiApplication",
            ],
            path: "Sources/NeoAnkiFeatures"
        ),
        .target(
            name: "NeoAnkiMobile",
            dependencies: [
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                "NeoAnkiApplication",
                "NeoAnkiFeatures",
                "NeoAnkiSharedUI",
                "NeoAnkiDeckBuilderKit",
                "NeoAnkiVocabularyKit",
                "PoemDeckBuilder",
                "VocabularyDeckBuilder",
            ],
            path: "Sources/NeoAnkiIOS"
        ),
        .executableTarget(
            name: "NeoAnki2",
            dependencies: [
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                "NeoAnkiApplication",
                "NeoAnkiFeatures",
                "NeoAnkiSharedUI",
                "NeoAnkiCloudSync",
                "NeoAnkiAPI",
                "NeoAnkiDeckBuilderKit",
                "NeoAnkiVocabularyKit",
                "PoemDeckBuilder",
                "VocabularyDeckBuilder",
            ],
            path: "Sources/NeoAnki2"
        ),
        .target(
            name: "NeoAnkiApplication",
            dependencies: [
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/NeoAnkiApplication"
        ),
        .target(
            name: "NeoAnkiSharedUI",
            dependencies: [
                "NeoAnkiApplication",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/NeoAnkiSharedUI"
        ),
        .target(
            name: "NeoAnkiCloudSync",
            dependencies: [
                "NeoAnkiApplication",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/NeoAnkiCloudSync",
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "NeoAnkiDeckBuilderKit",
            dependencies: ["NeoAnkiDeckBuilderCore"],
            path: "Sources/NeoAnkiDeckBuilderKit"
        ),
        .target(
            name: "NeoAnkiDeckBuilderCore",
            path: "Sources/NeoAnkiDeckBuilderCore"
        ),
        .target(
            name: "NeoAnkiAPI",
            dependencies: [
                "NeoAnkiApplication",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                "NeoAnkiVocabularyKit",
            ],
            path: "Sources/NeoAnkiAPI",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "NeoAnkiVocabularyKit",
            path: "Sources/NeoAnkiVocabularyKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "NeoAnkiVocabularyCLI",
            dependencies: ["NeoAnkiVocabularyKit"],
            path: "Sources/NeoAnkiVocabularyCLI"
        ),
        .executableTarget(
            name: "neoanki-vocab",
            dependencies: ["NeoAnkiVocabularyCLI"],
            path: "Sources/neoanki-vocab"
        ),
        .executableTarget(
            name: "NeoAnkiAPIReferenceGenerator",
            dependencies: ["NeoAnkiAPI"],
            path: "Tools/NeoAnkiAPIReferenceGenerator"
        ),
        .target(
            name: "NeoAnkiTemplateMigration",
            dependencies: [.product(name: "NeoAnkiCore", package: "NeoAnkiCore")],
            path: "Sources/NeoAnkiTemplateMigration",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "NeoAnkiTemplateMigrator",
            dependencies: ["NeoAnkiTemplateMigration"],
            path: "Tools/NeoAnkiTemplateMigrator"
        ),
        .target(
            name: "PoemDeckBuilder",
            dependencies: [
                "NeoAnkiDeckBuilderKit",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/PoemDeckBuilder"
        ),
        .target(
            name: "VocabularyDeckBuilder",
            dependencies: [
                "NeoAnkiVocabularyKit",
                "NeoAnkiDeckBuilderKit",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Sources/VocabularyDeckBuilder"
        ),
        .testTarget(
            name: "NeoAnkiFeaturesTests",
            dependencies: [
                "NeoAnkiFeatures",
                "NeoAnkiApplication",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                .product(name: "NeoAnkiTestSupport", package: "NeoAnkiCore"),
            ],
            path: "Tests/NeoAnkiFeaturesTests"
        ),
        .testTarget(
            name: "NeoAnkiApplicationTests",
            dependencies: [
                "NeoAnkiApplication",
                "NeoAnkiCloudSync",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                .product(name: "NeoAnkiTestSupport", package: "NeoAnkiCore"),
            ],
            path: "Tests/NeoAnkiApplicationTests"
        ),
        .testTarget(
            name: "NeoAnki2Tests",
            dependencies: [
                "NeoAnki2",
                "NeoAnkiApplication",
                "NeoAnkiSharedUI",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                .product(name: "NeoAnkiTestSupport", package: "NeoAnkiCore"),
                "NeoAnkiDeckBuilderKit",
                "NeoAnkiVocabularyKit",
                "PoemDeckBuilder",
                "VocabularyDeckBuilder",
                "NeoAnkiTemplateMigration",
            ],
            path: "Tests/NeoAnki2Tests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "NeoAnkiAPITests",
            dependencies: [
                "NeoAnkiAPI",
                "NeoAnkiApplication",
                "NeoAnkiVocabularyKit",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
                .product(name: "NeoAnkiTestSupport", package: "NeoAnkiCore"),
            ],
            path: "Tests/NeoAnkiAPITests"
        ),
        .testTarget(
            name: "PoemDeckBuilderTests",
            dependencies: [
                "PoemDeckBuilder",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Tests/PoemDeckBuilderTests"
        ),
        .testTarget(
            name: "NeoAnkiVocabularyKitTests",
            dependencies: ["NeoAnkiVocabularyKit"],
            path: "Tests/NeoAnkiVocabularyKitTests"
        ),
        .testTarget(
            name: "NeoAnkiVocabularyCLITests",
            dependencies: ["NeoAnkiVocabularyCLI", "NeoAnkiVocabularyKit"],
            path: "Tests/NeoAnkiVocabularyCLITests"
        ),
        .testTarget(
            name: "VocabularyDeckBuilderTests",
            dependencies: [
                "VocabularyDeckBuilder",
                "NeoAnkiVocabularyKit",
                "NeoAnkiDeckBuilderKit",
                .product(name: "NeoAnkiCore", package: "NeoAnkiCore"),
            ],
            path: "Tests/VocabularyDeckBuilderTests"
        ),
    ]
)
