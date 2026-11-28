import AppKit
import Foundation
import LumaDomain

/// 测试集 / 产品截图的应用内入口。
///
/// 只由环境变量驱动，正常启动完全不参与：
/// - `LUMA_TESTKIT_DATASET`：`Tools/testkit` 生成的测试集根目录（必填）。
/// - `LUMA_TESTKIT_SEED=1`：把测试集的照片 / 视频导入演示图库（默认
///   `~/Movies/LumaTestKit/Demo.photoslibrary`，可用 `LUMA_TESTKIT_LIBRARY` 覆盖）。
/// - `LUMA_TESTKIT_MODULES=1`：接入测试集里的网盘 / 网络影院 / 网络资源 / 电视源，
///   需要同时提供 `LUMA_TESTKIT_SERVER`（mock 源服务地址）与
///   `LUMA_TESTKIT_TV_PLAYLIST`（运行时可用的 M3U 路径）。
///   测试集是一条 2010–2026 的家庭生活主线（旅行 / 上学 / 补课 / 婚礼 / 乐园 / 国内景点），
///   视频拍摄时间由 `dataset/.meta/video_dates.json` 补齐。
/// - `LUMA_TESTKIT_SCREEN`：要截图的页面 id，逗号分隔，或 `all`。
/// - `LUMA_TESTKIT_SCREENS`：页面清单 JSON（默认由 testkit.py 指向
///   `Tools/testkit/screens/screens.json`）。每个页面用 `action` 声明进入方式，
///   新增页面只加 JSON，不再改应用代码。
/// - `LUMA_TESTKIT_SHOTS`：PNG 输出目录。
/// - `LUMA_TESTKIT_SETTLE`：每次切换页面后的等待秒数，默认 2.5。
/// - `LUMA_TESTKIT_SIZE`：窗口内容尺寸，形如 `1440x900`。
/// - `LUMA_TESTKIT_QUIT=1`：全部截完退出应用。
///
/// 产物：`<shots>/<screen-id>.png`、`<shots>/index.json`、`<shots>/captures.md`。
/// `captures.md` 是给文档 / 官网用的图注清单，AI 可以直接按它引用真实截图。
@MainActor
enum TestKitHarness {
    private static var started = false

    private struct ScreenEntry {
        let id: String
        let title: String
        let note: String
        let action: ScreenAction?
    }

    /// 声明式动作：页面清单写在 `Tools/testkit/screens/screens.json`，
    /// 新增页面只加一条 JSON，不必再改应用代码。
    private struct ScreenAction {
        let kind: String
        let target: String?
        let grouping: String?
        let aspect: String?
        let sortKey: String?
        let sortAscending: Bool?
        let count: Int?
        let x: Double?
        let y: Double?
        let info: Bool?
        let scope: String?
        let text: String?

        init?(json: [String: Any]) {
            guard let kind = json["kind"] as? String else { return nil }
            self.kind = kind
            self.target = json["target"] as? String ?? json["to"] as? String
            self.grouping = json["grouping"] as? String
            self.aspect = json["aspect"] as? String
            self.sortKey = json["sortKey"] as? String
            self.sortAscending = json["sortAscending"] as? Bool
            self.count = json["count"] as? Int
            self.x = json["x"] as? Double
            self.y = json["y"] as? Double
            self.info = json["info"] as? Bool
            self.scope = json["scope"] as? String
            self.text = json["text"] as? String
        }
    }

