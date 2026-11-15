import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Viewer

    func openViewer(_ id: UUID) {
        viewerID = id
        selection = [id]
        recordView(id)
        // 非分页范围下这里会把胶片条清空，避免沿用上一次的窗口片段。
        refreshViewerStripIfNeeded()
        if AppSettings.shared.showInfoOnOpen {
            showInfoPanel = true
        }
    }

    func closeViewer() {
        viewerID = nil
        viewerStrip = []
        viewerStripKey = nil
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
        // 大图库：顺序由 SQLite 决定，相邻项用 keyset 查询，翻页成本与总量无关。
        if isPagedScope, let query = pagedQuery, let store = metadataStore {
            guard let current = viewerIndex(of: viewerID), visibleCount > 0,
                  let target = store.neighbor(of: viewerID, delta: delta > 0 ? 1 : -1, in: query) else {
                return
            }
            var next = current + (delta > 0 ? 1 : -1)
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
        guard let current = viewerIndex(of: viewerID) else { return }
        var next = current + delta
        if next < 0 { next = items.count - 1 }
        if next >= items.count { next = 0 }
        let target = items[next]
        viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: target.id, index: next)
        self.viewerID = target.id
        selection = [target.id]
        recordView(target.id)
    }

    /// 视频播完后自动连播列表里的下一个视频（跳过照片）；已是最后一个则保持停住。
    func playNextVideo(after id: UUID) {
        guard viewerID == id else { return }
        // 用窗口内的局部位次，避免分页模式下全局下标与窗口长度不一致。
        let items = visiblePhotos
        guard let current = items.firstIndex(where: { $0.id == id }),
              current + 1 < items.count else { return }
        guard let nextIndex = items[(current + 1)...].firstIndex(where: { $0.isVideo }) else { return }
        let target = items[nextIndex]
        viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: target.id, index: nextIndex)
        viewerID = target.id
        selection = [target.id]
        recordView(target.id)
    }

    /// 在查看器里跳到上一个 / 下一个视频（跳过照片），供视频控制条使用。
    func viewerStepVideo(_ delta: Int) {
        guard let viewerID else { return }
        let items = visiblePhotos
        guard let current = items.firstIndex(where: { $0.id == viewerID }) else { return }
        let step = delta > 0 ? 1 : -1
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
        let items = visiblePhotos
        guard let current = items.firstIndex(where: { $0.id == id }) else { return false }
        let step = delta > 0 ? 1 : -1
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo { return true }
            index += step
        }
        return false
    }

    /// 当前可见列表里的位置；同一列表内连续翻页时命中缓存为 O(1)，未命中时回退到线性/索引查询。
    func viewerIndex(of id: UUID) -> Int? {
        if isPagedScope {
            if let cache = viewerIndexCache, cache.key == pagedKey, cache.id == id {
                return cache.index
            }
            guard let query = windowQuery ?? pagedQuery,
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

    static func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    }
}
