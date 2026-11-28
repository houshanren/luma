import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// 星图资料库（catalog.sqlite）的选择与加载状态。
///
/// 安装包不再内置这份数据库：默认没有资料库、星图入口完全不出现；
/// 用户必须从菜单「星图 › 加载星图资料库…」手动选一份，校验通过后入口才会出现。
/// 选择结果按路径保存在 UserDefaults，下次启动自动恢复；文件被移走则回到未加载。
@MainActor
@Observable
final class AtlasCatalogLibrary {
    static let shared = AtlasCatalogLibrary()

    private(set) var path: String?
    private(set) var isLoaded = false
    /// 最近一次加载失败的原因：弹窗提示用。
    private(set) var lastError: String?

    private init() {
        restore()
    }

    /// 启动时恢复上次选择：文件不存在或结构不对就视为未加载。
    func restore() {
        guard let saved = AtlasCatalogPaths.selectedPath else { return }
        if let error = AtlasCatalogValidator.validate(path: saved) {
            lastError = error
            AtlasCatalogPaths.clear()
            return
        }
        path = saved
        isLoaded = true
        CatalogAvatarStore.reset()
    }

    /// 加载一份 catalog.sqlite：校验通过才落地。
    @discardableResult
    func load(url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if let error = AtlasCatalogValidator.validate(path: resolved.path) {
            lastError = error
            return false
        }
        AtlasCatalogPaths.store(resolved.path)
        path = resolved.path
        lastError = nil
        isLoaded = true
        CatalogAvatarStore.reset()
        return true
    }

    /// 卸载：星图入口与搜索来源一起消失，资料库文件本身不动。
    func unload() {
        AtlasCatalogPaths.clear()
        path = nil
        isLoaded = false
        lastError = nil
        CatalogAvatarStore.reset()
    }

    /// 菜单入口：选文件 → 校验 → 加载；失败直接弹窗说明原因。
    func presentPicker() {
        let panel = NSOpenPanel()
        panel.title = "选择星图资料库"
        panel.message = "选择拾光星图的 catalog.sqlite（内置人物 / 作品资料库）。"
        panel.prompt = "加载"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let sqlite = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqlite, .database]
        }
        if let path {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !load(url: url) {
            presentError(lastError ?? "加载失败，请换一份 catalog.sqlite 再试。")
        }
    }

    func revealInFinder() {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法加载星图资料库"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - 非隔离查询

/// 路径与可用性的非隔离入口：搜索来源判断、数据库层打开都从这里取，
/// 避免在非 MainActor 上下文里访问 `AtlasCatalogLibrary`。
enum AtlasCatalogPaths {
    static let defaultsKey = "atlas.catalogPath"

    static var selectedPath: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    /// 只判断文件是否还在；结构问题由 `AtlasCatalogValidator` 负责。
    static var isLoaded: Bool {
        guard let selectedPath else { return false }
        return FileManager.default.fileExists(atPath: selectedPath)
    }

    static func store(_ path: String) {
        UserDefaults.standard.set(path, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// 校验一份 catalog.sqlite 是否为星图资料库：返回 nil 表示可用，否则是给用户看的原因。
enum AtlasCatalogValidator {
    static func validate(path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return "文件不存在，或者已经被移动到别的位置。"
        }
        guard let database = try? SQLiteDatabase(path: path, readonly: true, wal: false) else {
            return "无法以只读方式打开这个文件，确认它是 SQLite 数据库。"
        }
        guard let people = try? database.query("SELECT COUNT(*) AS n FROM actresses"),
              (people.first?["n"]?.int64 ?? 0) > 0 else {
            return "这不是拾光星图资料库：缺少 actresses（人物）数据。"
        }
        guard let works = try? database.query("SELECT COUNT(*) AS n FROM works"),
              (works.first?["n"]?.int64 ?? 0) > 0 else {
            return "这不是拾光星图资料库：缺少 works（作品）数据。"
        }
        return nil
    }
}
