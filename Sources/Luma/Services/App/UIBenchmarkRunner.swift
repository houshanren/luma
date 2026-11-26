import AppKit
import Foundation
import LumaDomain

// MARK: - 报告结构

private struct UIBenchmarkReport: Codable {
    var schemaVersion: Int
    var generatedAt: String
    var appVersion: String
    var osVersion: String
    var architecture: String
    var libraryPath: String
    var libraryPhotoCount: Int
    var scenes: [UIBenchmarkSceneReport]
}

private struct UIBenchmarkSceneReport: Codable {
    var scene: String
    var status: String
    var note: String?
    var itemCount: Int
    var scrollable: Bool
    var passes: [UIBenchmarkPassReport]
}

private struct UIBenchmarkPassReport: Codable {
    var frame: UIPerformancePassReport
    var imageLoads: [UIImageLoadReport]
}

private struct UIImageLoadReport: Codable {
    var key: String
    var count: Int
    var failures: Int
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double
}

// MARK: - 基准编排

/// 应用内界面性能基准：环境变量 `LUMA_UI_BENCH=<report.json>` 触发。
///
/// 场景覆盖图库三种网格与影院 / 网络资源海报墙；每个场景跑两轮同样的滚动，
/// 第一轮偏冷、第二轮偏热。滚动由 `NSScrollView` 的 clip view 驱动，走的仍是
/// SwiftUI 正常的 LazyVGrid / LazyVStack 创建与图片加载路径。
@MainActor
enum UIBenchmarkRunner {
    private static var started = false

    private enum Scene: String, CaseIterable {
        case gridSquare = "grid-square"
        case gridActual = "grid-actual"
        case gridMasonry = "grid-masonry"
        case cinemaWall = "cinema-wall"
        case catalogChannel = "catalog-channel"

        var title: String { rawValue }
    }

    static func runIfRequested(store: LibraryStore, reportPath: String) async {
        guard !started else { return }
        started = true

        NSApp.activate(ignoringOtherApps: true)
        let scenes = requestedScenes()
        let seconds = Double(ProcessInfo.processInfo.environment["LUMA_UI_BENCH_SECONDS"] ?? "") ?? 5
        var sceneReports: [UIBenchmarkSceneReport] = []
        Diagnostics.record("界面基准开始：scenes=\(scenes.map(\.title).joined(separator: ",")) "
                           + "单轮=\(seconds)s")

        _ = await waitUntil({ store.visibleCount > 0 }, timeout: 45)
        Diagnostics.record("界面基准：图库可见照片 \(store.visibleCount)")
        if let window = await waitForWindow() {
            window.makeKeyAndOrderFront(nil)
            Diagnostics.record("界面基准：主窗口 \(Int(window.frame.width))x\(Int(window.frame.height))")
        } else {
            Diagnostics.record("界面基准：没有找到主窗口")
        }

        for scene in scenes {
            let preparation = await prepare(scene, store: store)
            Diagnostics.record("界面基准场景 \(scene.title)：\(preparation.ok ? "ok" : "skip") "
                               + "items=\(preparation.itemCount) \(preparation.note ?? "")")
            guard preparation.ok else {
                sceneReports.append(UIBenchmarkSceneReport(scene: scene.title,
                                                           status: "skipped",
                                                           note: preparation.note,
                                                           itemCount: preparation.itemCount,
                                                           scrollable: false,
                                                           passes: []))
                continue
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            guard let window = mainWindow(),
                  let scrollView = findScrollView(in: window) else {
                sceneReports.append(UIBenchmarkSceneReport(scene: scene.title,
                                                           status: "failed",
                                                           note: "找不到可垂直滚动的 NSScrollView",
                                                           itemCount: preparation.itemCount,
                                                           scrollable: false,
                                                           passes: []))
                continue
            }

            resetScroll(scrollView)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let first = await runPass(scrollView, label: "pass1", seconds: seconds)
            Diagnostics.record("界面基准 \(scene.title) pass1：fps=\(String(format: "%.1f", first.report.fps)) "
                               + "p95=\(String(format: "%.1f", first.report.p95Ms))ms "
                               + "doc=\(Int(first.report.documentHeight)) "
                               + "viewport=\(Int(first.report.viewportHeight))")

            resetScroll(scrollView)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let second = await runPass(scrollView, label: "pass2", seconds: seconds)
            Diagnostics.record("界面基准 \(scene.title) pass2：fps=\(String(format: "%.1f", second.report.fps)) "
                               + "p95=\(String(format: "%.1f", second.report.p95Ms))ms")

            let scrollable = first.report.documentHeight > first.report.viewportHeight + 60
            let capturedFrames = first.report.frames + second.report.frames
            let status = !scrollable ? "failed" : (capturedFrames == 0 ? "failed" : "ok")
            let note: String?
            if !scrollable {
                note = "内容高度不足，未产生滚动负载"
            } else if capturedFrames == 0 {
                note = "没有收到 CADisplayLink 回调（应用可能不可见）"
            } else {
                note = nil
            }
            sceneReports.append(UIBenchmarkSceneReport(scene: scene.title,
                                                       status: status,
                                                       note: note,
                                                       itemCount: preparation.itemCount,
                                                       scrollable: scrollable,
                                                       passes: [
                                                           UIBenchmarkPassReport(frame: first.report,
                                                                                 imageLoads: first.imageLoads),
                                                           UIBenchmarkPassReport(frame: second.report,
                                                                                 imageLoads: second.imageLoads)
                                                       ]))
        }

        writeReport(path: reportPath, scenes: sceneReports, store: store)
        try? await Task.sleep(nanoseconds: 200_000_000)
        NSApp.terminate(nil)
    }

    // MARK: - 场景准备

    private struct Preparation {
        var ok: Bool
        var note: String?
        var itemCount: Int
    }

    private static func prepare(_ scene: Scene, store: LibraryStore) async -> Preparation {
        switch scene {
        case .gridSquare, .gridActual, .gridMasonry:
            store.sidebarItem = .library
            switch scene {
            case .gridSquare: store.thumbnailAspect = .square
            case .gridActual: store.thumbnailAspect = .actual
            case .gridMasonry: store.thumbnailAspect = .masonry
            default: break
            }
            let ok = await waitUntil({ store.visibleCount > 0 }, timeout: 25)
            return Preparation(ok: ok,
                               note: ok ? nil : "图库没有可显示的照片",
                               itemCount: store.visibleCount)

        case .cinemaWall:
            store.cinemaViewMode = .wall
            store.cinemaTab = .all
            var scope = CinemaScope.local
            store.sidebarItem = .cinema
            if store.cinemaEntries(for: .local).isEmpty,
               let mount = store.cloudMounts.first(where: {
                   !store.cinemaEntries(for: .mount($0.id)).isEmpty
               }) {
                scope = .mount(mount.id)
                store.sidebarItem = .cloudCinema(mount.id)
            }
            let ok = await waitUntil({ !store.cinemaEntries(for: scope).isEmpty }, timeout: 20)
            return Preparation(ok: ok,
                               note: ok ? nil : "影院没有已刮削条目",
                               itemCount: store.cinemaEntries(for: scope).count)

        case .catalogChannel:
            guard let source = store.catalog.sources.first(where: {
                $0.isEnabled && $0.domain == .networkResource
            }) else {
                return Preparation(ok: false, note: "没有已启用的网络资源", itemCount: 0)
            }
            store.catalog.focus(source.id)
            if let category = source.categories.first(where: { !$0.isGroupCategory }) {
                store.catalog.openCategory(category)
            } else {
                store.catalog.openHome()
            }
            store.sidebarItem = .catalogSource(source.id)
            let ok = await waitUntil({ !store.catalog.items.isEmpty }, timeout: 30)
            return Preparation(ok: ok,
                               note: ok ? nil : "网络资源频道没有返回内容",
                               itemCount: store.catalog.items.count)
        }
    }

    // MARK: - 采样

    private struct PassResult {
        var report: UIPerformancePassReport
        var imageLoads: [UIImageLoadReport]
    }

    private static func runPass(_ scrollView: NSScrollView,
                                label: String,
                                seconds: TimeInterval) async -> PassResult {
        UIPerformanceMetrics.shared.begin()
        let report = await UIPerformanceMonitor.shared.run(scrollView: scrollView,
                                                           label: label,
                                                           seconds: seconds)
        let samples = UIPerformanceMetrics.shared.end()
        return PassResult(report: report, imageLoads: summarize(samples))
    }

    private static func summarize(_ samples: [UIImageLoadSample]) -> [UIImageLoadReport] {
        let grouped = Dictionary(grouping: samples, by: \.key)
        return grouped.keys.sorted().map { key in
            let values = grouped[key] ?? []
            let durations = values.map(\.seconds).sorted()
            return UIImageLoadReport(
                key: key,
                count: values.count,
                failures: values.filter { !$0.success }.count,
                p50Ms: percentile(durations, 50) * 1_000,
                p95Ms: percentile(durations, 95) * 1_000,
                maxMs: (durations.last ?? 0) * 1_000
            )
        }
    }

    private static func percentile(_ sorted: [Double], _ pct: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, min(sorted.count - 1, Int(ceil(pct / 100 * Double(sorted.count))) - 1))
        return sorted[index]
    }

