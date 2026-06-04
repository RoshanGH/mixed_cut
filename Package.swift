// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MixCut",
    platforms: [.macOS(.v14)],
    dependencies: [],
    // 注意：App 本体由 MixCut.xcodeproj 用 xcodebuild 构建（SwiftData 宏需 Xcode），
    // 不再用 Package.swift 的 executableTarget 构建 App。Package.swift 仅承载可独立
    // `swift test` 的纯逻辑库 MixCutCore。App target 通过 xcodeproj 直接编译
    // Sources/MixCutCore/*.swift（同模块，无需 import）。
    targets: [
        .target(
            name: "MixCutCore",
            dependencies: [],
            path: "Sources/MixCutCore"
        ),
        .testTarget(
            name: "MixCutCoreTests",
            dependencies: ["MixCutCore"],
            path: "Tests/MixCutCoreTests"
        ),
    ]
)
