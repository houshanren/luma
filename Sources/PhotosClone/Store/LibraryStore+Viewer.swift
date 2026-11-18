import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Viewer

    func openViewer(_ id: UUID) {
        openViewer(id, context: [])
    }

    /// 从非图库网格（地图 / 地点 / 卡片墙）打开查看器：序号、总数与左右翻页都以这份列表为准。
    /// 传空数组等价于普通打开（按当前图库查询定位）。
    func openViewer(_ id: UUID, context: [PhotoItem]) {
        if cinemaPlaybackPhoto?.id != id {
            cinemaPlaybackPhoto = nil
        }
        viewerContextPhotos = context
        viewerID = id
        selection = [id]
        recordView(id)
        // 打开新照片时丢掉上一次的下标缓存，按当前查询重新算一次序号与邻居，
        // 避免沿用上一张的 ±1 结果把偏差带进来。
        viewerIndexCache = nil
        viewerPositionCache = nil
        // 连拍：先按当前照片载入整组，后面的翻页与序号都在组内进行。
        refreshViewerBurstGroup()
        // 非分页范围下这里会把胶片条清空，避免沿用上一次的窗口片段。
        refreshViewerStripIfNeeded()
        if AppSettings.shared.showInfoOnOpen {
            showInfoPanel = true
        }
    }

    func closeViewer() {
        let lastID = viewerID
        viewerID = nil
        cinemaPlaybackPhoto = nil
        viewerStrip = []
        viewerStripKey = nil
        viewerContextPhotos = []
        viewerIndexCache = nil
        viewerPositionCache = nil
        clearViewerBurstState()
        // 「所有照片」时间轴里翻页可能已经走出已加载窗口：返回网格时把它滚回来。
        if let lastID, isTimelineScope, isPagedScope {
            revealInWindow(lastID)
        }
    }

    /// 按「点击照片时」设置打开：查看器 / 编辑器 / 系统默认应用。
    func openPhoto(_ id: UUID, by mode: PhotoOpenMode) {
        switch mode {
        case .viewer:
            openViewer(id)
        case .editor:
            // 视频与只读项目（系统图库 / 只读网盘）仍交给查看器。
            if let photo = anyPhoto(id: id), !photo.isVideo, !photo.isReadOnly {
                openEditor(id)
            } else {
                openViewer(id)
            }
        case .systemApp:
            openInSystemApp(id)
        }
    }

    func viewerStep(_ delta: Int) {
        guard let viewerID else { return }
        let step = delta > 0 ? 1 : -1
        // 连拍：在原组内按拍摄顺序翻页，与官方「照片」一致（翻到末尾回到第一张）。
        if viewerModel.burstMembers.count > 1,
           let position = viewerModel.burstMembers.firstIndex(where: { $0.id == viewerID }) {
            let members = viewerModel.burstMembers
            var next = position + step
            if next < 0 { next = members.count - 1 }
            if next >= members.count { next = 0 }
            let target = members[next]
            viewerIndexCache = nil
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            return
        }
        // 「图库」页新照片在底部时，网格视觉顺序是旧 → 新（与查询顺序相反），
        // 查看器的下一张 / 上一张必须跟着屏幕走。
        let queryStep = viewerUsesVisualTimelineOrder ? -step : step
        // 外部列表（地图 / 地点 / 卡片墙）与「相似照片」：都按屏幕上的那份列表翻页。
        if !viewerContextPhotos.isEmpty || similarScope != nil {
            let count = viewerNavigationPhotos.count
            guard count > 0,
                  let current = viewerNavigationPhotos.firstIndex(where: { $0.id == viewerID }) else { return }
            let target = viewerNavigationPhotos[(current + viewerNavigationStep(delta) + count) % count]
            viewerIndexCache = nil
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            return
        }
        // 系统图库索引：顺序由索引决定，相邻项用索引查询，翻页成本与总量无关。
        if isSystemPagedScope, let query = systemPagedQuery, let index = systemIndex {
            // 直连模式没有全局下标（`index(of:)` 为 nil），不能拿它当翻页前提；
            // 相邻项由索引 / 直连 SQL 直接查询，翻页成本与总量无关。
            guard let target = index.neighbor(of: viewerID, delta: queryStep, in: query) else {
                return
            }
            if let current = viewerQueryIndex(of: viewerID), visibleCount > 0 {
                var next = current + queryStep
                if next < 0 { next += visibleCount }
                if next >= visibleCount { next -= visibleCount }
                viewerIndexCache = ViewerIndexCache(key: pagedKey, id: target.id, index: next)
            } else {
                viewerIndexCache = nil
            }
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            refreshViewerStripIfNeeded()
            return
        }
        // 大图库：顺序由 SQLite 决定，相邻项用 keyset 查询，翻页成本与总量无关。
        if isPagedScope, let query = pagedQuery, let store = metadataStore {
            guard let current = viewerQueryIndex(of: viewerID), visibleCount > 0,
                  let target = store.neighbor(of: viewerID, delta: queryStep, in: query) else {
                return
            }
            var next = current + queryStep
            if next < 0 { next += visibleCount }
            if next >= visibleCount { next -= visibleCount }
            viewerIndexCache = ViewerIndexCache(key: pagedKey, id: target.id, index: next)
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            refreshViewerStripIfNeeded()
            return
        }
        let items = visiblePhotos
        guard !items.isEmpty else { return }
        // 连翻时避免每次都线性扫描超大数组。
        guard let current = viewerQueryIndex(of: viewerID) else { return }
        var next = current + queryStep
        if next < 0 { next = items.count - 1 }
        if next >= items.count { next = 0 }
        let target = items[next]
        viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: target.id, index: next)
        self.viewerID = target.id
        selection = [target.id]
        recordView(target.id)
    }

    /// 查看器翻页使用的列表：外部列表（地图 / 地点 / 卡片墙）优先，否则用图库可见集合。
    private var viewerNavigationPhotos: [PhotoItem] {
        viewerContextPhotos.isEmpty ? visiblePhotos : viewerContextPhotos
    }

    /// 翻页方向：外部列表按原顺序，图库在「新照片在底部」时反转。
    private func viewerNavigationStep(_ delta: Int) -> Int {
        let step = delta > 0 ? 1 : -1
        guard viewerContextPhotos.isEmpty else { return step }
        return viewerUsesVisualTimelineOrder ? -step : step
    }

    /// 视频播完后自动连播列表里的下一个视频（跳过照片）；已是最后一个则保持停住。
    func playNextVideo(after id: UUID) {
        guard viewerID == id else { return }
        // 用窗口内的局部位次，避免分页模式下全局下标与窗口长度不一致。
        let items = viewerNavigationPhotos
        guard let current = items.firstIndex(where: { $0.id == id }) else { return }
        let step = viewerNavigationStep(1)
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo {
                let target = items[index]
                viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: target.id, index: index)
                viewerID = target.id
                selection = [target.id]
                recordView(target.id)
                return
            }
            index += step
        }
    }

    /// 在查看器里跳到上一个 / 下一个视频（跳过照片），供视频控制条使用。
    func viewerStepVideo(_ delta: Int) {
        guard let viewerID else { return }
        let items = viewerNavigationPhotos
        guard let current = items.firstIndex(where: { $0.id == viewerID }) else { return }
        let step = viewerNavigationStep(delta)
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo {
                let target = items[index]
                let key = isPagedScope ? pagedKey : visibleStateKey
                viewerIndexCache = ViewerIndexCache(key: key, id: target.id, index: index)
                self.viewerID = target.id
                selection = [target.id]
                recordView(target.id)
                return
            }
            index += step
        }
    }

    /// 从指定项目出发，前 / 后是否还有可跳转的视频。
    func hasAdjacentVideo(from id: UUID, delta: Int) -> Bool {
        let items = viewerNavigationPhotos
        guard let current = items.firstIndex(where: { $0.id == id }) else { return false }
        let step = viewerNavigationStep(delta)
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo { return true }
            index += step
        }
        return false
    }

    /// 查看器显示的序号（0 起）：默认就是查询顺序；
    /// 「新照片在底部」时换算成网格的视觉顺序（第 1 张是最早的，最后一张是最新的）。
    func viewerIndex(of id: UUID) -> Int? {
        guard let raw = viewerQueryIndex(of: id) else { return nil }
        let total = visibleCount
        guard viewerUsesVisualTimelineOrder, total > 0 else { return raw }
        return max(0, min(total - 1, total - 1 - raw))
    }

    /// 查看器顶栏 / 全屏底栏的「当前 / 总数」。
    /// 任何入口（相簿位置跳转、场景目录、卡片墙与目录封面…）打开都必须给出一组数字：
    /// 优先用查询下标（分页 / 系统索引，与网格顺序和翻页一致），算不出时依次退回
    /// 已加载窗口 → 胶片条 → 可见列表 → 照片自身所属的完整范围。
    func viewerPosition(of id: UUID) -> (index: Int, total: Int) {
        let key = visibleStateKey
        if let cache = viewerPositionCache, cache.key == key, cache.id == id {
            return (cache.index, cache.total)
        }
        let position = resolveViewerPosition(of: id)
        viewerPositionCache = ViewerPositionCache(key: key, id: id,
                                                 index: position.index, total: position.total)
        return position
    }

    private func resolveViewerPosition(of id: UUID) -> (index: Int, total: Int) {
        // 从地图 / 地点 / 卡片墙打开：序号与总数都以那份列表为准。
        if let position = viewerContextPhotos.firstIndex(where: { $0.id == id }) {
            return (position, viewerContextPhotos.count)
        }
        if let index = viewerIndex(of: id) {
            // 全局排名可用：总数是整段范围的数量，不是已加载窗口。
            return (index, max(visibleCount, index + 1, 1))
        }
        // 分页窗口已加载：窗口起始排名 + 窗口内位置就是整段范围里的序号。
        if isSystemPagedScope {
            let total = max(systemWindowTotal, systemWindowStartRank + systemWindowPhotos.count, 1)
            if let position = systemWindowPhotos.firstIndex(where: { $0.id == id }) {
                return (visualIndex(systemWindowStartRank + position, total: total), total)
            }
        } else if isPagedScope {
            let total = max(windowTotal, windowStartOffset + windowPhotos.count, 1)
            if let position = windowPhotos.firstIndex(where: { $0.id == id }) {
                return (visualIndex(windowStartOffset + position, total: total), total)
            }
        }
        // 胶片条已经是网格的视觉顺序，直接取位置。
        if let position = viewerStrip.firstIndex(where: { $0.id == id }) {
            return (position, viewerStrip.count)
        }
        let visible = viewerVisiblePhotos
        if let position = visible.firstIndex(where: { $0.id == id }) {
            return (position, visible.count)
        }
        // 照片不在当前可见集合里（卡片墙 / 目录封面 / 其它范围直接打开）：
        // 退回它自身所属的完整范围，保证序号与总数不会凭空消失。
        let own = ownScopePhotos(for: id)
        if let position = own.firstIndex(where: { $0.id == id }) {
            return (position, own.count)
        }
        return (0, 1)
    }

    /// 查询顺序排名换算成网格的视觉顺序排名。
    private func visualIndex(_ raw: Int, total: Int) -> Int {
        guard viewerUsesVisualTimelineOrder, total > 0 else { return raw }
        return max(0, min(total - 1, total - 1 - raw))
    }

    /// 当前照片所属的完整范围：网盘全部照片 / 系统图库 / 本地库。
    private func ownScopePhotos(for id: UUID) -> [PhotoItem] {
        if let photo = anyPhoto(id: id) {
            if photo.isCloud { return cloudPhotos }
            if photo.isSystem { return systemPhotos }
        }
        return photos
    }

    /// 当前照片在查询顺序里的下标（0 = 最新）；内部翻页运算统一用它，界面序号再经 `viewerIndex(of:)` 换算。
    func viewerQueryIndex(of id: UUID) -> Int? {
        // 「相似照片」是过滤后的固定集合：序号必须在集合内算，不能沿用整库下标。
        if similarScope != nil {
            guard let index = visiblePhotos.firstIndex(where: { $0.id == id }) else { return nil }
            viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: id, index: index)
            return index
        }
        if isSystemPagedScope {
            if let cache = viewerIndexCache, cache.key == pagedKey, cache.id == id {
                return cache.index
            }
            // 直连模式没有全局下标（一次 COUNT 会扫整库）：查看器都是从网格打开的，
            // 用「窗口起始排名 + 窗口内位置」换算，后续翻页由 `viewerStep` 按 ±1 维护缓存。
            if systemIndex?.direct != nil {
                // 窗口必须已经是当前查询的窗口；否则位置与起始排名对不上，
                // 宁可先不显示序号，也不要显示一个会跳变的错误数字。
                guard systemWindowQuery?.key == systemPagedQuery?.key,
                      let position = systemWindowPhotos.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                let index = systemWindowStartRank + position
                viewerIndexCache = ViewerIndexCache(key: pagedKey, id: id, index: index)
                return index
            }
            guard let query = systemPagedQuery,
                  let index = systemIndex?.index(of: id, in: query) else {
                return nil
            }
            viewerIndexCache = ViewerIndexCache(key: pagedKey, id: id, index: index)
            return index
        }
        if isPagedScope {
            if let cache = viewerIndexCache, cache.key == pagedKey, cache.id == id {
                return cache.index
            }
            // 必须以「当前查询」为准：窗口查询可能还是上一次范围的，拿它算序号会整体偏移。
            guard let query = pagedQuery,
                  let index = metadataStore?.index(of: id, in: query) else {
                return nil
            }
            viewerIndexCache = ViewerIndexCache(key: pagedKey, id: id, index: index)
            return index
        }
        let items = visiblePhotos
        if let cache = viewerIndexCache,
           cache.key == visibleStateKey,
           cache.id == id,
           cache.index < items.count,
           items[cache.index].id == id {
            return cache.index
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: id, index: index)
        return index
    }

    func openEditor(_ id: UUID) {
        guard let photo = photo(id: id), !photo.isVideo, !photo.isSystem, !photo.isCloud else { return }
        editorID = id
    }

    func closeEditor() {
        editorID = nil
    }

    // MARK: - Editing

    func commitEditedImage(photoID: UUID, jpegData: Data, pixelWidth: Int, pixelHeight: Int,
                           recipe: String? = nil) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        let filename = photoID.uuidString + ".jpg"
        let url = LibraryPaths.edited.appendingPathComponent(filename)
        LibraryPaths.prepare()
        try? jpegData.write(to: url, options: .atomic)

        var updated = photos[index]
        updated.editedFilename = filename
        updated.pixelWidth = pixelWidth
        updated.pixelHeight = pixelHeight
        updated.editRecipe = recipe
        // 渲染结果已经包含旋转，清除旋转元数据避免二次旋转。
        updated.rotation = nil
        ImportService.makeImageThumbnail(url: url, destination: LibraryPaths.thumbnailURL(for: updated))
        updated.editVersion += 1
        photos[index] = updated

        ImageLoader.invalidate(photo: updated)
        save()
        editorID = nil
        showToast("已保存修改")
    }

    func revertEdits(_ photoID: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        if let editedFilename = photos[index].editedFilename {
            try? FileManager.default.removeItem(at: LibraryPaths.edited.appendingPathComponent(editedFilename))
        }
        var updated = photos[index]
        updated.editedFilename = nil
        updated.rotation = nil
        updated.editRecipe = nil
        ImportService.generateThumbnail(for: updated)
        updated.editVersion += 1
        photos[index] = updated

        ImageLoader.invalidate(photo: updated)
        save()
        showToast("已还原为原始照片")
    }

    // MARK: - 编辑点复制 / 粘贴

    func copyEdits(_ photoID: UUID) {
        guard let photo = photo(id: photoID) else { return }
        guard let recipe = photo.editRecipe else {
            showToast("这张照片没有可复制的编辑点")
            return
        }
        copiedEditRecipe = recipe
        showToast("已复制编辑点")
    }

    func pasteEdits(_ photoID: UUID) {
        guard let recipeString = copiedEditRecipe else {
            showToast("请先复制编辑点")
            return
        }
        guard let photo = photo(id: photoID), !photo.isVideo,
              !photo.isReadOnly, !photo.isDeleted else {
            showToast("该照片不支持粘贴编辑点")
            return
        }
        guard let state = EditState(jsonString: recipeString) else { return }
        let baseURL = LibraryPaths.originalURL(for: photo)
        guard let base = PhotoRenderer.loadBase(url: baseURL) else {
            showToast("无法读取原始照片")
            return
        }
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: base, state: state, maxPixel: nil)
            }.value
            guard let rendered, let data = Self.jpegData(from: rendered) else {
                showToast("粘贴编辑点失败")
                return
            }
            commitEditedImage(photoID: photoID,
                              jpegData: data,
                              pixelWidth: rendered.width,
                              pixelHeight: rendered.height,
                              recipe: recipeString)
        }
    }

    nonisolated static func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    }
}
