// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotosClone",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotosClone", targets: ["PhotosClone"])
    ],
    targets: [
        // 纯算法与尺寸策略：不依赖 UI，便于单测。
        .target(
            name: "LumaCore",
            path: "Sources/LumaCore"
        ),
        // 播放内核：时间轴 / 片源计划 / AVPlayer 引擎 / ffmpeg 管道 / 字幕解析。
        // 只依赖 Foundation + AVFoundation + AVKit，不引入 SwiftUI / AppKit，
        // 缓存目录、二进制路径、日志、进度落盘全部由 App 注入。
        .target(
            name: "PlaybackCore",
            path: "Sources/PlaybackCore"
        ),
        .executableTarget(
            name: "PhotosClone",
            dependencies: ["LumaCore", "PlaybackCore"],
            path: "Sources/PhotosClone",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("NetFS"),
                .linkedFramework("Photos")
            ]
        ),
        // 命令行工具链（无 Xcode）不提供 XCTest，这里用可执行 target 做断言检查。
        .executableTarget(
            name: "LumaCoreChecks",
            dependencies: ["LumaCore", "PlaybackCore"],
            path: "Tests/LumaCoreChecks"
        )
    ]
)
