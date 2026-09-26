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
    ],
    targets: [
        .target(name: "MarkdownStickiesCore"),
        .testTarget(
            name: "MarkdownStickiesCoreTests",
            dependencies: ["MarkdownStickiesCore"]
        ),
    ]
)