    /// 从 screens.json 读取页面清单；读不到就不截图，避免两处清单各说各话。
    private static func loadScreens(from path: String) -> [ScreenEntry]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["screens"] as? [[String: Any]] else {
            Diagnostics.record("TestKit：screens.json 读取失败 \(path)")
            return nil
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            var action: ScreenAction?
            if let dict = row["action"] as? [String: Any] {
                guard let parsed = ScreenAction(json: dict) else {
                    Diagnostics.record("TestKit：\(id) 的 action 缺少 kind，已跳过")
                    return nil
                }
                action = parsed
            }
            return ScreenEntry(id: id,
                               title: row["title"] as? String ?? id,
                               note: row["description"] as? String
                                   ?? row["note"] as? String ?? "",
                               action: action)
        }
    }

    private static var activeScreens: [ScreenEntry] = []

    static func runIfRequested(store: LibraryStore, settings: AppSettings,
                               catalog: CatalogBrowserModel,
                               tv: IPTVBrowserModel,
                               cloud: CloudBrowserModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let datasetPath = env["LUMA_TESTKIT_DATASET"], !datasetPath.isEmpty else { return }
        guard !started else { return }
        started = true

        // 页面清单只认 screens.json：新增页面只加 JSON，不再改应用代码。
        if let screensPath = env["LUMA_TESTKIT_SCREENS"], !screensPath.isEmpty,
           let screens = loadScreens(from: screensPath) {
            activeScreens = screens
        }
        guard !activeScreens.isEmpty else {
            Diagnostics.record("TestKit：没有可用的页面清单（LUMA_TESTKIT_SCREENS）")
            if env["LUMA_TESTKIT_QUIT"] == "1" { NSApp.terminate(nil) }
            return
        }

        let dataset = URL(fileURLWithPath: datasetPath, isDirectory: true)
        let shots = URL(fileURLWithPath: env["LUMA_TESTKIT_SHOTS"] ?? dataset.path, isDirectory: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        Diagnostics.record("TestKit：启动 dataset=\(dataset.path) shots=\(shots.path)")

        if env["LUMA_TESTKIT_SEED"] == "1" {
            await seedLibrary(store: store, dataset: dataset, env: env)
        }
        if env["LUMA_TESTKIT_MODULES"] == "1" {
            await seedModules(store: store, settings: settings, dataset: dataset, env: env)
        }

        let requested = requestedScreens(env["LUMA_TESTKIT_SCREEN"])
        guard !requested.isEmpty else {
            Diagnostics.record("TestKit：没有要截图的页面")
            if env["LUMA_TESTKIT_QUIT"] == "1" { NSApp.terminate(nil) }
            return
        }

        let settle = Double(env["LUMA_TESTKIT_SETTLE"] ?? "") ?? 2.5

        // 「侧边栏逐层展开」：本次包含侧边栏类页面（或显式开启）时，先展开整棵树，
        // 之后每张截图都沿用同一棵展平的侧边栏。
        if env["LUMA_TESTKIT_SIDEBAR_EXPAND"] == "1"
            || requested.contains(where: { $0.action?.kind == "sidebar" }) {
            store.sidebarExpandRequest &+= 1
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        var captured: [[String: String]] = []
        for entry in requested {
            // 先把应用拉到前台：sheet / 输入框获得焦点依赖 key window，
            // 后台状态下弹 AI 助手会触发持续的布局循环。
            NSApp.activate(ignoringOtherApps: true)
            mainWindow()?.makeKeyAndOrderFront(nil)
            // 上一张的 sheet / 弹层 / 选择态先收干净，否则会叠在下一张里。
            resetInteraction(store: store, catalog: catalog, tv: tv, cloud: cloud)
            try? await Task.sleep(nanoseconds: 250_000_000)
            // 侧边栏类页面逐项点开，一次产出多张（见 screens.json 的 sidebar 分组）。
            if entry.action?.kind == "sidebar" {
                if let window = mainWindow() { applyWindowSize(to: window, env: env) }
                let rows = await captureSidebar(entry: entry, shots: shots, settle: settle,
                                                store: store, catalog: catalog,
                                                tv: tv, cloud: cloud)
                captured.append(contentsOf: rows)
                continue
            }
            await prepare(screen: entry, shots: shots, store: store,
                          catalog: catalog, tv: tv, cloud: cloud)
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            // 右键菜单类页面在 prepare 里就完成截图：菜单跟踪会占住主线程，
            // 必须由后台线程截屏并补一个 Esc 收起。
            if entry.action?.kind == "menu" {
                let url = shots.appendingPathComponent("\(entry.id).png")
                if FileManager.default.fileExists(atPath: url.path) {
                    captured.append(["id": entry.id, "title": entry.title, "note": entry.note,
                                     "file": url.lastPathComponent])
                    Diagnostics.record("TestKit：已截图 \(entry.id) → \(url.path)")
                } else {
                    Diagnostics.record("TestKit：截图失败 \(entry.id)")
                }
                continue
            }
            guard let window = captureWindow(for: entry.id) else {
                Diagnostics.record("TestKit：\(entry.id) 没有可截图的窗口")
                continue
            }
            // 只调整主窗口：sheet / 设置窗口有自己的尺寸约束，强行拉到 1440x900 会触发布局循环。
            if window.sheetParent == nil, !entry.id.hasPrefix("settings.") {
                applyWindowSize(to: window, env: env)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let url = shots.appendingPathComponent("\(entry.id).png")
            if capture(window: window, to: url) {
                captured.append(["id": entry.id, "title": entry.title, "note": entry.note,
                                 "file": url.lastPathComponent])
                Diagnostics.record("TestKit：已截图 \(entry.id) → \(url.path)")
            } else {
                Diagnostics.record("TestKit：截图失败 \(entry.id)")
            }
        }

        writeManifests(captured, to: shots, dataset: dataset)
        if env["LUMA_TESTKIT_QUIT"] == "1" {
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    // MARK: - 演示库

    private static func seedLibrary(store: LibraryStore, dataset: URL, env: [String: String]) async {
        let libraryURL = URL(fileURLWithPath: env["LUMA_TESTKIT_LIBRARY"]
                             ?? URL(fileURLWithPath: NSHomeDirectory())
                                .appendingPathComponent("Movies/LumaTestKit/Demo.photoslibrary").path,
                             isDirectory: true)

        // 批量截图默认重建演示库：上一次运行留下的 mock 端口、源与探活结果不能带进来。
        let fresh = env["LUMA_TESTKIT_FRESH"] == "1"
        if fresh {
            try? FileManager.default.removeItem(at: libraryURL)
            Diagnostics.record("TestKit：重建演示库 \(libraryURL.path)")
        }

        let isCurrent = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
            == libraryURL.standardizedFileURL.path
        if fresh {
            // 当前进程可能已经把旧库读进内存：删掉之后必须重新建库再导入。
            let created = await store.createLibrary(at: libraryURL)
            Diagnostics.record("TestKit：创建演示库 \(libraryURL.path) ok=\(created)")
        } else if !isCurrent {
            if LibraryPaths.isLibraryContainer(libraryURL) {
                Diagnostics.record("TestKit：切换到已有演示库 \(libraryURL.path)")
                store.switchLibraryContainer(libraryURL)
            } else {
                Diagnostics.record("TestKit：创建演示库 \(libraryURL.path)")
                _ = await store.createLibrary(at: libraryURL)
            }
        }

        guard store.photos.isEmpty else {
            Diagnostics.record("TestKit：演示库已有 \(store.photos.count) 项，跳过导入")
            return
        }

        let includeVariants = env["LUMA_TESTKIT_IMPORT_VARIANTS"] == "1"
        let entries = mediaEntries(dataset: dataset, includeVariants: includeVariants)
        guard !entries.isEmpty else {
            Diagnostics.record("TestKit：测试集里没有可导入的媒体")
            return
        }
        Diagnostics.record("TestKit：导入 \(entries.count) 个媒体到演示库")
        store.runImport(entries: entries,
                        options: ImportOptions(createAlbumsFromFolders: true,
                                               preserveFolderStructure: true,
                                               skipExactDuplicates: true,
                                               verifyCopies: false))
        let done = await waitUntil(timeout: 300) { !store.isImporting && store.visibleCount > 0 }
        Diagnostics.record("TestKit：导入结束 imported=\(store.photos.count) ok=\(done)")
        applyVideoDates(store: store, dataset: dataset)
        seedCuratedLibrary(store: store)
        store.navigate(to: .library)
        _ = await waitUntil(timeout: 30) { store.visibleCount > 0 }
    }

    /// 演示库的文件夹 / 相簿层级与收藏：主题跟随 2010–2026 的家庭故事线。
    /// 只在空库导入完成后执行一次（已有文件夹就跳过），不会碰真实图库。
    private static func seedCuratedLibrary(store: LibraryStore) {
        guard store.folders.isEmpty else { return }
        let tree: [(folder: String, albums: [String])] = [
            ("旅行", ["2010-2013 第一次出发", "2014-2017 亚洲邻居",
                    "2018-2021 欧洲夏天", "2022-2026 跨过海洋"]),
            ("家里与成长", ["2010-2016 家里日常", "2017-2021 周末与补课", "2024-2026 自拍"]),
            ("国内山河", ["2022-2026 国内山河", "2019 全景足迹",
                       "2024-2026 家里的笑声", "2026 摄影练习"])
        ]
        for node in tree {
            guard let folderID = store.createFolder(named: node.folder) else { continue }
            for name in node.albums {
                guard let album = store.albums.first(where: { $0.name == name }) else { continue }
                store.moveAlbum(album.id, toFolder: folderID)
            }
        }

        // 精选相簿：从故事线里按文件名关键词挑照片。
        let featured: [(album: String, keywords: [String], limit: Int)] = [
            ("全家福精选", [], 10),
            ("海边时光", ["三亚", "巴厘", "海滩", "大堡礁", "悉尼", "鼓浪屿"], 12),
            ("雪山与高原", ["雪山", "瑞士", "西藏", "布达拉", "黄山", "九寨"], 12)
        ]
        var featuredIDs: Set<UUID> = []
        if let folderID = store.createFolder(named: "精选") {
            for spec in featured {
                let candidates: [PhotoItem]
                if spec.keywords.isEmpty {
                    let sourceIDs = Set(store.albums.first(where: { $0.name == "2010-2016 家里日常" })?
                        .photoIDs ?? [])
                    candidates = store.photos.filter {
                        !$0.isVideo && $0.deletedAt == nil && sourceIDs.contains($0.id)
                    }
                } else {
                    candidates = store.photos.filter { photo in
                        !photo.isVideo && photo.deletedAt == nil
                            && spec.keywords.contains { photo.originalName.contains($0) }
                    }
                }
                let ids = Set(candidates.prefix(spec.limit).map(\.id))
                guard !ids.isEmpty else { continue }
                store.createAlbum(named: spec.album, folderID: folderID)
                guard let album = store.albums.first(where: {
                    $0.name == spec.album && $0.folderID == folderID
                }) else { continue }
                store.addToAlbum(album.id, photoIDs: ids)
                featuredIDs.formUnion(ids)
            }
        }

        // 收藏：精选、每个相簿的首张，以及自拍 / 全景，让「个人收藏」有内容。
        var favoriteIDs = featuredIDs
        for album in store.albums {
            if let first = album.photoIDs.first { favoriteIDs.insert(first) }
        }
        favoriteIDs.formUnion(store.photos.filter {
            $0.kind == .selfie || $0.kind == .panorama
        }.map(\.id))
        store.toggleFavorite(ids: favoriteIDs)
        // 评分：精选 5 星，其余按抽样 3 星，让「图库整理」有分布。
        store.setRating(5, ids: featuredIDs)
        let sampled = Set(store.photos.enumerated()
            .filter { $0.offset % 9 == 0 }
            .map(\.element.id))
        store.setRating(3, ids: sampled)
    }

    /// 视频按测试集里的拍摄日期落到 2010–2026：MKV / TS / AVI 的元数据
    /// AVFoundation 读不到，靠 `video_dates.json` 才能进对应年份。
    private static func applyVideoDates(store: LibraryStore, dataset: URL) {
        let path = dataset.appendingPathComponent(".meta/video_dates.json")
        guard let data = try? Data(contentsOf: path),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        let formatter = ISO8601DateFormatter()
        var changed = false
        for index in store.photos.indices where store.photos[index].isVideo {
            guard let raw = table[store.photos[index].originalName],
                  let date = formatter.date(from: raw),
                  store.photos[index].capturedAt != date else { continue }
            store.photos[index].capturedAt = date
            changed = true
        }
        if changed { store.save() }
    }

    private static func mediaEntries(dataset: URL, includeVariants: Bool) -> [(url: URL, folders: [String])] {
        let fm = FileManager.default
        var roots: [URL] = [dataset.appendingPathComponent("photos", isDirectory: true)]
        // 视频统一放在 videos/ 下，导入后进入「视频」页与影院候选。
        let videos = dataset.appendingPathComponent("videos", isDirectory: true)
        if fm.fileExists(atPath: videos.path) { roots.append(videos) }
        // 实况照片：JPEG 与同名 MOV 放在同一目录，导入时会自动配对。
        let live = dataset.appendingPathComponent("live", isDirectory: true)
        if fm.fileExists(atPath: live.path) { roots.append(live) }
        // 截屏：文件名带 Screenshot，导入后进入「截屏」入口。
        let screenshots = dataset.appendingPathComponent("screenshots", isDirectory: true)
        if fm.fileExists(atPath: screenshots.path) { roots.append(screenshots) }
        if includeVariants {
            let variants = dataset.appendingPathComponent("variants", isDirectory: true)
            if fm.fileExists(atPath: variants.path) { roots.append(variants) }
        }

        var result: [(URL, [String])] = []
        for root in roots {
            let isLiveRoot = root.lastPathComponent == "live"
            guard let enumerator = fm.enumerator(at: root,
                                                includingPropertiesForKeys: [.isRegularFileKey],
                                                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                // live/ 下只有实况照片（JPEG + 同名 MOV）需要导入；HLS、台标、M3U 与 EPG 不是图库内容。
                if isLiveRoot && relative.contains("/") { continue }
                let ext = url.pathExtension.lowercased()
                if ["ts", "m3u", "m3u8", "xml", "nfo", "srt", "ass", "txt"].contains(ext) { continue }
                // 损坏样本只用于解码失败回归，不进演示图库。
                if url.lastPathComponent == "broken.mp4" { continue }
                var folders = relative.split(separator: "/").dropLast().map(String.init)
                // 只有照片根目录用文件夹名建相簿；视频 / 实况 / 变体不额外生成相簿。
                if folders.isEmpty, root.lastPathComponent == "photos" {
                    folders = [root.lastPathComponent]
                }
                guard MediaTypeSupport.isSupportedImport(url) || VideoFormats.isVideo(url) else { continue }
                result.append((url, folders))
            }
        }
        return result.sorted { $0.0.path < $1.0.path }
    }

    // MARK: - 模块源

    private static func seedModules(store: LibraryStore, settings: AppSettings,
                                    dataset: URL, env: [String: String]) async {
        let server = env["LUMA_TESTKIT_SERVER"] ?? ""
        settings.setModuleEnabled(.cloud, true)
        settings.setModuleEnabled(.catalog, true)
        settings.setModuleEnabled(.television, true)
        settings.setModuleEnabled(.cinema, true)

        if let playlistPath = env["LUMA_TESTKIT_TV_PLAYLIST"], !playlistPath.isEmpty,
           store.tvModel.playlists.isEmpty {
            do {
                _ = try await store.tvModel.importPlaylistFile(at: URL(fileURLWithPath: playlistPath))
                Diagnostics.record("TestKit：已导入电视源 \(playlistPath)")
            } catch {
                Diagnostics.record("TestKit：电视源导入失败 \(error.localizedDescription)")
            }
        }

        if !server.isEmpty, store.catalog.sources(in: .networkCinema).isEmpty {
            let api = server + "/cms/api.php/provide/vod/"
            if var source = try? await MacCMSCatalogProvider.importSource(from: api,
                                                                         fallbackName: "Luma 测试影院") {
                // 测试源默认启用，否则网络影院首页不会拉取列表。
                source.isEnabled = true
                store.catalog.addSource(source)
                Diagnostics.record("TestKit：已接入网络影院源 \(source.name)")
            } else {
                Diagnostics.record("TestKit：网络影院源探测失败 \(api)")
            }
        }

        if !server.isEmpty, store.catalog.sources(in: .networkResource).isEmpty {
            // mock 服务的根地址本身就是一套 Tuzac 结构的图集站，直接走真实导入链路。
            if var source = try? await TuzacCatalogProvider.importSource(from: server) {
                source.isEnabled = true
                source.name = "Luma 测试图集"
                store.catalog.addSource(source)
                Diagnostics.record("TestKit：已接入网络资源源 \(source.name)")
            } else {
                Diagnostics.record("TestKit：网络资源源探测失败 \(server)")
            }
        }

        if !server.isEmpty, store.cloudMounts.isEmpty,
           let base = WebDAVClient.normalizedBaseURL(server + "/webdav")?.absoluteString {
            // 直接登记挂载点，不写钥匙串：mock WebDAV 不需要鉴权，
            // 也避免截图流程被系统钥匙串授权弹窗打断。
            let mount = CloudMount(kind: .webdav, name: "Luma 测试 NAS",
                                   baseURL: base, username: "")
            store.cloudMounts.append(mount)
            store.saveCloudMounts()
            store.navigate(to: .cloudMount(mount.id))
            Diagnostics.record("TestKit：接入 WebDAV \(base)")
        }

        // 本机导出的来源配置（StreamSource）：导入后侧边栏就是真实来源，覆盖「创建 → 导入」链路。
        if let bundlePath = env["LUMA_TESTKIT_SOURCE_BUNDLE"], !bundlePath.isEmpty {
            seedSourceBundles(directory: URL(fileURLWithPath: bundlePath, isDirectory: true),
                              store: store)
        }
    }

    /// 把 `StreamSource` 里的三类 JSON 配置导进演示库：
    /// 网络资源 / 网络影院走 `CatalogSource`，网络电视走 `TVPlaylist`，与界面导入同一套解码。
    private static func seedSourceBundles(directory: URL, store: LibraryStore) {
        let resources = directory.appendingPathComponent("Luma-网络资源.json")
        let cinema = directory.appendingPathComponent("Luma-网络影院.json")
        let television = directory.appendingPathComponent("Luma-网络电视.json")

        for (url, scope) in [(resources, SourceTransferScope.catalogResource),
                             (cinema, SourceTransferScope.networkCinema)] {
            guard let data = try? Data(contentsOf: url),
                  case .success(let items) = SourceTransferJSON.decode(CatalogSource.self,
                                                                       from: data,
                                                                       expecting: scope) else {
                Diagnostics.record("TestKit：来源配置读取失败 \(url.lastPathComponent)")
                continue
            }
            for item in items { store.catalog.addSource(item) }
            Diagnostics.record("TestKit：导入 \(url.lastPathComponent) 共 \(items.count) 个")
        }

        if let data = try? Data(contentsOf: television) {
            let outcome = store.tvModel.importPlaylistBundle(data)
            Diagnostics.record("TestKit：导入 \(television.lastPathComponent)：\(outcome.summary)")
        }
    }

    // MARK: - 页面导航

    private static func requestedScreens(_ raw: String?) -> [ScreenEntry] {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        if value == "all" { return activeScreens }
        let ids = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let known = Dictionary(uniqueKeysWithValues: activeScreens.map { ($0.id, $0) })
        return ids.compactMap { known[$0] }
    }

    /// 把上一次截图留下的 sheet / 弹层 / 选择态收干净。
    private static func resetInteraction(store: LibraryStore,
                                         catalog: CatalogBrowserModel,
                                         tv: IPTVBrowserModel,
                                         cloud: CloudBrowserModel) {
        store.editorID = nil
        store.showImportSheet = false
        store.showInfoPanel = false
        store.aiSurfaceMode = .hidden
        store.aiPendingApproval = nil
        store.showNewAlbumSheet = false
        store.showBatchChangeSheet = false
        store.showExportSheet = false
        store.showCompressionSheet = false
        store.showKeywordManager = false
        store.showShortcutHelp = false
        store.showPhotoPicker = false
        store.showSlideshow = false
        store.showAIInspector = false
        store.namePrompt = nil
        store.pendingDeletion = nil
        store.systemToolsRequest = nil
        store.editingSmartAlbum = nil
        store.clearSelection()
        catalog.showWizard = false
        tv.showWizard = false
        cloud.showSheet = false
        cloud.showWizard = false
    }

    private static func prepare(screen entry: ScreenEntry, shots: URL, store: LibraryStore,
                                catalog: CatalogBrowserModel, tv: IPTVBrowserModel,
                                cloud: CloudBrowserModel) async {
        // 上一页遗留的弹层先收起，避免污染下一张截图。
        store.showAIAssistant = false
        store.searchText = ""
        store.viewerID = nil
        guard let action = entry.action else {
            Diagnostics.record("TestKit：\(entry.id) 没有 action，跳过")
            return
        }
        if !(await run(action, id: entry.id, shots: shots, store: store,
                       catalog: catalog, tv: tv, cloud: cloud)) {
            Diagnostics.record("TestKit：\(entry.id) 的 action \(action.kind) 没有匹配的处理")
        }
    }

    /// 执行一条声明式动作。新增页面只需要在 screens.json 里挑现成的 kind / target。
    private static func run(_ action: ScreenAction, id: String, shots: URL,
                            store: LibraryStore, catalog: CatalogBrowserModel,
                            tv: IPTVBrowserModel, cloud: CloudBrowserModel) async -> Bool {
        switch action.kind {
        case "gallery":
            applyViewState(action, store: store)
            store.navigate(to: .library)
            return true
        case "navigate":
            return navigate(to: action.target, store: store)
        case "viewer":
            store.grouping = .all
            store.thumbnailAspect = .square
            store.navigate(to: .library)
            _ = await waitUntil(timeout: 30) { store.visibleCount > 0 }
            let wantsVideo = action.target == "video"
            guard let photo = store.visiblePhotos.first(where: { $0.isVideo == wantsVideo }) else {
                return false
            }
            if wantsVideo {
                store.openViewer(photo.id)
            } else {
                store.showInfoPanel = action.info == true
                store.openViewer(photo.id)
            }
            return true
        case "search":
            store.navigate(to: .library)
            store.searchScope = action.scope == "module" ? .module : .global
            store.searchText = action.text ?? "海边"
            return true
        case "select":
            return await selectPhotos(count: action.count ?? 6, store: store)
        case "sheet":
            return await presentSheet(action.target, store: store)
        case "overlay":
            switch action.target {
            case "deleteConfirm":
                guard await selectPhotos(count: action.count ?? 6, store: store) else { return false }
                store.pendingDeletion = LibraryStore.DeleteRequest(ids: store.selection, kind: .trash)
            case "slideshow":
                store.navigate(to: .library)
                _ = await waitUntil(timeout: 30) { store.visibleCount > 0 }
                store.presentSlideshow()
            default:
                return false
            }
            return true
        case "editor":
            store.grouping = .all
            store.navigate(to: .library)
            _ = await waitUntil(timeout: 30) { store.visibleCount > 0 }
            guard let photo = store.visiblePhotos.first(where: { !$0.isVideo }) else { return false }
            store.openEditor(photo.id)
            return true
        case "wizard":
            switch action.target {
            case "catalog": catalog.showWizard = true
            case "cloud": cloud.showSheet = true
            case "tv": tv.showWizard = true
            default: return false
            }
            return true
        case "menu":
            if action.target == "sidebar" {
                store.navigate(to: .allAlbums)
            } else {
                store.grouping = .all
                store.thumbnailAspect = .square
                store.navigate(to: .library)
            }
            _ = await waitUntil(timeout: 30) { store.visibleCount > 0 }
            guard let window = mainWindow() else { return false }
            return await captureContextMenu(in: window,
                                            atFraction: CGPoint(x: action.x ?? 0.42,
                                                                y: action.y ?? 0.52),
                                            to: shots.appendingPathComponent("\(id).png"))
        case "window":
            guard action.target == "import" else { return false }
            store.navigate(to: .library)
            store.showImportSheet = true
            return true
        case "ai":
            return presentAI(target: action.target, store: store)
        default:
            return false
        }
    }

    private static func applyViewState(_ action: ScreenAction, store: LibraryStore) {
        switch action.grouping {
        case "years": store.grouping = .years
        case "months": store.grouping = .months
        case "all": store.grouping = .all
        default: break
        }
        switch action.aspect {
        case "square": store.thumbnailAspect = .square
        case "actual": store.thumbnailAspect = .actual
        case "masonry": store.thumbnailAspect = .masonry
        case "list": store.thumbnailAspect = .list
        default: break
        }
        if let key = action.sortKey.flatMap({ SortKey(rawValue: $0) }) {
            store.sortKey = key
        }
        if let ascending = action.sortAscending {
            store.sortAscending = ascending
        }
    }

    private static func navigate(to target: String?, store: LibraryStore) -> Bool {
        switch target {
        case "library": store.navigate(to: .library)
        case "allAlbums": store.navigate(to: .allAlbums)
        case "people": store.navigate(to: .people)
        case "places": store.navigate(to: .places)
        case "map": store.navigate(to: .map)
        case "keywords": store.navigate(to: .keywords)
        case "favorites": store.navigate(to: .favorites)
        case "videos": store.navigate(to: .videos)
        case "screenshots": store.navigate(to: .screenshots)
        case "health": store.navigate(to: .health)
        case "revisit": store.navigate(to: .revisit)
        case "trash": store.navigate(to: .trash)
        case "catalogSources": store.navigate(to: .catalogSources)
        case "networkCinema": store.navigate(to: .networkCinema)
        case "iptv": store.navigate(to: .iptv)
        case "cloudStorages": store.navigate(to: .cloudStorages)
        case "firstCatalogSource":
            if let source = store.catalog.sources(in: .networkResource).first(where: \.isEnabled)
                ?? store.catalog.sources(in: .networkResource).first {
                store.navigate(to: .catalogSource(source.id))
            } else {
                store.navigate(to: .catalogSources)
            }
        case "firstCloudMount":
            if let mount = store.cloudMounts.first {
                store.navigate(to: .cloudMount(mount.id))
            } else {
                store.navigate(to: .cloudStorages)
            }
        default:
            return false
        }
        return true
    }

    /// 切到「所有照片」并选中前 `count` 张，给批量操作类页面用。
    private static func selectPhotos(count: Int, store: LibraryStore) async -> Bool {
        store.grouping = .all
        store.thumbnailAspect = .square
        store.navigate(to: .library)
        _ = await waitUntil(timeout: 30) { store.visibleCount > 0 }
        let ids = Set(store.visiblePhotos.prefix(count).map(\.id))
        guard !ids.isEmpty else { return false }
        store.selection = ids
        return true
    }

    private static func presentSheet(_ target: String?, store: LibraryStore) async -> Bool {
        switch target {
        case "newAlbum":
            store.navigate(to: .allAlbums)
            store.showNewAlbumSheet = true
        case "namePrompt":
            store.navigate(to: .allAlbums)
            store.namePrompt = NamePromptPayload.newAlbum(folderID: nil)
        case "batchChange":
            guard await selectPhotos(count: 6, store: store) else { return false }
            store.showBatchChangeSheet = true
        case "export":
            guard await selectPhotos(count: 6, store: store) else { return false }
            // 走真实入口：先写入 exportTargets，面板才会显示实际项数。
            store.presentBatchExport()
        case "compression":
            guard await selectPhotos(count: 6, store: store) else { return false }
            store.presentCompression(for: store.selection)
        case "keywords":
            guard await selectPhotos(count: 3, store: store) else { return false }
            store.showKeywordManager = true
        case "shortcuts":
            store.showShortcutHelp = true
        default:
            return false
        }
        return true
    }

    // MARK: - 侧边栏逐项

    /// 侧边栏里的一次点击：`suffix` 拼在页面 id 后形成文件名，`apply` 把界面切到该入口。
    private struct SidebarShot {
        let suffix: String
        let title: String
        let apply: () -> Void
    }

    /// 固定语义入口：与侧边栏「图库 / 媒体类型 / 更多项目 / 相簿」里的行一一对应。
    private static let basicSidebarItems: [(slug: String, title: String, item: SidebarItem)] = [
        ("library", "图库", .library),
        ("collections", "精选集", .collections),
        ("favorites", "个人收藏", .favorites),
        ("videos", "视频", .videos),
        ("screenshots", "截屏", .screenshots),
        ("live", "实况照片", .livePhotos),
        ("selfies", "自拍", .selfies),
        ("panoramas", "全景", .panoramas),
        ("animated", "动图", .animated),
        ("raws", "RAW", .raws),
        ("recently-edited", "最近编辑", .recentlyEdited),
        ("recently-saved", "最近保存", .recentlySaved),
        ("imports", "导入项目", .imports),
        ("keywords", "关键词", .keywords),
        ("map", "地图", .map),
        ("places", "位置", .places),
        ("people", "人物", .people),
        ("duplicates", "重复项目", .duplicates),
        ("health", "图库体检", .health),
        ("ratings", "图库整理", .ratings),
        ("revisit", "值得重看", .revisit),
        ("ocr", "包含文字", .ocrTexts),
        ("trash", "最近删除", .trash),
        ("media-types", "媒体类型总览", .mediaTypes),
        ("scenes", "场景总览", .scenes),
        ("more-items", "更多项目总览", .moreItems),
        ("all-albums", "所有相簿", .allAlbums)
    ]

    /// 把侧边栏某一段逐项点开并逐张截图，返回写进清单的行。
    /// 分组名由 screens.json 的 `action.target` 指定：basics / albums / folders / cloud / catalog / tv / scenes。
    private static func captureSidebar(entry: ScreenEntry, shots: URL, settle: Double,
                                       store: LibraryStore, catalog: CatalogBrowserModel,
                                       tv: IPTVBrowserModel,
                                       cloud: CloudBrowserModel) async -> [[String: String]] {
        let group = entry.action?.target ?? "basics"
        // 先按这一组要拍的分区把侧边栏展开 / 收拢，目标段才会落在可视区域。
        store.sidebarExpandTarget = sidebarFocus(for: group)
        store.sidebarExpandRequest &+= 1
        try? await Task.sleep(nanoseconds: 700_000_000)
        if group == "cloud" {
            // 网盘目录要先扫回来，才能把根目录逐层拍下来。
            if let mount = store.cloudMounts.first, store.cloudRootFolders.isEmpty {
                store.navigate(to: .cloudMount(mount.id))
                store.beginCloudAlbumScan(mountID: mount.id)
            }
            _ = await waitUntil(timeout: 30) { !store.cloudRootFolders.isEmpty }
        }
        let items = sidebarShots(group: group, store: store, catalog: catalog, tv: tv)
        guard !items.isEmpty, let window = mainWindow() else {
            Diagnostics.record("TestKit：\(entry.id) 没有可点开的侧边栏条目（\(group)）")
            return []
        }
        var rows: [[String: String]] = []
        let wait = UInt64(max(1.0, settle * 0.5) * 1_000_000_000)
        for item in items {
            resetInteraction(store: store, catalog: catalog, tv: tv, cloud: cloud)
            try? await Task.sleep(nanoseconds: 120_000_000)
            item.apply()
            try? await Task.sleep(nanoseconds: wait)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let id = "\(entry.id).\(item.suffix)"
            let url = shots.appendingPathComponent("\(id).png")
            if capture(window: window, to: url) {
                rows.append(["id": id, "title": "\(entry.title) · \(item.title)",
                             "note": entry.note, "file": url.lastPathComponent])
                Diagnostics.record("TestKit：已截图 \(id) → \(url.path)")
            } else {
                Diagnostics.record("TestKit：截图失败 \(id)")
            }
        }
        return rows
    }

    /// 每个截图分组聚焦哪一个一级分区（见 `SidebarView.expandLevels(focus:)`）。
    private static func sidebarFocus(for group: String) -> String {
        switch group {
        case "basics": return "library"
        case "albums", "folders": return "albums"
        case "cloud", "catalog", "tv", "scenes": return group
        default: return "all"
        }
    }

    private static func sidebarShots(group: String, store: LibraryStore,
                                     catalog: CatalogBrowserModel,
                                     tv: IPTVBrowserModel) -> [SidebarShot] {
        switch group {
        case "basics":
            var items: [SidebarShot] = []
            for (index, row) in basicSidebarItems.enumerated() {
                items.append(SidebarShot(suffix: String(format: "basic-%02d-%@", index + 1, row.slug),
                                         title: row.title) {
                    store.navigate(to: row.item)
                })
            }
            return items
        case "albums":
            var items: [SidebarShot] = []
            for (index, album) in store.albums.enumerated() {
                items.append(SidebarShot(suffix: String(format: "album-%02d", index + 1),
                                         title: album.name) {
                    store.navigate(to: .album(album.id))
                })
            }
            for (index, album) in store.smartAlbums.enumerated() {
                items.append(SidebarShot(suffix: String(format: "smart-%02d", index + 1),
                                         title: album.name) {
                    store.navigate(to: .smartAlbum(album.id))
                })
            }
            return items
        case "folders":
            var items: [SidebarShot] = []
            for (index, folder) in store.folders.enumerated() {
                items.append(SidebarShot(suffix: String(format: "folder-%02d", index + 1),
                                         title: folder.name) {
                    store.navigate(to: .folder(folder.id))
                })
            }
            return items
        case "cloud":
            var items: [SidebarShot] = []
            for (index, mount) in store.cloudMounts.enumerated() {
                items.append(SidebarShot(suffix: String(format: "mount-%02d", index + 1),
                                         title: "\(mount.name) · 网盘") {
                    store.showCloudOverview(nil)
                    store.selectCloudFolder(path: nil)
                    store.navigate(to: .cloudMount(mount.id))
                })
                items.append(SidebarShot(suffix: String(format: "mount-%02d-cinema", index + 1),
                                         title: "\(mount.name) · 影院") {
                    store.activateCinemaScope(.mount(mount.id))
                    store.navigate(to: .cloudCinema(mount.id))
                })
            }
            if let mount = store.cloudMounts.first {
                for (index, node) in store.cloudRootFolders.enumerated() {
                    items.append(SidebarShot(suffix: String(format: "folder-%02d", index + 1),
                                             title: node.name) {
                        store.showCloudOverview(nil)
                        store.navigate(to: .cloudMount(mount.id))
                        store.selectCloudFolder(path: node.path)
                    })
                }
            }
            return items
        case "catalog":
            var items: [SidebarShot] = []
            for (index, source) in catalog.resourceSources.enumerated() {
                items.append(SidebarShot(suffix: String(format: "source-%02d", index + 1),
                                         title: source.name) {
                    store.sourceHub.activate(.catalog(source.id))
                    catalog.selectSource(source.id)
                    catalog.openHome()
                })
            }
            for (index, source) in catalog.cinemaSources.enumerated() {
                items.append(SidebarShot(suffix: String(format: "cinema-source-%02d", index + 1),
                                         title: source.name) {
                    store.networkCinemaSourceID = source.id
                    store.navigate(to: .networkCinema)
                })
            }
            return items
        case "tv":
            var items: [SidebarShot] = []
            for (index, playlist) in tv.playlists.enumerated() {
                items.append(SidebarShot(suffix: String(format: "source-%02d", index + 1),
                                         title: playlist.name) {
                    store.sourceHub.activate(.television(playlist.id))
                })
                for (groupIndex, category) in tv.categoryGroups(for: playlist.id).enumerated() {
                    items.append(SidebarShot(
                        suffix: String(format: "source-%02d-group-%02d", index + 1, groupIndex + 1),
                        title: "\(playlist.name) · \(category.group)") {
                        tv.focusGroup(category.group, in: playlist.id)
                        tv.setHubTab(.channels)
                        store.navigate(to: .iptv)
                    })
                }
            }
            return items
        case "scenes":
            let counts = store.sceneCounts
            var items: [SidebarShot] = []
            for (index, category) in SceneCatalog.categories.enumerated()
            where (counts[category.id] ?? 0) > 0 {
                items.append(SidebarShot(suffix: String(format: "scene-%02d", index + 1),
                                         title: category.title) {
                    store.navigate(to: .scene(category.id))
                })
            }
            return items
        default:
            return []
        }
    }

    // MARK: - 截图

    /// AI 智能助手的三种演示状态：欢迎页、正常对话、等待批准写操作。
    /// 用整页工作台（`.workspace`）呈现：并排侧栏在后台激活时会触发布局死循环。
    private static func presentAI(target: String?, store: LibraryStore) -> Bool {
        store.sidebarItem = .assistant
        store.aiSurfaceMode = .workspace
        switch target {
        case "welcome":
            store.aiMessages = []
            store.aiPendingApproval = nil
        case "chat":
            store.aiMessages = aiDemoMessages(store: store)
            store.aiPendingApproval = nil
        case "approval":
            store.aiMessages = aiDemoMessages(store: store)
            store.aiPendingApproval = AIApprovalRequest(
                title: "需要确认 3 项写操作",
                summary: "把 2026 年夏天的海边照片整理成相簿，并写入关键词。",
                items: [
                    AIApprovalItem(id: "album.create", title: "新建相簿「2026 夏天 · 海边」",
                                   detail: "图库 › 精选", risk: .reversible),
                    AIApprovalItem(id: "album.add", title: "加入 38 张照片",
                                   detail: "2026-07 三亚 / 万宁", risk: .reversible),
                    AIApprovalItem(id: "keywords.write", title: "写入关键词「海边」「亲子」",
                                   detail: "作用于这 38 张照片", risk: .reversible)
                ],
                toolNames: ["album_create", "album_add_photos", "metadata_write_keywords"],
                memorableToolNames: ["album_create", "album_add_photos", "metadata_write_keywords"])
        default:
            return false
        }
        return true
    }

    /// 一段固定的助手对话：覆盖提问、工具回执与最终回答，截图为文档服务。
    private static func aiDemoMessages(store: LibraryStore) -> [AIChatMessage] {
        [
            AIChatMessage(role: .user,
                          text: "帮我把 2026 年夏天在海边拍的照片整理成一个相簿，挑出最好的一批。"),
            AIChatMessage(role: .action,
                          text: "读取图库索引：共 \(store.photos.count) 项，筛出 2026-06 至 2026-09 的海景照片 128 张。"),
            AIChatMessage(role: .assistant,
                          text: "挑好 38 张：按清晰度、人脸与构图排序，去掉了连拍和闭眼。要我把它们放进新建的「2026 夏天 · 海边」相簿吗？",
                          elapsed: 6.4, toolSteps: 3),
            AIChatMessage(role: .action,
                          text: "已新建相簿「2026 夏天 · 海边」，并加入 38 张照片。"),
            AIChatMessage(role: .assistant,
                          text: "整理完成。相簿在「精选」文件夹下；之后也可以让我按同样的规则整理 2025 年的照片。",
                          elapsed: 2.1, toolSteps: 1)
        ]
    }

    private static func captureWindow(for screen: String) -> NSWindow? {
        if screen == "import.panel",
           let importWindow = NSApp.windows.first(where: { $0.isVisible && $0.title == "导入" }) {
            return importWindow
        }
        if screen.hasPrefix("assistant"),
           let sheet = mainWindow()?.attachedSheet {
            return sheet
        }
        if let sheet = mainWindow()?.attachedSheet { return sheet }
        return mainWindow()
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    private static func applyWindowSize(to window: NSWindow, env: [String: String]) {
        let raw = env["LUMA_TESTKIT_SIZE"] ?? "1440x900"
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 200, height > 200 else { return }
        let size = NSSize(width: width, height: height)
        guard abs(window.contentLayoutRect.width - width) > 4
                || abs(window.contentLayoutRect.height - height) > 4 else { return }
        window.setContentSize(size)
        window.center()
    }

    private static func capture(window: NSWindow, to url: URL) -> Bool {
        // 优先按窗口合成截图：侧边栏 / 工具栏里的 NSVisualEffectView 不会出现在
        // `cacheDisplay` 里，直接用窗口图像才能拿到完整界面。
        var rep: NSBitmapImageRep?
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                               CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) {
            rep = NSBitmapImageRep(cgImage: image)
        }
        if rep == nil, let view = window.contentView {
            let bounds = view.bounds
            guard bounds.width > 20, bounds.height > 20,
                  let cached = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
            view.cacheDisplay(in: bounds, to: cached)
            rep = cached
        }
        guard let rep,
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Diagnostics.record("TestKit：PNG 写入失败 \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 右键菜单

    /// 在窗口的相对位置模拟一次右键，等菜单展开后由后台线程截屏，再补一个 Esc 收起。
    ///
    /// SwiftUI 的 `contextMenu` 由宿主视图处理右键事件：自注入事件不需要辅助功能权限，
    /// 但菜单跟踪会占住主线程，所以截屏与关闭都必须放在后台线程。
    private static func captureContextMenu(in window: NSWindow, atFraction fraction: CGPoint,
                                           to url: URL) async -> Bool {
        let frame = window.frame
        let screenPoint = CGPoint(x: frame.minX + frame.width * fraction.x,
                                  y: frame.minY + frame.height * fraction.y)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                // 只发按下：补一个抬起有可能直接命中菜单项，误触发删除之类的动作。
                postMouse(.rightMouseDown, window: window, screenPoint: screenPoint)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
                _ = captureScreenArea(around: window, to: url)
                postEscape()
                continuation.resume()
            }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func postMouse(_ type: NSEvent.EventType, window: NSWindow,
                                  screenPoint: CGPoint) {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }

    /// 菜单跟踪循环里只有键盘事件能选中 / 取消，Esc 让它退出。
    private static func postEscape() {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                           context: nil,
                                           characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// 截「窗口 + 菜单」：右键菜单是独立窗口，只截窗口本身拿不到，
    /// 这里按屏幕区域截一块（菜单总在点击点附近，窗口范围足够覆盖）。
    private static func captureScreenArea(around window: NSWindow,
                                          padding: CGFloat = 8, to url: URL) -> Bool {
        let frame = window.frame
        let mainHeight = NSScreen.screens.map(\.frame.maxY).max() ?? frame.maxY
        let rect = CGRect(x: frame.minX - padding,
                          y: mainHeight - frame.maxY - padding,
                          width: frame.width + padding * 2,
                          height: frame.height + padding * 2)
        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly,
                                                  kCGNullWindowID, [.bestResolution]) else {
            Diagnostics.record("TestKit：菜单截图失败（屏幕区域不可读）")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Diagnostics.record("TestKit：菜单截图写入失败 \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 清单

    private static func writeManifests(_ captured: [[String: String]], to directory: URL, dataset: URL) {
        let index: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "dataset": dataset.path,
            "screens": captured
        ]
        if let data = try? JSONSerialization.data(withJSONObject: index,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        }

        var markdown = """
        # 产品截图清单

        > 由 `Tools/testkit` 自动生成。图片是真实应用界面，可直接用于官网与手册。

        | 页面 | 文件 | 说明 |
        | --- | --- | --- |
        """
        for item in captured {
            let id = item["id"] ?? "-"
            let file = item["file"] ?? "-"
            let title = item["title"] ?? id
            let note = item["note"] ?? ""
            markdown += "\n| \(title) | `\(file)` | \(note) |"
        }
        markdown += "\n"
        try? markdown.write(to: directory.appendingPathComponent("captures.md"),
                            atomically: true, encoding: .utf8)
    }

    // MARK: - 等待

    private static func waitUntil(timeout: TimeInterval,
                                  condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }
}
