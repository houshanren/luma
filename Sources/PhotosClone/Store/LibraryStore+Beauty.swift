import Foundation
import AppKit
import LumaCore
import SwiftUI

/// 一次批量美化的结果，供推荐面板与智能助手复用。
struct BeautyBatchResult {
    let applied: Int
    let skipped: Int
    let message: String
}

/// 智能美化：用缩略图做端侧分析，按「偏暗 / 偏亮 / 发灰 / 偏色 / 偏软」归类推荐，
/// 并把建议映射成编辑器同一套参数生成渲染副本。原图始终保留，可随时还原。仅作用于本地图库。
extension LibraryStore {
    /// 是否有可美化的照片：系统图库与网盘都是只读来源。
    var canScanBeauty: Bool {
        !isSystemScope && !isCloudScope && !needsLibrarySetup
    }

    func resetBeautyState() {
        beautyTask?.cancel()
        beautyTask = nil
        beautyReport = nil
        isScanningBeauty = false
        beautyScanProgress = 0
        isApplyingBeauty = false
        beautyApplyProgress = 0
        showBeautyPanel = false
    }

    // MARK: - 扫描与推荐

    /// 按拍摄时间从新到旧分析最多 `limit` 张照片，产出可直接批量处理的分组。
    func scanBeautyCandidates(limit: Int = 2000) {
        guard canScanBeauty else {
            showToast("智能美化仅支持拾光本地图库")
            return
        }
        guard !isScanningBeauty, !isApplyingBeauty else { return }

        let targets = photos
            .filter { $0.deletedAt == nil && !$0.isHidden && !$0.isVideo }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard !targets.isEmpty else {
            showToast("图库里还没有可分析的照片")
            return
        }
        let slice = Array(targets.prefix(max(1, limit)))

        isScanningBeauty = true
        beautyScanProgress = 0
        beautyTask = Task { [weak self] in
            guard let self else { return }
            var found: [(UUID, BeautyAdvice)] = []
            found.reserveCapacity(slice.count)

            // 按小块并发：缩略图解码是主要开销，小块可以及时回报进度。
            let chunkSize = 12
            var index = 0
            while index < slice.count {
                if Task.isCancelled { break }
                let end = min(index + chunkSize, slice.count)
                let chunk = Array(slice[index..<end])
                let part = await Task.detached(priority: .utility) {
                    chunk.compactMap { photo in
                        PhotoBeauty.advice(for: photo).map { (photo.id, $0) }
                    }
                }.value
                found.append(contentsOf: part)
                index = end
                self.beautyScanProgress = Double(index) / Double(max(1, slice.count))
            }

            if Task.isCancelled {
                self.isScanningBeauty = false
                self.beautyScanProgress = 0
                self.beautyTask = nil
                return
            }

            let report = self.buildBeautyReport(found: found, scannedCount: slice.count)
            self.beautyReport = report
            self.isScanningBeauty = false
            self.beautyScanProgress = 0
            self.beautyTask = nil
            if report.distinctCount == 0 {
                self.showToast("分析完成：这 \(slice.count) 张画面已经比较均衡")
            } else {
                self.showToast("分析完成：\(report.distinctCount) 张可以美化")
            }
        }
    }

    func cancelBeautyScan() {
        beautyTask?.cancel()
        beautyTask = nil
        isScanningBeauty = false
        beautyScanProgress = 0
    }

    /// 把候选按偏差方向分桶，并按「偏差程度 + 收藏加权 - 已编辑降权」排序。
    @MainActor
    private func buildBeautyReport(found: [(UUID, BeautyAdvice)], scannedCount: Int) -> BeautyReport {
        let lookup = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var buckets: [BeautyGroup.Kind: [(Double, BeautyCandidate)]] = [:]

        for (id, advice) in found where advice.score >= BeautyAdvisor.recommendThreshold {
            guard lookup[id] != nil else { continue }
            var rank = advice.score
            if lookup[id]?.isFavorite == true { rank += 0.08 }
            if lookup[id]?.hasEdits == true { rank -= 0.12 }
            let candidate = BeautyCandidate(photoID: id, advice: advice)
            for kind in Self.beautyKinds(for: advice) {
                buckets[kind, default: []].append((rank, candidate))
            }
        }

        let groups = BeautyGroup.Kind.allCases.compactMap { kind -> BeautyGroup? in
            guard let entries = buckets[kind], !entries.isEmpty else { return nil }
            let sorted = entries
                .sorted { $0.0 > $1.0 }
                .prefix(300)
                .map(\.1)
            return BeautyGroup(kind: kind, candidates: Array(sorted))
        }
        .sorted { $0.count > $1.count }

        return BeautyReport(scannedAt: Date(), scannedCount: scannedCount, groups: groups)
    }

    private static func beautyKinds(for advice: BeautyAdvice) -> [BeautyGroup.Kind] {
        var kinds: [BeautyGroup.Kind] = []
        if advice.exposure > 0.15 { kinds.append(.dark) }
        if advice.exposure < -0.15 { kinds.append(.bright) }
        if advice.contrast >= 0.06 { kinds.append(.flat) }
        if abs(advice.warmth) >= 0.06 || abs(advice.tint) >= 0.06 { kinds.append(.cast) }
        if advice.sharpness >= 0.15 { kinds.append(.soft) }
        return kinds
    }

