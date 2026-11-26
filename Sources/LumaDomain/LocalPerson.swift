import Foundation
/// 本地图库的人物聚类结果（端侧 Vision 分析，不上传任何照片）。
package struct LocalPerson: Identifiable, Hashable {
    package var id: UUID
    package var name: String
    package var assetIDs: [UUID]
    package var coverImageData: Data?
    package var faceCount: Int
    package var centroid: [Float]

    /// 聚类生成时默认叫「人物 N」，用户没改过名就视为未命名。
    package var isUnnamed: Bool {
        name.hasPrefix("人物 ") && Int(name.dropFirst(3)) != nil
    }
    package init(
        id: UUID,
        name: String,
        assetIDs: [UUID],
        coverImageData: Data? = nil,
        faceCount: Int,
        centroid: [Float]
    ) {
        self.id = id
        self.name = name
        self.assetIDs = assetIDs
        self.coverImageData = coverImageData
        self.faceCount = faceCount
        self.centroid = centroid
    }
}
