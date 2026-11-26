import CoreGraphics
import Foundation
import LumaCore

/// Retina 2x 估算，与 LumaUI 的 `ThumbnailPurpose.scale` 保持一致；
/// 最终仍会被 `ImageLoader` 收敛到固定档位。Domain 不能反向依赖 LumaUI，故在此重复一次。
private let personAvatarPixelScale: CGFloat = 2

/// 人物 / 宠物头像的取图请求：优先官方裁切图；缺失时按关键人脸几何从
/// 关键照片现算脸部特写（与官方「照片」的人物头像口径一致）；再退回整张缩略图。
///
/// 视图层只能异步取用——解码放进后台，主线程 body 里不做图片解码或按 ID 查库。
package struct PersonAvatarRequest: Hashable {
    package let cacheKey: String
    package let cropData: Data?
    package let fallbackPhotoID: UUID?
    /// 关键人脸几何（0-1 归一化：cx 相对图宽、cy 相对图高且原点在左下、size 相对图对角线）。
    package let faceGeometry: (centerX: Double, centerY: Double, size: Double)?
    /// 解码边长（像素，已收敛到固定档位）。
    package let maxPixel: CGFloat

    package init(identity: String, cropData: Data?, fallbackPhotoID: UUID?,
                 faceGeometry: (centerX: Double, centerY: Double, size: Double)? = nil,
                 size: CGFloat) {
        let bucket = ThumbnailSizing.bucket(for: size * personAvatarPixelScale)
        let geometryKey = faceGeometry
            .map { String(format: "%.4f|%.4f|%.4f", $0.centerX, $0.centerY, $0.size) } ?? "-"
        cacheKey = "\(identity)|\(bucket)|\(cropData?.count ?? 0)|\(fallbackPhotoID?.uuidString ?? "-")|\(geometryKey)"
        self.cropData = cropData
        self.fallbackPhotoID = fallbackPhotoID
        self.faceGeometry = faceGeometry
        maxPixel = CGFloat(bucket)
    }

    package static func == (lhs: PersonAvatarRequest, rhs: PersonAvatarRequest) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(cacheKey)
    }
}

package extension PersonAvatarRequest {
    /// 本地图库人物：封面裁切图 + 第一张成员照片兜底。
    static func make(for person: LocalPerson, size: CGFloat) -> PersonAvatarRequest {
        PersonAvatarRequest(identity: "local-\(person.id.uuidString)",
                            cropData: person.coverImageData,
                            fallbackPhotoID: person.assetIDs.first,
                            size: size)
    }

    /// 「值得重看」里的同行人：只带封面裁切图。
    static func make(for companion: PersonInsight.Companion, size: CGFloat) -> PersonAvatarRequest {
        PersonAvatarRequest(identity: "companion-\(companion.id)",
                            cropData: companion.coverData,
                            fallbackPhotoID: companion.coverPhotoID,
                            size: size)
    }
}
