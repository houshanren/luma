// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Luma", targets: ["Luma"])
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
        // 内容契约层：源、内容、播放目标、搜索、任务、错误与进度接口。
        // 纯 Foundation，不依赖 SwiftUI / AppKit；具体源实现留在 App 或 SourceKit。
        .target(
            name: "LumaContentCore",
            dependencies: ["LumaCore", "PlaybackCore"],
            path: "Sources/LumaContentCore"
        ),
        // 领域模型层：纯 Foundation 模型、查询描述、派生 DTO 与格式判定。
        // 不依赖 App / Store / Services，供 Persistence 与 App 共用。
        .target(
            name: "LumaDomain",
            dependencies: ["LumaCore", "PlaybackCore", "LumaContentCore"],
            path: "Sources/LumaDomain"
        ),
        // 持久化层：SQLite 封装、图库元数据、系统图库索引与各领域库表。
        // 只依赖 LumaDomain / LumaCore / LumaContentCore 与文件路径，不依赖 Store 或视图。
        .target(
            name: "LumaPersistence",
            dependencies: ["LumaDomain", "LumaCore", "LumaContentCore"],
            path: "Sources/LumaPersistence"
        ),
        // AI 能力层：模型后端契约、OpenAI 兼容实现、提示词上下文与工具定义。
        // 只依赖 LumaDomain；执行侧（需要 LibraryStore）仍留在 App。
        .target(
            name: "LumaAI",
            dependencies: ["LumaDomain"],
            path: "Sources/LumaAI"
        ),
        // UI 基础层：设计 token、磨砂 / 环境光等通用视图修饰器、拖放 / 键盘 / 窗口胶水。
        // 只依赖 LumaDomain，不依赖 Store 或任何功能模块。
        .target(
            name: "LumaUI",
            dependencies: ["LumaDomain"],
            path: "Sources/LumaUI"
        ),
        .executableTarget(
            name: "Luma",
            dependencies: ["LumaCore", "PlaybackCore", "LumaContentCore", "LumaDomain", "LumaPersistence", "LumaAI", "LumaUI"],
            path: "Sources/Luma",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("NetFS"),
                .linkedFramework("Photos")
            ]
        ),
        // 命令行工具链（无 Xcode）不提供 XCTest，这里用可执行 target 做断言检查。
        .target(
            name: "TestSupport",
            path: "Tests/TestSupport"
        ),
        .executableTarget(
            name: "LumaCoreChecks",
            dependencies: ["TestSupport", "LumaCore", "PlaybackCore"],
            path: "Tests/LumaCoreChecks"
        ),
        // 内容契约层检查：源激活策略、能力位、内容引用、播放目标与任务中心。
        .executableTarget(
            name: "LumaContentChecks",
            dependencies: ["TestSupport", "LumaContentCore", "PlaybackCore"],
            path: "Tests/LumaContentChecks"
        ),
        // 数据层检查：领域模型与 SQLite 持久化；验证 LumaDomain / LumaPersistence 的公开边界。
        .executableTarget(
            name: "LumaDataChecks",
            dependencies: ["TestSupport", "LumaDomain", "LumaPersistence"],
            path: "Tests/LumaDataChecks",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
