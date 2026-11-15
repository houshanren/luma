import Foundation

/// 网盘浏览状态：挂载列表、当前目录、加载与弹窗状态。
/// 由 `LibraryStore` 持有并转发变更，后续可按需让网盘视图单独订阅。
final class CloudBrowserModel: ObservableObject {
    @Published var mounts: [CloudMount] = []
    @Published var folders: [CloudEntry] = []
    @Published var photos: [PhotoItem] = [] {
        didSet { revision &+= 1 }
    }
    /// 照片集合版本号：目录刷新、收藏切换等变化时自增，用于云网格筛选缓存失效。
    var revision = 0
    @Published var path: String = ""
    @Published var trail: [CloudCrumb] = []
    @Published var loading = false
    @Published var error: String?
    @Published var showSheet = false
    @Published var sheetMount: CloudMount?
    @Published var showWizard = false
    @Published var wizardInitialFlow: CloudWizardFlow?
    @Published var nameRequest: CloudNameRequest?
    @Published var busyText: String?

    // MARK: 浏览范围与端侧识别

    /// 当前网盘列表的范围（全部 / 视频 / 截屏 / 场景 / 包含文字…）。
    @Published var scope: CloudScope = .all
    /// 端侧识别结果：只保存在内存，切换网盘或换库时清空。
    @Published var analysis: [UUID: PhotoAnalysis] = [:]
    @Published var isAnalyzing = false
    @Published var analysisProgress = 0.0
    /// 当前识别结果属于哪个挂载；与打开中的挂载不一致时先清空再识别。
    var insightMountID: UUID?
    var analysisTask: Task<Void, Never>?
}
