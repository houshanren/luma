import Foundation
/// 本地图库的人物聚类结果（端侧 Vision 分析，不上传任何照片）。
public struct LocalPerson: Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var assetIDs: [UUID]
    public var coverImageData: Data?
    public var faceCount: Int
    public var centroid: [Float]

    /// 聚类生成时默认叫「人物 N」，用户没改过名就视为未命名。
    public var isUnnamed: Bool {
        name.hasPrefix("人物 ") && Int(name.dropFirst(3)) != nil
    }
    public init(
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
