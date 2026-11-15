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
        .executableTarget(
            name: "PhotosClone",
            dependencies: ["LumaCore"],
            path: "Sources/PhotosClone",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("NetFS")
            ]
        ),
        // 命令行工具链（无 Xcode）不提供 XCTest，这里用可执行 target 做断言检查。
        .executableTarget(
            name: "LumaCoreChecks",
            dependencies: ["LumaCore"],
            path: "Tests/LumaCoreChecks"
        )
    ]
)
