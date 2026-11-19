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

    /// 查看器底部是否显示缩略图胶片条。
    @Published var viewerFilmstrip: Bool {
        didSet { UserDefaults.standard.set(viewerFilmstrip, forKey: SettingsKeys.viewerFilmstrip) }
    }

    /// 查看器是否用当前照片的模糊影像铺满舞台背景（关闭后为纯色，翻页更省资源）。
    @Published var viewerBackdrop: Bool {
        didSet { UserDefaults.standard.set(viewerBackdrop, forKey: SettingsKeys.viewerBackdrop) }
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

    /// 新打开的图片列表（照片网格）默认每行几张；已单独调整过的页面保持各自记忆。
    @Published var defaultGridColumns: Int {
        didSet { UserDefaults.standard.set(defaultGridColumns, forKey: SettingsKeys.defaultGridColumns) }
    }

    /// 相簿 / 媒体类型 / 场景 / 更多项目等卡片墙默认每行几个。
    @Published var defaultCardColumns: Int {
        didSet { UserDefaults.standard.set(defaultCardColumns, forKey: SettingsKeys.defaultCardColumns) }
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

    /// 视频查看器里 ↑ / ↓ 快进快退的步长（秒）。
    @Published var videoSeekStep: Double {
        didSet { UserDefaults.standard.set(videoSeekStep, forKey: SettingsKeys.videoSeekStep) }
    }

    /// 视频控制条的位置：底部悬浮，或融合进画面上方的顶栏。
    @Published var videoControlPlacement: VideoControlPlacement {
        didSet {
            UserDefaults.standard.set(videoControlPlacement.rawValue,
                                      forKey: SettingsKeys.videoControlPlacement)
        }
    }

    /// 视频转码 / 边下边播缓存容量上限（GB）；超过后按最近最少使用淘汰。
    @Published var videoCacheLimitGB: Int {
        didSet { UserDefaults.standard.set(videoCacheLimitGB, forKey: SettingsKeys.videoCacheLimitGB) }
    }

    /// 外挂字幕字号。
    @Published var subtitleFontSize: Double {
        didSet { UserDefaults.standard.set(subtitleFontSize, forKey: SettingsKeys.subtitleFontSize) }
    }

    /// 外挂字幕是否显示半透明底色。
    @Published var subtitleBackground: Bool {
        didSet { UserDefaults.standard.set(subtitleBackground, forKey: SettingsKeys.subtitleBackground) }
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

    /// 导入时跳过字节完全相同的文件。（随图库保存）
    @Published var importSkipExactDuplicates: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importSkipDuplicates, importSkipExactDuplicates) }
    }

    /// 导入完成后重新校验目标文件哈希。（随图库保存）
    @Published var importVerifyCopies: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importVerifyCopies, importVerifyCopies) }
    }

    /// 网格缩略图上显示的元数据。（随图库保存）
    @Published var metadata: MetadataOptions {
        didSet { persistLibraryJSON(SettingsKeys.metadata, metadata) }
    }

    // MARK: 影院刮削

    /// 刮削数据源：TMDB（官方 API）或豆瓣（非官方公开接口）。
    @Published var cinemaProvider: CinemaProvider {
        didSet { UserDefaults.standard.set(cinemaProvider.rawValue, forKey: SettingsKeys.cinemaProvider) }
    }

    /// TMDB API Key（v3）或 Read Access Token（v4，以 eyJ 开头）。
    @Published var cinemaAPIKey: String {
        didSet { UserDefaults.standard.set(cinemaAPIKey, forKey: SettingsKeys.cinemaAPIKey) }
    }

    /// 刮削语言，如 zh-CN / en-US / ja-JP。
    @Published var cinemaLanguage: String {
        didSet { UserDefaults.standard.set(cinemaLanguage, forKey: SettingsKeys.cinemaLanguage) }
    }

    /// TMDB API 地址，可替换为镜像 / 代理。
    @Published var cinemaAPIBase: String {
        didSet { UserDefaults.standard.set(cinemaAPIBase, forKey: SettingsKeys.cinemaAPIBase) }
    }

    /// 海报与背景图地址前缀，默认 image.tmdb.org。
    @Published var cinemaImageBase: String {
        didSet { UserDefaults.standard.set(cinemaImageBase, forKey: SettingsKeys.cinemaImageBase) }
    }

    /// 进入影院或扫描完网盘后自动刮削新视频。
    @Published var cinemaAutoScrape: Bool {
        didSet { UserDefaults.standard.set(cinemaAutoScrape, forKey: SettingsKeys.cinemaAutoScrape) }
    }

    /// 豆瓣接口地址，可换成镜像 / 反代前缀。
    @Published var cinemaDoubanBase: String {
        didSet { UserDefaults.standard.set(cinemaDoubanBase, forKey: SettingsKeys.cinemaDoubanBase) }
    }

    /// 可选的豆瓣登录 Cookie，用于降低被限流的概率。
    @Published var cinemaDoubanCookie: String {
        didSet { UserDefaults.standard.set(cinemaDoubanCookie, forKey: SettingsKeys.cinemaDoubanCookie) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: SettingsKeys.appearance) ?? "") ?? .system
        accent = AppAccent(rawValue: defaults.string(forKey: SettingsKeys.accent) ?? "") ?? .system
        photoOpenMode = PhotoOpenMode(rawValue: defaults.string(forKey: SettingsKeys.photoOpenMode) ?? "") ?? .viewer
        viewerLayout = ViewerLayout(rawValue: defaults.string(forKey: SettingsKeys.viewerLayout) ?? "") ?? .window
        showInfoOnOpen = defaults.bool(forKey: SettingsKeys.showInfoOnOpen)
        viewerFilmstrip = defaults.object(forKey: SettingsKeys.viewerFilmstrip) as? Bool ?? false
        viewerBackdrop = defaults.object(forKey: SettingsKeys.viewerBackdrop) as? Bool ?? true
        motion = MotionPreset(rawValue: defaults.string(forKey: SettingsKeys.motion) ?? "") ?? .silky
        cardCornerRadius = defaults.object(forKey: SettingsKeys.cardCornerRadius) as? Double ?? 14
        hoverLift = defaults.object(forKey: SettingsKeys.hoverLift) as? Bool ?? true
        defaultGridColumns = defaults.object(forKey: SettingsKeys.defaultGridColumns) as? Int ?? 8
        defaultCardColumns = defaults.object(forKey: SettingsKeys.defaultCardColumns) as? Int ?? 5
        autoPlayVideo = defaults.object(forKey: SettingsKeys.autoPlayVideo) as? Bool ?? true
        autoPlayNextVideo = defaults.object(forKey: SettingsKeys.autoPlayNextVideo) as? Bool ?? true
        viewFullHDR = defaults.object(forKey: SettingsKeys.viewFullHDR) as? Bool ?? true
        muteVideoByDefault = defaults.object(forKey: SettingsKeys.videoMuted) as? Bool ?? false
        loopVideoByDefault = defaults.object(forKey: SettingsKeys.videoLoop) as? Bool ?? false
        videoSeekStep = defaults.object(forKey: SettingsKeys.videoSeekStep) as? Double ?? 5
        videoControlPlacement = VideoControlPlacement(
            rawValue: defaults.string(forKey: SettingsKeys.videoControlPlacement) ?? "") ?? .topIntegrated
        videoCacheLimitGB = defaults.object(forKey: SettingsKeys.videoCacheLimitGB) as? Int ?? 20
        subtitleFontSize = defaults.object(forKey: SettingsKeys.subtitleFontSize) as? Double ?? 15
        subtitleBackground = defaults.object(forKey: SettingsKeys.subtitleBackground) as? Bool ?? true
        // 默认豆瓣：免 Key，开箱即可刮削。
        cinemaProvider = CinemaProvider(rawValue: defaults.string(forKey: SettingsKeys.cinemaProvider) ?? "") ?? .douban
        cinemaAPIKey = defaults.string(forKey: SettingsKeys.cinemaAPIKey) ?? ""
        cinemaLanguage = defaults.string(forKey: SettingsKeys.cinemaLanguage) ?? "zh-CN"
        cinemaAPIBase = defaults.string(forKey: SettingsKeys.cinemaAPIBase) ?? "https://api.themoviedb.org/3"
        cinemaImageBase = defaults.string(forKey: SettingsKeys.cinemaImageBase) ?? "https://image.tmdb.org/t/p"
        cinemaAutoScrape = defaults.object(forKey: SettingsKeys.cinemaAutoScrape) as? Bool ?? true
        cinemaDoubanBase = defaults.string(forKey: SettingsKeys.cinemaDoubanBase) ?? "https://movie.douban.com"
        cinemaDoubanCookie = defaults.string(forKey: SettingsKeys.cinemaDoubanCookie) ?? ""
        trashRetentionDays = defaults.object(forKey: SettingsKeys.trashRetentionDays) as? Int ?? 30
        importCreateAlbumsFromFolders = defaults.object(forKey: SettingsKeys.importCreateAlbums) as? Bool ?? true
        importPreserveFolderStructure = defaults.object(forKey: SettingsKeys.importPreserveStructure) as? Bool ?? true
        importSkipExactDuplicates = defaults.object(forKey: SettingsKeys.importSkipDuplicates) as? Bool ?? true
        importVerifyCopies = defaults.object(forKey: SettingsKeys.importVerifyCopies) as? Bool ?? true
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
        importSkipExactDuplicates = libraryBool(SettingsKeys.importSkipDuplicates, fallback: true)
        importVerifyCopies = libraryBool(SettingsKeys.importVerifyCopies, fallback: true)
        trashRetentionDays = libraryInt(SettingsKeys.trashRetentionDays, fallback: 30)
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
