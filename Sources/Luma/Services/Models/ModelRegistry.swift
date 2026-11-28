import Foundation

/// 可以独立安装 / 停用的本机模型能力。
enum ModelComponentID: String, CaseIterable, Identifiable {
    case siglip2 = "siglip2"
    case localLLM = "local-llm"

    var id: String { rawValue }
}

struct ModelComponentDescriptor: Identifiable {
    let id: ModelComponentID
    /// 解析模型文件时使用的目录名（`Models/<directoryName>/...`）。
    let directoryName: String
    let title: String
    let detail: String
    let approxSize: String
    /// 安装包解压后必须存在的文件，用来拒绝残缺包。
    let requiredEntries: [String]
    /// 运行时是否已经接入。未接入的组件只占位，不允许下载。
    let installable: Bool
    let note: String?
}

/// 模型资产注册表：统一的磁盘解析顺序、安装状态与内存占用查询。
///
/// 解析顺序（先命中先返回）：
/// 1. `~/Library/Application Support/Luma/Models`：用户下载的组件；
/// 2. App 包内 `Contents/Resources/Models`：随包内置的小模型（YOLO、地点库）；
/// 3. 源码目录 `Resources/Models`：仅开发期 `swift run` 使用。
///
/// 模型放在应用目录而不是图库目录，避免图库迁移 / 备份时把几个 GB 一起搬走。
enum ModelRegistry {
    static let catalog: [ModelComponentDescriptor] = [
        ModelComponentDescriptor(
            id: .siglip2,
            directoryName: "SigLIP2",
            title: "图像理解（SigLIP2）",
            detail: "自动标签 · 场景分类 · 相似照片 · 语义搜索扩展",
            approxSize: "约 355 MB",
            requiredEntries: [
                "ImageEncoder.mlmodelc",
                "TextEncoder.mlmodelc",
                "tags.json",
                "tag_embeddings.bin",
                "tokenizer_meta.json",
                "tokenizer_vocab.bin",
                "tokenizer_merges.bin"
            ],
            installable: true,
            note: "模型来自国内镜像 hf-mirror.net / hf-mirror.com（Apache-2.0），分片并发下载、支持断点续传；安装时在本机编译为 Core ML。需要 macOS 15 以上，未安装时自动回退到 Apple Vision 分类器。"
        ),
        ModelComponentDescriptor(
            id: .localLLM,
            directoryName: "LocalLLM",
            title: "本地语言模型",
            detail: "自然语言检索 · 智能相簿生成",
            approxSize: "运行时约 180 MB + 模型 1–6 GB",
            requiredEntries: [],
            installable: false,
            note: "点开关会自动下载 Ollama 运行时与 Qwen 模型并启动本机服务；Qwen2.5-VL 3B 与 Qwen3-VL 档能看图，可用于照片与事件理解。全程不联网推理，也可在下方连接已安装的 Ollama / LM Studio。"
        )
    ]

    static var modelsRoot: URL {
        LibraryPaths.applicationRoot.appendingPathComponent("Models", isDirectory: true)
    }

    /// 解压与替换用的临时目录，和正式目录同一块盘，保证 rename 是原子操作。
    static var stagingRoot: URL {
        modelsRoot.appendingPathComponent(".staging", isDirectory: true)
    }

    static var downloadsRoot: URL {
        modelsRoot.appendingPathComponent(".downloads", isDirectory: true)
    }

