// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lint", targets: ["Lint"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "LintCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/LintCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .executableTarget(
            name: "Lint",
            dependencies: [
                "LintCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Lint",
            linkerSettings: [
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "LintCoreTests",
            dependencies: ["LintCore"],
            path: "Tests/LintCoreTests",
            // Read from the repository by path (`WritingEvalFixtures.load()`), not bundled.
            exclude: ["Eval/WritingEvalFixtures.json"]
        )
    ]
)
