import SwiftUI
import AppKit

final class AppSettings: ObservableObject {
    /// 全局唯一实例；服务层（如 LibraryStore）读取业务设置时使用，避免绕过设置模型。
    static let shared = AppSettings()

    /// 当前图库设置表的读写入口，由 LibraryStore 在打开/切换图库时注入。
    /// 图库级设置随图库保存；为 nil 时（尚未打开图库）退回 UserDefaults。
    var libraryReader: ((String) -> String?)?
    var libraryWriter: ((String, String?) -> Void)?
    /// 正在把图库里的值灌回属性时，跳过写回，避免无意义的重写。
    private var isApplyingLibraryScope = false

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: SettingsKeys.appearance) }
    }

    @Published var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: SettingsKeys.accent) }
    }

    @Published var photoOpenMode: PhotoOpenMode {
        didSet { UserDefaults.standard.set(photoOpenMode.rawValue, forKey: SettingsKeys.photoOpenMode) }
    }

    /// 查看器的呈现方式（窗口内 / 全屏）。
    @Published var viewerLayout: ViewerLayout {
        didSet { UserDefaults.standard.set(viewerLayout.rawValue, forKey: SettingsKeys.viewerLayout) }
    }

    @Published var showInfoOnOpen: Bool {
        didSet { UserDefaults.standard.set(showInfoOnOpen, forKey: SettingsKeys.showInfoOnOpen) }
    }

    @Published var motion: MotionPreset {
        didSet { UserDefaults.standard.set(motion.rawValue, forKey: SettingsKeys.motion) }
    }

    @Published var cardCornerRadius: Double {
        didSet { UserDefaults.standard.set(cardCornerRadius, forKey: SettingsKeys.cardCornerRadius) }
    }

    @Published var hoverLift: Bool {
        didSet { UserDefaults.standard.set(hoverLift, forKey: SettingsKeys.hoverLift) }
    }

    @Published var autoPlayVideo: Bool {
        didSet { UserDefaults.standard.set(autoPlayVideo, forKey: SettingsKeys.autoPlayVideo) }
    }

    @Published var viewFullHDR: Bool {
        didSet { UserDefaults.standard.set(viewFullHDR, forKey: SettingsKeys.viewFullHDR) }
    }

    /// 视频默认以静音状态开始播放。
    @Published var muteVideoByDefault: Bool {
        didSet { UserDefaults.standard.set(muteVideoByDefault, forKey: SettingsKeys.videoMuted) }
    }

    /// 视频播放结束后自动连播下一个视频（跳过照片）。
    @Published var autoPlayNextVideo: Bool {
        didSet { UserDefaults.standard.set(autoPlayNextVideo, forKey: SettingsKeys.autoPlayNextVideo) }
    }

    /// 视频默认循环播放。
    @Published var loopVideoByDefault: Bool {
        didSet { UserDefaults.standard.set(loopVideoByDefault, forKey: SettingsKeys.videoLoop) }
    }

    /// 「最近删除」自动清理的保留天数；0 表示不自动清理。（随图库保存）
    @Published var trashRetentionDays: Int {
        didSet { persistLibraryInt(SettingsKeys.trashRetentionDays, trashRetentionDays) }
    }

    /// 导入时把文件夹末级目录创建为相簿。（随图库保存）
    @Published var importCreateAlbumsFromFolders: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importCreateAlbums, importCreateAlbumsFromFolders) }
    }

    /// 导入时保留上层文件夹结构。（随图库保存）
    @Published var importPreserveFolderStructure: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importPreserveStructure, importPreserveFolderStructure) }
    }

    /// 系统「照片」图库一次最多载入的项数；0 表示不限制（超大图库不推荐）。（随图库保存）
    @Published var systemLibraryMaxAssets: Int {
        didSet { persistLibraryInt(SettingsKeys.systemLibraryMaxAssets, systemLibraryMaxAssets) }
    }

    /// 网格缩略图上显示的元数据。（随图库保存）
    @Published var metadata: MetadataOptions {
        didSet { persistLibraryJSON(SettingsKeys.metadata, metadata) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: SettingsKeys.appearance) ?? "") ?? .system
        accent = AppAccent(rawValue: defaults.string(forKey: SettingsKeys.accent) ?? "") ?? .system
        photoOpenMode = PhotoOpenMode(rawValue: defaults.string(forKey: SettingsKeys.photoOpenMode) ?? "") ?? .viewer
        viewerLayout = ViewerLayout(rawValue: defaults.string(forKey: SettingsKeys.viewerLayout) ?? "") ?? .window
        showInfoOnOpen = defaults.bool(forKey: SettingsKeys.showInfoOnOpen)
        motion = MotionPreset(rawValue: defaults.string(forKey: SettingsKeys.motion) ?? "") ?? .silky
        cardCornerRadius = defaults.object(forKey: SettingsKeys.cardCornerRadius) as? Double ?? 14
        hoverLift = defaults.object(forKey: SettingsKeys.hoverLift) as? Bool ?? true
        autoPlayVideo = defaults.object(forKey: SettingsKeys.autoPlayVideo) as? Bool ?? true
        autoPlayNextVideo = defaults.object(forKey: SettingsKeys.autoPlayNextVideo) as? Bool ?? true
        viewFullHDR = defaults.object(forKey: SettingsKeys.viewFullHDR) as? Bool ?? true
        muteVideoByDefault = defaults.object(forKey: SettingsKeys.videoMuted) as? Bool ?? false
        loopVideoByDefault = defaults.object(forKey: SettingsKeys.videoLoop) as? Bool ?? false
        trashRetentionDays = defaults.object(forKey: SettingsKeys.trashRetentionDays) as? Int ?? 30
        importCreateAlbumsFromFolders = defaults.object(forKey: SettingsKeys.importCreateAlbums) as? Bool ?? true
        importPreserveFolderStructure = defaults.object(forKey: SettingsKeys.importPreserveStructure) as? Bool ?? true
        systemLibraryMaxAssets = defaults.object(forKey: SettingsKeys.systemLibraryMaxAssets) as? Int ?? 100_000
        if let data = defaults.data(forKey: SettingsKeys.metadata),
           let decoded = try? JSONDecoder().decode(MetadataOptions.self, from: data) {
            metadata = decoded
            // 旧版默认会把标题/关键词/文件类型等文字叠在缩略图上；
            // 若用户从未改动过（仍是旧默认组合），这里一次性收起，避免网格过于拥挤。
            if metadata.title, metadata.keywords, metadata.edited,
               metadata.fileType, metadata.location, !metadata.resolution,
               !metadata.fileSize, !metadata.camera, !metadata.source,
               !metadata.capturedDate {
                metadata = MetadataOptions()
            }
        } else {
            metadata = MetadataOptions()
        }
    }

    /// 从当前图库读取图库级设置；缺少的键使用默认值，避免把上一个图库的值带过来。
    func reloadLibraryScopedValues() {
        guard libraryReader != nil else { return }
        isApplyingLibraryScope = true
        defer { isApplyingLibraryScope = false }
        importCreateAlbumsFromFolders = libraryBool(SettingsKeys.importCreateAlbums, fallback: true)
        importPreserveFolderStructure = libraryBool(SettingsKeys.importPreserveStructure, fallback: true)
        trashRetentionDays = libraryInt(SettingsKeys.trashRetentionDays, fallback: 30)
        systemLibraryMaxAssets = libraryInt(SettingsKeys.systemLibraryMaxAssets, fallback: 100_000)
        metadata = libraryDecoded(SettingsKeys.metadata, as: MetadataOptions.self) ?? MetadataOptions()
    }

    private func libraryBool(_ key: String, fallback value: Bool) -> Bool {
        guard let raw = libraryReader?(key) else { return value }
        return raw == "1" || raw.lowercased() == "true"
    }

    private func libraryInt(_ key: String, fallback value: Int) -> Int {
        guard let raw = libraryReader?(key), let int = Int(raw) else { return value }
        return int
    }

    private func libraryDecoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let raw = libraryReader?(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func persistLibraryFlag(_ key: String, _ value: Bool) {
        guard !isApplyingLibraryScope else { return }
        if libraryWriter != nil {
            libraryWriter?(key, value ? "1" : "0")
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func persistLibraryInt(_ key: String, _ value: Int) {
        guard !isApplyingLibraryScope else { return }
        if libraryWriter != nil {
            libraryWriter?(key, String(value))
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func persistLibraryJSON<T: Encodable>(_ key: String, _ value: T) {
        guard !isApplyingLibraryScope else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        if libraryWriter != nil {
            libraryWriter?(key, String(data: data, encoding: .utf8))
        } else {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var cardRadius: CGFloat { CGFloat(cardCornerRadius) }

    /// 全 App 的统一强调色：控件 tint 与 `Color.accentColor`（选中框、高亮、强调文字）都用它。
    var accentColor: Color { accent.color ?? .accentColor }

    /// 侧边栏的小封面按比例缩小圆角，避免 18pt 图标过于圆。
    var smallCoverRadius: CGFloat { min(8, max(2, CGFloat(cardCornerRadius) * 0.45)) }
}
