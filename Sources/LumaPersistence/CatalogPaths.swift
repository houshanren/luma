import Foundation
import LumaDomain
import LumaCore
import CryptoKit

/// 网络资源（影视源）的海报缓存与数据库路径入口。
///
/// 放在服务层而不是 `Domain`：`Domain` 只放可序列化模型，不依赖 `LibraryPaths`。
/// 缓存目录统一挂在 `LibraryPaths.overlayRoot` 下，换图库时随图库迁移。
public enum CatalogPaths {
    public static var root: URL { LibraryPaths.overlayRoot.appendingPathComponent("catalog", isDirectory: true) }

    public static func artwork(scriptSourceID: UUID) -> URL {
        root.appendingPathComponent("artwork", isDirectory: true)
            .appendingPathComponent(scriptSourceID.uuidString, isDirectory: true)
    }

    public static func artworkURL(sourceID: UUID, urlString: String, quick: Bool) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let name = (quick ? "q-" : "") + String(digest.prefix(40)) + ".jpg"
        return artwork(scriptSourceID: sourceID).appendingPathComponent(name)
    }
}
