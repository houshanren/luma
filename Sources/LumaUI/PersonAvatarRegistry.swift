import AppKit
import LumaDomain

/// 人物头像取图出口：解码、缓存与「按 ID 查库」都留在 App 侧，
/// 组件只认这两个闭包。People / Revisit 独立成 target 后仍然可以编译，
/// 与 `MemoryFrameLoader` / `ThumbnailLoaderRegistry` 是同一套注入方式。
@MainActor
package enum PersonAvatarRegistry {
    /// 同步命中内存缓存（列表首帧用它避免闪白）。
    package static var cachedProvider: ((PersonAvatarRequest) -> NSImage?)?
    /// 异步解码：失败返回 nil，视图退回占位图标。
    package static var loadProvider: ((PersonAvatarRequest) async -> NSImage?)?

    package static func cached(_ request: PersonAvatarRequest) -> NSImage? {
        cachedProvider?(request)
    }

    package static func load(_ request: PersonAvatarRequest) async -> NSImage? {
        guard let loadProvider else { return nil }
        return await loadProvider(request)
    }
}
