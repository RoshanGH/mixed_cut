// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MixCut",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MixCut",
            dependencies: [],
            path: "MixCut",
            resources: [
                .copy("Resources/Prompts"),
            ]
        ),
    ]
)
