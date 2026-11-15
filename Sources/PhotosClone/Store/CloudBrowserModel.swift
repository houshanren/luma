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
}