    // MARK: - 窗口 / 滚动

    private static func mainWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    private static func waitForWindow() async -> NSWindow? {
        if let window = mainWindow() { return window }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let window = mainWindow() { return window }
        }
        return nil
    }

    /// 选面积最大、且纵向内容超过可视高度的 NSScrollView：
    /// 侧边栏与横向货架都会被子视图遍历命中，但面积和纵向条件会把它们排除。
    private static func findScrollView(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var result: NSScrollView?
        var bestArea: CGFloat = 0
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, isVerticallyScrollable(scroll) {
                let clip = scroll.contentView.bounds
                let area = clip.width * clip.height
                if area > bestArea {
                    bestArea = area
                    result = scroll
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return result
    }

    private static func isVerticallyScrollable(_ scroll: NSScrollView) -> Bool {
        guard scroll.window != nil, !scroll.isHidden, scroll.alphaValue > 0.01 else { return false }
        let clip = scroll.contentView.bounds
        guard clip.width > 120, clip.height > 120 else { return false }
        let documentHeight = scroll.documentView?.frame.height ?? 0
        return documentHeight > clip.height + 60
    }

    private static func resetScroll(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - 环境 / 报告

    private static func requestedScenes() -> [Scene] {
        let raw = ProcessInfo.processInfo.environment["LUMA_UI_BENCH_SCENES"] ?? ""
        let requested = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !requested.isEmpty else { return Scene.allCases }
        let scenes = requested.compactMap(Scene.init(rawValue:))
        return scenes.isEmpty ? Scene.allCases : scenes
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool,
                                  timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return condition()
    }

    private static func writeReport(path: String, scenes: [UIBenchmarkSceneReport],
                                    store: LibraryStore) {
        let report = UIBenchmarkReport(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            libraryPath: LibraryPaths.containerLibraryURL?.path ?? "unknown",
            libraryPhotoCount: store.visibleCount,
            scenes: scenes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else {
            Diagnostics.record("界面基准报告编码失败")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            Diagnostics.record("界面基准完成：\(url.path)")
        } catch {
            Diagnostics.record("界面基准报告写入失败：\(error.localizedDescription)")
        }
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
