// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownStickiesCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "MarkdownStickiesCore", targets: ["MarkdownStickiesCore"]),
        .executable(name: "SyncMergeHarness", targets: ["SyncMergeHarness"]),
    ],
    targets: [
        .target(name: "MarkdownStickiesCore"),
        .executableTarget(
            name: "SyncMergeHarness",
            dependencies: ["MarkdownStickiesCore"]
        ),
        .testTarget(
            name: "MarkdownStickiesCoreTests",
            dependencies: ["MarkdownStickiesCore"]
        ),
    ]
)
