// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MixCut",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .target(
            name: "MixCutCore",
            dependencies: [],
            path: "Sources/MixCutCore"
        ),
        .executableTarget(
            name: "MixCut",
            dependencies: ["MixCutCore"],
            path: "MixCut",
            resources: [.copy("Resources/Prompts")]
        ),
        .testTarget(
            name: "MixCutCoreTests",
            dependencies: ["MixCutCore"],
            path: "Tests/MixCutCoreTests"
        ),
    ]
)
