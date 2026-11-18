import Foundation
import AVFoundation
import Photos

/// 系统「照片」图库的真实写入（PhotoKit）。
/// 由 Photos 自己更新原图与它自己的数据库，不直接改 `Photos.sqlite`。
/// 仅当当前图库就是官方「照片」图库时可用。
enum PhotoKitBridge {
    enum BridgeError: LocalizedError {
        case unauthorized
        case assetNotFound
        case editInputFailed
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "没有照片图库读写权限，请在「系统设置 › 隐私与安全性 › 照片」中允许拾光访问"
            case .assetNotFound:
                return "在系统「照片」图库中找不到这些项目"
            case .editInputFailed:
                return "无法读取照片原图，可能仍在 iCloud 中下载"
            case .saveFailed(let message):
                return "写回「照片」失败：\(message)"
            }
        }
    }

    static let adjustmentFormatIdentifier = "com.baymax.luma.beauty"

    /// 还没有做过选择（首次使用）：此时申请权限才会弹出系统授权框。
    static var isAuthorizationUndetermined: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    /// 申请 / 检查相册读写权限。
    static func ensureAuthorized() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            return false
        }
    }

    /// 把渲染好的 JPEG 作为可撤销的调整写回系统照片（原图与 Photos 数据库由 Photos 自己更新）。
    static func applyEdit(assetID: UUID, jpegData: Data) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let asset = try fetchAsset(assetID)
        let input = try await requestEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: adjustmentFormatIdentifier,
                                                 formatVersion: "1.0",
                                                 data: Data())
        do {
            try jpegData.write(to: output.renderedContentURL, options: .atomic)
        } catch {
            throw BridgeError.saveFailed(error.localizedDescription)
        }
        try await performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
        }
    }

    /// 移入「照片」的最近删除（30 天内可在「照片」中恢复）。
    static func delete(assetIDs: [UUID]) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    // MARK: - 校验目标库

    /// 当前打开的系统图库是否就是 PhotoKit 指向的系统「照片」图库。
    /// 用几张真实照片的 localIdentifier 能否取到来判断；取不到说明不是同一个库，禁止写回。
    static func targetsSystemLibrary(sampleAssetIDs: [UUID]) -> Bool {
        sampleAssetIDs.prefix(3).contains { (try? fetchAsset($0)) != nil }
    }

    // MARK: - 收藏 / 隐藏

    static func setFavorite(_ favorite: Bool, assetIDs: [UUID]) async throws {
        try await setFlag(assetIDs: assetIDs) { $0.isFavorite = favorite }
    }

    static func setHidden(_ hidden: Bool, assetIDs: [UUID]) async throws {
        try await setFlag(assetIDs: assetIDs) { $0.isHidden = hidden }
    }

    private static func setFlag(assetIDs: [UUID],
                                apply: @escaping (PHAssetChangeRequest) -> Void) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            for asset in assets {
                apply(PHAssetChangeRequest(for: asset))
            }
        }
    }

    // MARK: - 相簿

    /// 新建用户相簿，返回它的 localIdentifier。
    static func createAlbum(title: String) async throws -> String {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        var identifier: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier else { throw BridgeError.saveFailed("未能取得新相簿标识") }
        return identifier
    }

    static func renameAlbum(albumID: String, title: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.title = title
        }
    }

    static func deleteAlbums(albumIDs: [String]) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let albums = albumIDs.compactMap { fetchAlbum($0) }
        guard !albums.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
        }
    }

    static func addAssets(_ assetIDs: [UUID], toAlbum albumID: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    static func removeAssets(_ assetIDs: [UUID], fromAlbum albumID: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
        }
    }

    /// 相簿内手动排序：把指定照片移到最前 / 最后（macOS 13+ 的 moveAssets）。
    static func moveAssets(_ assetIDs: [UUID], inAlbum albumID: String, toTop: Bool) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let moving = assetIDs.compactMap { try? fetchAsset($0) }
        guard !moving.isEmpty else { throw BridgeError.assetNotFound }
        let all = PHAsset.fetchAssets(in: album, options: nil)
        let movingIDs = Set(moving.map(\.localIdentifier))
        var indexes = IndexSet()
        all.enumerateObjects { asset, index, _ in
            if movingIDs.contains(asset.localIdentifier) { indexes.insert(index) }
        }
        guard !indexes.isEmpty else { throw BridgeError.assetNotFound }
        let destination = toTop ? 0 : max(0, all.count - indexes.count)
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: all) else { return }
            request.moveAssets(at: indexes, to: destination)
        }
    }

    // MARK: - 媒体类型
    //
    // 长曝光 / 电影效果在 Photos.sqlite 里没有稳定字段，只能通过 PhotoKit 的智能相簿取 ID。

    /// 读取「长曝光」与「电影效果」智能相簿里的项目 ID；没有照片权限时返回 nil。
    static func specialMediaTypeAssetIDs() async -> (longExposure: Set<UUID>, cinematic: Set<UUID>)? {
        guard await ensureAuthorized() else { return nil }
        let longExposure = await smartAlbumAssetIDs(.smartAlbumLongExposures)
        let cinematic = await smartAlbumAssetIDs(.smartAlbumCinematic)
        return (longExposure ?? [], cinematic ?? [])
    }

    private static func smartAlbumAssetIDs(_ subtype: PHAssetCollectionSubtype) async -> Set<UUID>? {
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                  subtype: subtype,
                                                                  options: nil)
        guard let album = collections.firstObject else { return [] }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var ids = Set<UUID>()
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let key = asset.localIdentifier.split(separator: "/").first.map(String.init) ?? ""
            if let id = UUID(uuidString: key) { ids.insert(id) }
        }
        return ids
    }

    // MARK: - 视频素材

    /// 从系统「照片」取回可播放的视频素材。
    /// 共享相簿与仅存 iCloud 的视频在本机没有原图文件，必须由 Photos 自己按需下载。
    /// 返回的 URL 只是本地缓存路径，流式素材可能为 nil。
    static func videoAsset(id: UUID) async -> (asset: AVAsset, url: URL?)? {
        guard await ensureAuthorized(), let source = videoPHAsset(id: id) else { return nil }
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestAVAsset(forVideo: source, options: options) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
        guard let avAsset else { return nil }
        return (avAsset, (avAsset as? AVURLAsset)?.url)
    }

    /// 先按 localIdentifier 找；共享相簿里的项目不在主图库的全局集合里，需要逐个共享相簿查。
    private static func videoPHAsset(id: UUID) -> PHAsset? {
        let key = id.uuidString
        for identifier in ["\(key)/L0/001", "\(key)/L0/000"] {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                return asset
            }
        }
        let albums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .albumCloudShared,
                                                             options: nil)
        var match: PHAsset?
        albums.enumerateObjects { album, _, stopAlbums in
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            assets.enumerateObjects { asset, _, stopAssets in
                if asset.localIdentifier.hasPrefix(key) {
                    match = asset
                    stopAssets.pointee = true
                }
            }
            if match != nil { stopAlbums.pointee = true }
        }
        return match
    }

    // MARK: - 内部

    private static func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }
    }

    private static func requestEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHContentEditingInput, Error>) in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: BridgeError.editInputFailed)
                }
            }
        }
    }

    /// 系统图库的照片 ID 就是 `Photos.sqlite` 的 ZUUID，`localIdentifier` 形如 `UUID/L0/001`。
    private static func fetchAsset(_ id: UUID) throws -> PHAsset {
        let candidates = ["\(id.uuidString)/L0/001", "\(id.uuidString)/L0/000"]
        for identifier in candidates {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                return asset
            }
        }
        // 少数项目的后缀不同：按前缀兜底匹配一次。
        let all = PHAsset.fetchAssets(with: nil)
        var match: PHAsset?
        all.enumerateObjects { asset, _, stop in
            if asset.localIdentifier.hasPrefix(id.uuidString) {
                match = asset
                stop.pointee = true
            }
        }
        guard let match else { throw BridgeError.assetNotFound }
        return match
    }

    /// 相簿标识：可能是 ZUUID，也可能是完整的 localIdentifier，这里统一解析。
    private static func fetchAlbum(_ identifier: String) -> PHAssetCollection? {
        var candidates = [identifier]
        if !identifier.contains("/") {
            candidates += ["\(identifier)/L0/001", "\(identifier)/L0/000"]
        }
        for candidate in candidates {
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [candidate],
                                                                   options: nil).firstObject {
                return album
            }
        }
        // 后缀不同的少数项目：按前缀兜底匹配。
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var match: PHAssetCollection?
        all.enumerateObjects { album, _, stop in
            if album.localIdentifier.hasPrefix(identifier) {
                match = album
                stop.pointee = true
            }
        }
        return match
    }
}