    // MARK: - 批量应用

    /// 为指定照片生成美化副本。已经是编辑过的照片会在原有编辑点上叠加，不会丢弃已有调整。
    @discardableResult
    func applyBeauty(to photoIDs: [UUID], strength: Double = 1) async -> BeautyBatchResult {
        guard canScanBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "智能美化仅支持拾光本地图库")
        }
        guard !isApplyingBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "正在美化其他照片，请稍候")
        }
        let wanted = Set(photoIDs)
        let targets = photos.filter { wanted.contains($0.id) && !$0.isVideo && $0.deletedAt == nil }
        guard !targets.isEmpty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "没有可美化的照片")
        }

        isApplyingBeauty = true
        beautyApplyProgress = 0
        var renders: [BeautyRender] = []
        renders.reserveCapacity(targets.count)

        // 原图解码与全尺寸渲染较重，逐小块放到后台，界面只更新进度。
        let chunkSize = 4
        var index = 0
        while index < targets.count {
            if Task.isCancelled { break }
            let end = min(index + chunkSize, targets.count)
            let chunk = Array(targets[index..<end])
            let part = await Task.detached(priority: .userInitiated) {
                Self.renderBeauty(checkpoint: chunk, strength: strength)
            }.value
            renders.append(contentsOf: part)
            index = end
            beautyApplyProgress = Double(index) / Double(max(1, targets.count))
        }

        commitBeautyRenders(renders)
        isApplyingBeauty = false
        beautyApplyProgress = 0

        let skipped = targets.count - renders.count
        if renders.isEmpty {
            return BeautyBatchResult(applied: 0, skipped: skipped, message: "这些照片没有可美化的调整")
        }
        showToast(skipped > 0 ? "已美化 \(renders.count) 张，\(skipped) 张跳过" : "已美化 \(renders.count) 张")
        return BeautyBatchResult(applied: renders.count, skipped: skipped, message: "已美化 \(renders.count) 张")
    }

    // MARK: - 应用前确认

    /// 批量美化会写入渲染副本，执行前统一弹一次确认（与智能助手工具的确认方式一致）。
    func confirmBeautyApply(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "生成美化副本？"
        alert.informativeText = "将为 \(count) 张照片生成美化副本。原图与已有编辑都保留，可随时在编辑器的「美化」页撤销。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "开始美化")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 渲染与落盘

    private struct BeautyRender: Sendable {
        let id: UUID
        let data: Data
        let width: Int
        let height: Int
        let recipe: String
    }

    /// 纯计算：解码原图 → 叠加美化建议 → 全尺寸渲染成 JPEG。放在后台线程执行。
    nonisolated private static func renderBeauty(checkpoint: [PhotoItem],
                                                 strength: Double) -> [BeautyRender] {
        checkpoint.compactMap { photo in
            guard let advice = PhotoBeauty.advice(for: photo) else { return nil }
            let hasRecipe = photo.hasEdits && photo.editRecipe != nil
            // 有编辑点时从原图重建，避免在已渲染的副本上反复叠加。
            let baseURL = hasRecipe ? LibraryPaths.originalURL(for: photo)
                                    : LibraryPaths.sourceURL(for: photo)
            guard let base = PhotoRenderer.loadBase(url: baseURL) else { return nil }

            var state = hasRecipe ? (photo.editRecipe.flatMap(EditState.init(jsonString:)) ?? EditState())
                                  : EditState()
            if !hasRecipe {
                state.rotation = photo.rotationAngle
            }
            let next = EditState.beautified(state, advice: advice, strength: strength)
            guard let image = PhotoRenderer.renderCG(base: base, state: next, maxPixel: nil),
                  let data = jpegData(from: image),
                  let recipe = next.jsonString else { return nil }
            return BeautyRender(id: photo.id, data: data, width: image.width,
                                height: image.height, recipe: recipe)
        }
    }

    /// 一次写入全部渲染结果与缩略图，只 `save()` 一次。
    private func commitBeautyRenders(_ renders: [BeautyRender]) {
        guard !renders.isEmpty else { return }
        LibraryPaths.prepare()
        for render in renders {
            guard let index = photos.firstIndex(where: { $0.id == render.id }) else { continue }
            let filename = render.id.uuidString + ".jpg"
            let url = LibraryPaths.edited.appendingPathComponent(filename)
            try? render.data.write(to: url, options: .atomic)

            var updated = photos[index]
            updated.editedFilename = filename
            updated.pixelWidth = render.width
            updated.pixelHeight = render.height
            updated.editRecipe = render.recipe
            // 渲染结果已经包含旋转，清掉旋转元数据避免二次旋转。
            updated.rotation = nil
            ImportService.makeImageThumbnail(url: url, destination: LibraryPaths.thumbnailURL(for: updated))
            updated.editVersion += 1
            photos[index] = updated
            ImageLoader.invalidate(photo: updated)
        }
        save()
    }

    // MARK: - 与其它范围的衔接

    /// 在网格中选中一组推荐照片，供「查看」使用：先回到「所有照片」网格再选中。
    func selectBeautyCandidates(_ ids: [UUID]) {
        showBeautyPanel = false
        navigate(to: .library)
        selection = Set(ids)
        showToast("已选中 \(ids.count) 张")
    }
}
