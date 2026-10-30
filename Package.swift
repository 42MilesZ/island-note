// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IslandNote",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/MarkdownEngine")
    ],
    targets: [
        .executableTarget(
            name: "IslandNote",
            dependencies: [.product(name: "MarkdownEngine", package: "MarkdownEngine")],
            path: "Sources/IslandNote",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "IslandNoteTests", dependencies: ["IslandNote"])
    ]
)
