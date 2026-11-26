import Foundation

package struct ImportOptions {
    package var createAlbumsFromFolders: Bool = true
    package var preserveFolderStructure: Bool = true
    package var targetAlbumID: UUID?
    /// 导入前计算 SHA-256，跳过与图库中已有文件字节完全相同的项目。
    package var skipExactDuplicates: Bool = true
    /// 复制完成后重新计算目标文件哈希，确认写入完整。
    package var verifyCopies: Bool = true
    package init(
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

package struct ImportProgress {
    package var total: Int
    package var completed: Int
    package var currentName: String
    package var importedCount: Int = 0
    package var skippedDuplicates: Int = 0
    package var failedCount: Int = 0
    package var verifiedCount: Int = 0
    package var isCancelled: Bool = false

    package var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
    package init(
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
