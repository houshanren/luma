import Foundation

/// 网格缩略图上的信息浮层配置：由设置页开关，网格与列表共用同一份。
package struct MetadataOptions: Codable, Equatable {
    package var title = false
    package var capturedDate = false
    package var keywords = false
    package var edited = false
    package var fileType = false
    package var favorite = true
    package var location = false
    package var resolution = false
    package var fileSize = false
    package var camera = false
    package var source = false
    package var duration = true

    package init() {}

    /// 除「个人收藏」「视频时长」这类角标外，是否还有文字信息需要遮罩。
    package var hasTextOverlay: Bool {
        title || capturedDate || keywords || edited || fileType
            || location || resolution || fileSize || camera || source
    }
}

/// 双击照片时的打开方式。网格组件只负责按这个值回调，具体打开逻辑由宿主实现。
package enum PhotoOpenMode: String, CaseIterable, Identifiable {
    case viewer
    case editor
    case systemApp

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .viewer: return "在本 App 中查看"
        case .editor: return "直接进入编辑（仅照片）"
        case .systemApp: return "用系统默认应用打开"
        }
    }

    package var detail: String {
        switch self {
        case .viewer: return "双击照片打开查看器，视频直接播放。"
        case .editor: return "双击照片进入编辑；视频和只读项目仍用查看器。"
        case .systemApp: return "双击交给「预览」等默认应用；云端项目仍用查看器。"
        }
    }

    /// 设置卡片上的短标题与图标。
    package var shortTitle: String {
        switch self {
        case .viewer: return "App 内查看"
        case .editor: return "直接编辑"
        case .systemApp: return "系统应用"
        }
    }

    package var icon: String {
        switch self {
        case .viewer: return "eye"
        case .editor: return "slider.horizontal.3"
        case .systemApp: return "arrow.up.forward.app"
        }
    }
}

/// 网格堆叠角标：代表图 ID 对应的整组张数与是否连拍。
package struct PhotoStackBadge {
    package let count: Int
    package let isBurst: Bool

    package init(count: Int, isBurst: Bool) {
        self.count = count
        self.isBurst = isBurst
    }
}
