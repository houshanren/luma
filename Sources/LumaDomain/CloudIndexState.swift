import Foundation

/// 网盘索引的扫描状态：属于展示与缓存判断用的 DTO，不绑定数据库实现。
package struct CloudIndexState {
    package var folderCount: Int
    package var mediaCount: Int
    package var truncated: Bool
    package var complete: Bool
    package var pathVersion: Int
    package var scopeSignature: String
    package var updatedAt: Date
    package init(
        folderCount: Int,
        mediaCount: Int,
        truncated: Bool,
        complete: Bool,
        pathVersion: Int,
        scopeSignature: String,
        updatedAt: Date
    ) {
        self.folderCount = folderCount
        self.mediaCount = mediaCount
        self.truncated = truncated
        self.complete = complete
        self.pathVersion = pathVersion
        self.scopeSignature = scopeSignature
        self.updatedAt = updatedAt
    }
}
