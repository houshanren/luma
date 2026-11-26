import Foundation

public struct ImportOptions {
    public var createAlbumsFromFolders: Bool = true
    public var preserveFolderStructure: Bool = true
    public var targetAlbumID: UUID?
    /// 导入前计算 SHA-256，跳过与图库中已有文件字节完全相同的项目。
    public var skipExactDuplicates: Bool = true
    /// 复制完成后重新计算目标文件哈希，确认写入完整。
    public var verifyCopies: Bool = true
    public init(
        createAlbumsFromFolders: Bool = true,
        preserveFolderStructure: Bool = true,
        targetAlbumID: UUID? = nil,
        skipExactDuplicates: Bool = true,
        verifyCopies: Bool = true
    ) {
        self.createAlbumsFromFolders = createAlbumsFromFolders
        self.preserveFolderStructure = preserveFolderStructure
        self.targetAlbumID = targetAlbumID
        self.skipExactDuplicates = skipExactDuplicates
        self.verifyCopies = verifyCopies
    }
}

public struct ImportProgress {
    public var total: Int
    public var completed: Int
    public var currentName: String
    public var importedCount: Int = 0
    public var skippedDuplicates: Int = 0
    public var failedCount: Int = 0
    public var verifiedCount: Int = 0
    public var isCancelled: Bool = false

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
    public init(
        total: Int,
        completed: Int,
        currentName: String,
        importedCount: Int = 0,
        skippedDuplicates: Int = 0,
        failedCount: Int = 0,
        verifiedCount: Int = 0,
        isCancelled: Bool = false
    ) {
        self.total = total
        self.completed = completed
        self.currentName = currentName
        self.importedCount = importedCount
        self.skippedDuplicates = skippedDuplicates
        self.failedCount = failedCount
        self.verifiedCount = verifiedCount
        self.isCancelled = isCancelled
    }
}
