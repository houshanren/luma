import Foundation

/// 网盘索引的扫描状态：属于展示与缓存判断用的 DTO，不绑定数据库实现。
public struct CloudIndexState {
    public var folderCount: Int
    public var mediaCount: Int
    public var truncated: Bool
    public var complete: Bool
    public var pathVersion: Int
    public var scopeSignature: String
    public var updatedAt: Date
    public init(
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
