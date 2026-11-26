import SwiftUI
import AppKit
import LumaDomain

/// 缩略图用途：按实际显示尺寸决定解码像素，避免一律解码 1200px。
package enum ThumbnailPurpose {
    /// 网格单元格：像素由格子尺寸推导，走“快速层 + 目标档位”两层加载。
    case grid(maxPixel: CGFloat)
    /// 封面、头像、卡片等按显示边长（pt）取图。
    case cover(CGFloat)
    /// 胶片条等小图，按显示高度（pt）取图。
    case filmstrip(CGFloat)
    /// 导入窗口预览。
    case preview(CGFloat)

    /// Retina 2x 估算，最终会被 ImageLoader 收敛到固定档位。
    package static let scale: CGFloat = 2

    package var maxPixel: CGFloat {
        switch self {
        case .grid(let pixels):
            return pixels
        case .cover(let side), .filmstrip(let side), .preview(let side):
            return side * Self.scale
        }
    }

    package var isTwoTier: Bool {
        if case .grid = self { return true }
        return false
    }
}

/// 取图管线的唯一出口。
///
/// 真正的缓存命中、快速层、目标档位解码与取消都留在 App 的 `PhotoThumbnailLoader`，
/// 由组合根在启动时注入；组件层只做一次间接调用，不感知 `LibraryStore`。
/// 这里刻意不使用 SwiftUI Environment：避免上游任意状态变化导致环境失效、
/// 让整棵缩略图子树重新求值，也不改变原有 `.task(id:)` 的取消与去重行为。
@MainActor
package enum ThumbnailLoaderRegistry {
    package static var load: ((PhotoItem, ThumbnailPurpose, (NSImage) -> Void) async -> NSImage?)?
}

/// 统一缩略图组件：异步加载、取消、缓存命中与“先低清后目标档位”的降级都不变。
package struct PhotoThumbnailView: View {
    package let photo: PhotoItem
    package let purpose: ThumbnailPurpose
    package let contentMode: ContentMode

    @State private var image: NSImage?
    @State private var didFail = false

    package init(photo: PhotoItem,
                 purpose: ThumbnailPurpose = .cover(220),
                 contentMode: ContentMode = .fill) {
        self.photo = photo
        self.purpose = purpose
        self.contentMode = contentMode
    }

    /// 与重构前完全一致：照片缓存键 + 目标档位 + 是否网盘。
    private var loadKey: String {
        "\(photo.cacheKey)|\(Int(purpose.maxPixel.rounded()))|\(photo.isCloud)"
    }

    package var body: some View {
        ZStack {
            // 与网格单元格一致的占位渐变，避免封面加载时是一块死灰。
            LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.22),
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.10)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if didFail || photo.isVideo {
                Image(systemName: photo.isVideo ? "video" : "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        didFail = false
        guard let loader = ThumbnailLoaderRegistry.load else {
            didFail = true
            return
        }
        let loaded = await loader(photo, purpose) { quick in
            image = quick
        }
        guard !Task.isCancelled else { return }
        // 目标档位失败时保留已经出图的快速层。
        if let loaded { image = loaded }
        didFail = image == nil
    }
}