    private static let resourceRoots: [URL] = {
        var roots: [URL] = [modelsRoot]
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models", isDirectory: true) {
            roots.append(bundled)
        }
        // 只有 `swift run` 这类非 App 包才回退读仓库里的模型；
        // 正式包必须走「下载目录 + App 内置」，否则开关形同虚设。
        if Bundle.main.bundleURL.pathExtension.lowercased() != "app" {
            roots.append(sourceModelsRoot)
        }
        return roots
    }()

    /// 开发期直接 `swift run` 时没有资源副本，回退到仓库里的 `Resources/Models`。
    private static var sourceModelsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Models
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // Luma
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根目录
            .appendingPathComponent("Resources/Models", isDirectory: true)
    }

    /// 随 App 内置的清单：模型源地址变化时只需要更新清单文件，不需要重新下载几百 MB。
    static func bundledManifestData() -> Data? {
        bundledResourceURL("manifest.json").flatMap { try? Data(contentsOf: $0) }
    }

    /// 读取随包分发的 `Resources/Models` 资源（清单、本地模型源配置等）：
    /// 先找 App 包内副本，开发期 `swift run` 再回退仓库目录。
    static func bundledResourceURL(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models/\(name)", isDirectory: false) {
            candidates.append(bundled)
        }
        if Bundle.main.bundleURL.pathExtension.lowercased() != "app" {
            candidates.append(sourceModelsRoot.appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 词表、标签向量与分词器随 App 内置（约 9MB），下载的只有两个编码器。
    static var bundledAssetsDirectory: URL? {
        resolve("SigLIP2Assets")
    }

    /// 已安装模型目录里的「轻资产」需要随 App 升级刷新：
    /// 用户下载过 SigLIP2 后，模型目录优先于 App 包，旧版 tags.json 会把新标签永远挡在外面。
    /// 只同步词表 / 标签 / 分词器，不碰两个编码器；按 tags.json 的 version 判断，版本不涨就不复制。
    static func syncBundledTagAssetsIfNeeded() {
        let fileManager = FileManager.default
        guard let bundled = bundledAssetsDirectory else { return }
        let installed = modelsRoot.appendingPathComponent("SigLIP2", isDirectory: true)
        guard fileManager.fileExists(atPath: installed.appendingPathComponent("ImageEncoder.mlmodelc").path) else {
            return
        }
        let bundledTags = bundled.appendingPathComponent("tags.json")
        let installedTags = installed.appendingPathComponent("tags.json")
        guard tagAssetVersion(bundledTags) > tagAssetVersion(installedTags) else { return }

        let names = [
            "tags.json",
            "tag_embeddings.bin",
            "tokenizer_meta.json",
            "tokenizer_vocab.bin",
            "tokenizer_merges.bin"
        ]
        for name in names {
            let source = bundled.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = installed.appendingPathComponent(name)
            let temporary = installed.appendingPathComponent(".\(name).sync")
            do {
                try? fileManager.removeItem(at: temporary)
                try fileManager.copyItem(at: source, to: temporary)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: destination)
                }
            } catch {
                Diagnostics.record("SigLIP2 资产升级失败：\(name) \(error.localizedDescription)")
                try? fileManager.removeItem(at: temporary)
            }
        }
    }

    private static func tagAssetVersion(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        return object["version"] as? Int ?? 1
    }

    static func descriptor(_ id: ModelComponentID) -> ModelComponentDescriptor? {
        catalog.first { $0.id == id }
    }

    /// 组件在当前系统上是否可以安装。
    /// SigLIP2 的 Core ML 模型由 macOS 15 的转换工具产出，低版本系统装上也加载不了。
    static func isInstallable(_ id: ModelComponentID) -> Bool {
        guard let descriptor = descriptor(id), descriptor.installable else { return false }
        if id == .siglip2 {
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
            )
        }
        return true
    }

    /// 按优先级在三个根目录里找相对路径；返回的是真实存在的 URL。
    static func resolve(_ relative: String) -> URL? {
        for root in resourceRoots {
            let url = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func directoryURL(for id: ModelComponentID) -> URL? {
        guard let descriptor = descriptor(id) else { return nil }
        return resolve(descriptor.directoryName)
    }

    /// 文件是否齐备。内置或开发目录里的模型同样算已安装。
    static func isInstalled(_ id: ModelComponentID) -> Bool {
        directoryURL(for: id) != nil
    }

    /// 用户是否启用该能力。首次读取时按“文件是否存在”推断：
    /// 老用户（模型已随包内置）保持原行为，全新安装（没有文件）默认关闭。
    static func isEnabled(_ id: ModelComponentID) -> Bool {
        let key = SettingsKeys.modelEnabled(id.rawValue)
        if let stored = UserDefaults.standard.object(forKey: key) as? Bool {
            return stored
        }
        return isInstalled(id)
    }

    static func setEnabled(_ enabled: Bool, for id: ModelComponentID) {
        UserDefaults.standard.set(enabled, forKey: SettingsKeys.modelEnabled(id.rawValue))
    }

    /// 已安装版本：下载安装的读 `.ready` 标记，内置的显示「内置」。
    static func installedVersion(_ id: ModelComponentID) -> String? {
        guard let directory = directoryURL(for: id) else { return nil }
        let marker = directory.appendingPathComponent(".ready")
        if let data = try? Data(contentsOf: marker),
           let ready = try? JSONDecoder().decode(ModelReadyMarker.self, from: data) {
            return ready.version
        }
        return "内置"
    }

    /// 是否由用户下载而来（只有这种才能删除）。
    static func isRemovable(_ id: ModelComponentID) -> Bool {
        guard let directory = directoryURL(for: id) else { return false }
        let root = modelsRoot.standardizedFileURL.path
        return directory.standardizedFileURL.path.hasPrefix(root + "/")
    }

    /// 组件目录的实际占用（用于设置页显示与删除提示）。
    static func sizeOnDisk(_ id: ModelComponentID) -> Int64 {
        guard let directory = directoryURL(for: id) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                             includingPropertiesForKeys: Array(keys),
                                                             options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// 模型资源定位：保留旧的调用签名，内部走 `ModelRegistry` 的统一解析顺序。
enum LumaModelResources {
    static func directory(_ relative: String) -> URL? {
        ModelRegistry.resolve(relative)
    }

    static func file(_ relative: String) -> URL? {
        ModelRegistry.resolve(relative)
    }
}
