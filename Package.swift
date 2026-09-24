// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IslandNote",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nodes-app/swift-markdown-engine.git", exact: "0.13.0")
    ],
    targets: [
        .executableTarget(
            name: "IslandNote",
            dependencies: [.product(name: "MarkdownEngine", package: "swift-markdown-engine")],
            path: "Sources/IslandNote"
        )
    ]
)
