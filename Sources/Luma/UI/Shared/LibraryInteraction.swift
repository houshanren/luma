import Foundation
import UniformTypeIdentifiers

/// 打开文件 / 目录面板的参数。
struct LibraryOpenPanelRequest {
    var message: String?
    var prompt: String?
    var allowsMultipleSelection = false
    var canChooseFiles = true
    var canChooseDirectories = false
    var canCreateDirectories = false
    var treatsFilePackagesAsDirectories = true
    var allowedContentTypes: [UTType] = []
    var directoryURL: URL?
}

/// 保存面板的参数。
struct LibrarySavePanelRequest {
    var title: String?
    var message: String?
    var prompt: String?
    var nameFieldStringValue = ""
    var canCreateDirectories = true
    var isExtensionHidden: Bool?
    var directoryURL: URL?
}

enum LibraryAlertStyle {
    case informational
    case warning
}

/// 确认 / 提示弹窗的参数。
struct LibraryAlertRequest {
    var title: String
    var message: String
    var style: LibraryAlertStyle = .informational
    var buttons: [String] = ["好"]
}

/// Store 需要的用户交互端口。
/// 具体弹窗由视图层实现并注入，Store 不再直接创建 `NSOpenPanel` / `NSAlert`。
/// 方法必须在主线程调用，与原有 AppKit 弹窗的行为一致。
protocol LibraryUserInteraction {
    func chooseURLs(_ request: LibraryOpenPanelRequest) -> [URL]
    func chooseSaveURL(_ request: LibrarySavePanelRequest) -> URL?
    /// 返回用户点下的按钮下标；没有可用按钮时返回 nil。
    func presentAlert(_ request: LibraryAlertRequest) -> Int?
}

extension LibraryStore {
    func chooseURLs(_ request: LibraryOpenPanelRequest) -> [URL] {
        userInteraction?.chooseURLs(request) ?? []
    }

    func chooseSaveURL(_ request: LibrarySavePanelRequest) -> URL? {
        userInteraction?.chooseSaveURL(request)
    }

    @discardableResult
    func presentAlert(_ request: LibraryAlertRequest) -> Int? {
        userInteraction?.presentAlert(request)
    }
}
