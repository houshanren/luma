import Foundation
import AppKit
import Combine
import LumaContentCore

/// 图集看图上下文：一张虚拟照片对应的原图地址、来源站与相簿路径。
struct CatalogGalleryContext {
    var source: CatalogSource
    var urlString: String
    var albumTitle: String
    /// 图集标签：顶栏在标题后面展示，最多取前两个。
    var tags: [String] = []
    /// 入库时的层级：网络图集 / 网站 / 分类 / 模特 / 图集标题。
    var folders: [String]
    var index: Int
    var total: Int
}

/// 关闭图集查看器后回到详情页的定位请求：滚到刚才看的那张图。
struct CatalogGalleryReturnRequest: Equatable {
    var index: Int
    /// 自增代次：同一张图连续返回也能再次触发滚动。
    var token: Int
}

extension LibraryStore {
    /// 网络资源（影视源）的浏览状态。
    var catalog: CatalogBrowserModel { catalogModel }

    func presentCatalogWizard(domain: CatalogDomain = .networkResource) {
        catalogModel.wizardDomain = domain
        catalogModel.showWizard = true
    }

    /// 从侧边栏打开某个资源：先切换源，再走统一导航。
    func openCatalogSource(_ id: UUID) {
        catalogModel.focus(id)
        navigate(to: .catalogSource(id))
    }

    /// 打开一条网络资源内容：图集进频道页的内联详情（看图、存整套），视频直接起播。
    /// 榜单 / 日历 / 片单 / 图集墙等聚合入口统一走这里，图集不会再被当成视频去播。
    func openCatalogItem(sourceID: UUID, item: CatalogItem) {
        guard let source = catalogModel.sources.first(where: { $0.id == sourceID }) else { return }
        if item.isGallery(in: source) {
            catalogModel.pendingInlineItem = item
            openCatalogSource(sourceID)
        } else {
            catalogModel.playRemote(sourceID: sourceID, item: item)
        }
    }

    // MARK: - 卡片操作

    /// 在浏览器打开站点首页：403 / WAF / 人机验证时，
    /// 用户先在系统浏览器完成验证，回到应用再重试即可复用同一会话。
    func openCatalogSourceInBrowser(_ source: CatalogSource) {
        guard let url = URL(string: source.baseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 在浏览器打开条目对应的站点原始详情页。
    /// 各站点的详情地址规则不同，直接问适配器要（拿不到就退回站点首页）。
    func openCatalogItemInBrowser(source: CatalogSource, item: CatalogItem) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task {
            let detail = try? await provider.detail(source: source, itemID: item.id)
            if let page = detail?.episodes.first?.pageURL, let url = URL(string: page) {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: source.baseURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 把网络视频收进图库：转封装与导入交给统一入库服务。
    func saveCatalogVideoToLibrary(source: CatalogSource, item: CatalogItem) {
        guard catalogModel.savingItemID == nil,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        catalogModel.savingItemID = item.id
        Task { [weak self] in
            guard let self else { return }
            defer { catalogModel.savingItemID = nil }
            do {
                let detail = try await provider.detail(source: source, itemID: item.id)
                guard let episode = detail.episodes.first else {
                    throw CatalogError.parse("该条目没有可播放的视频")
                }
                let stream = try await provider.stream(source: source, episode: episode)
                let result = try await ingestService.ingest(
                    IngestRequest(
                        payload: .remoteVideo(RemoteMedia(url: stream.url,
                                                          headers: stream.headers,
                                                          trustSelfSigned: source.trustsInsecureCertificate)),
                        title: item.title.isEmpty ? nil : item.title
                    )
                )
                catalogModel.showNotice("已保存到图库：\(result.title)")
            } catch {
                Diagnostics.record("保存网络视频失败 \(item.title)：\(error.localizedDescription)")
                catalogModel.showNotice("保存失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 图集保存

    /// 整本图集保存到图库：先并发取回全部原图，再一次性按
    /// 「网络图集 / 网站 / 分类 / 模特 / 图集标题」的层级建文件夹与相簿，
    /// 避免逐张入库把界面刷成几十条导入任务。
    /// 全流程只登记一条后台任务（下载 + 入库），完成后由导入侧统一提示；
    /// 不会把用户带到图库页面。
    func saveCatalogGalleryToLibrary(source: CatalogSource, item: CatalogItem) {
        guard item.isGallery(in: source),
              catalogModel.gallerySave == nil,
              !isImporting,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        let itemID = item.id
        let title = item.title.isEmpty ? source.name : item.title
        // 保存的是后台任务：完成后要回到用户当时所在的图集页面，而不是切去图库。
        let originSidebar = sidebarItem
        catalogModel.gallerySave = CatalogGallerySaveProgress(sourceID: source.id,
                                                              itemID: itemID,
                                                              title: title)
        catalogModel.savingItemID = itemID
        let jobID = beginSourceJob(
            SourceJob(sourceID: .catalog(source.id),
                      kind: .download,
                      title: "保存图集 · \(Self.galleryAlbumTitle(title))",
                      isCancellable: false)
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.catalogModel.savingItemID = nil }
            do {
                let detail: CatalogDetail
                if let cached = self.catalogModel.detail, cached.item.id == itemID,
                   !cached.articleImages.isEmpty {
                    detail = cached
                } else {
                    detail = try await provider.detail(source: source, itemID: itemID)
                }
                let images = detail.articleImages
                guard !images.isEmpty else {
                    throw CatalogError.parse("图集里没有解析到图片")
                }
                let album = Self.galleryAlbumTitle(title)
                // 目录层级与站点、当前分类、模特一一对应，最后一级就是相簿名。
                let path = Self.galleryFolderPath(site: source.name,
                                                  sectionTitle: self.catalogModel.sectionTitle,
                                                  detail: detail) + [album]

                // 重复检测：相簿已经存在时先说明已保存多少张，让用户决定是否继续；
                // 已经下载过的图片不再重复下载，只补缺的那几张。
                var targets = Array(images.enumerated())
                    .map { (index: $0.offset, address: $0.element) }
                if let existing = self.catalogGalleryAlbum(at: path)
                    ?? self.catalogGalleryAlbum(at: ["网络图集", album]) {
                    let existingIndexes = self.catalogGalleryImportedIndexes(in: existing)
                    if !existingIndexes.isEmpty {
                        let missing = targets.filter { !existingIndexes.contains($0.index + 1) }
                        if missing.isEmpty {
                            let choice = self.presentAlert(LibraryAlertRequest(
                                title: "这套图集已经保存过",
                                message: "「\(album)」已在图库：\(path.joined(separator: " / "))。\n共 \(images.count) 张，已经全部存在，不需要重复下载。\n仍要重新保存一遍吗？",
                                buttons: ["取消", "重新保存"]))
                            guard choice == 1 else {
                                self.catalogModel.gallerySave = nil
                                self.abandonSourceJob(jobID)
                                return
                            }
                        } else {
                            let choice = self.presentAlert(LibraryAlertRequest(
                                title: "这套图集之前保存过",
                                message: "「\(album)」已在图库：\(path.joined(separator: " / "))。\n已有 \(images.count - missing.count) 张，还缺 \(missing.count) 张。\n只下载缺少的图片，已经下载过的不再重复下载。",
                                buttons: ["继续保存", "取消"]))
                            guard choice == 0 else {
                                self.catalogModel.gallerySave = nil
                                self.abandonSourceJob(jobID)
                                return
                            }
                            targets = missing
                        }
                    }
                } else if let similar = self.catalogGallerySimilarAlbum(to: album) {
                    // 名字不完全一样、但图库里有高度相似的相册：先提醒，再决定要不要保存。
                    let similarPath = self.catalogGalleryAlbumPath(of: similar.album)
                        .joined(separator: " / ")
                    let percent = Int((similar.score * 100).rounded())
                    let choice = self.presentAlert(LibraryAlertRequest(
                        title: "图库里已有相似的相册",
                        message: "「\(similar.album.name)」在 \(similarPath)，与这套图集的名字相似度 \(percent)%。\n可能是同一套图集的另一种写法，仍要保存吗？",
                        buttons: ["取消", "仍然保存"]))
                    guard choice == 1 else {
                        self.catalogModel.gallerySave = nil
                        self.abandonSourceJob(jobID)
                        return
                    }
                }
                self.catalogModel.gallerySave?.total = targets.count
                self.updateSourceJob(jobID, completed: 0, total: targets.count,
                                     message: "正在下载原图…")

                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("luma-gallery-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)

                var files: [(index: Int, url: URL)] = []
                // 并发请求交给 URLSession 的连接池限流，这里只为每张图登记一次任务。
                await withTaskGroup(of: (Int, URL?).self) { group in
                    for target in targets {
                        let index = target.index
                        let address = target.address
                        group.addTask {
                            guard let data = try? await provider.coverData(source: source,
                                                                          urlString: address),
                                  !data.isEmpty else { return (index, nil) }
                            let ext = Self.galleryImageExtension(from: address)
                            let file = directory.appendingPathComponent(
                                String(format: "%03d", index + 1) + "." + ext)
                            do {
                                try data.write(to: file, options: .atomic)
                                return (index, file)
                            } catch {
                                return (index, nil)
                            }
                        }
                    }
                    for await (index, file) in group {
                        if let file { files.append((index, file)) }
                        let completed = (self.catalogModel.gallerySave?.completed ?? 0) + 1
                        self.catalogModel.gallerySave?.completed = completed
                        self.updateSourceJob(jobID, completed: completed, total: targets.count,
                                             message: "正在下载原图…")
                    }
                }

                guard !files.isEmpty else {
                    self.catalogModel.gallerySave = nil
                    self.failSourceJob(jobID, message: "没有下载到图片")
                    self.showToast("图集保存失败：没有下载到图片")
                    return
                }
                guard !self.isImporting else {
                    self.catalogModel.gallerySave = nil
                    self.failSourceJob(jobID, message: "已有导入任务在进行")
                    self.showToast("已有导入任务在进行，请稍后再试")
                    return
                }
                let entries = files.sorted { $0.index < $1.index }
                    .map { (url: $0.url, folders: path) }
                self.catalogModel.gallerySave = nil
                self.runImport(entries: entries, options: ImportOptions(), existingJobID: jobID,
                               restoreSidebarItem: originSidebar)
            } catch {
                self.catalogModel.gallerySave = nil
                self.failSourceJob(jobID, message: error.localizedDescription)
                Diagnostics.record("保存图集失败 \(title)：\(error.localizedDescription)")
                self.showToast("图集保存失败：\(error.localizedDescription)")
            }
        }
    }

    /// 图集入库的目录层级：网络图集 → 网站 → 当前分类 → 模特。
    /// 相簿名由调用方接在最后，导入侧据此逐级建文件夹。
    nonisolated static func galleryFolderPath(site: String,
                                              sectionTitle: String,
                                              detail: CatalogDetail?) -> [String] {
        var path = ["网络图集"]
        func push(_ raw: String?) {
            guard let raw else { return }
            let safe = galleryAlbumTitle(raw)
            guard safe != "未命名图集", !path.contains(safe) else { return }
            path.append(safe)
        }
        push(site)
        // 分类优先取当前浏览的分类 / 标签；首页这类聚合页没有分类，就用详情里的「分类」字段。
        let aggregates = ["首页", "排行榜", "继续观看", "稍后看"]
        if !sectionTitle.isEmpty,
           !aggregates.contains(sectionTitle),
           !sectionTitle.hasPrefix("搜索") {
            push(sectionTitle)
        } else if let detail {
            push(detail.facts.first(where: { $0.label == "分类" })?.value)
        }
        if let detail {
            push(detail.facts.first(where: { $0.label == "模特" })?.value)
        }
        return path
    }

    /// 按入库层级找到已经存在的相簿：只查不建，用于保存前的重复检测。
    func catalogGalleryAlbum(at path: [String]) -> Album? {
        guard path.count >= 2, let name = path.last else { return nil }
        var parentID: UUID?
        for folderName in path.dropLast() {
            guard let folder = folders.first(where: { $0.name == folderName && $0.parentID == parentID })
            else { return nil }
            parentID = folder.id
        }
        return albums.first(where: { $0.name == name && $0.folderID == parentID })
    }

    /// 相簿里已经存在的图片序号：保存图集时文件名固定为 001 / 002…，
    /// 再次保存时据此跳过已经下载过的图片。
    func catalogGalleryImportedIndexes(in album: Album) -> Set<Int> {
        var indexes = Set<Int>()
        for id in album.photoIDs {
            guard let name = anyPhoto(id: id)?.originalName else { continue }
            let stem = (name as NSString).deletingPathExtension
            if let value = Int(stem), value > 0 { indexes.insert(value) }
        }
        return indexes
    }

    /// 相簿的完整层级路径：提示里说明「相似相册」在图库的什么位置。
    func catalogGalleryAlbumPath(of album: Album) -> [String] {
        var parts = [album.name]
        var parentID = album.folderID
        var depth = 0
        while let id = parentID, depth < 32 {
            guard let folder = folders.first(where: { $0.id == id }) else { break }
            parts.insert(folder.name, at: 0)
            parentID = folder.parentID
            depth += 1
        }
        return parts
    }

    /// 在整座图库里找名字最相近的相簿：用于保存图集时提醒「可能已经存过」。
    /// 归一化后（忽略大小写 / 全半角 / 空白 / 标点）先比完全相同，
    /// 再按字符二元组 Dice 系数算模糊相似度；
    /// 数字串不一致（例如第 11065 期 / 第 11066 期）视为不同图集，避免连环误报。
    func catalogGallerySimilarAlbum(to name: String) -> (album: Album, score: Double)? {
        let target = SearchFuzzyText.normalize(name)
        guard target.count >= 4 else { return nil }
        var best: (album: Album, score: Double)?
        for album in albums {
            let candidate = SearchFuzzyText.normalize(album.name)
            guard candidate.count >= 4,
                  Self.galleryTitlesShareDigits(target, candidate) else { continue }
            let score = candidate == target
                ? 1
                : SearchFuzzyText.similarity(candidate, target)
            guard score >= 0.88 else { continue }
            if best == nil || score > best!.score {
                best = (album, score)
            }
        }
        return best
    }

    /// 名字里最有辨识度的数字串（最长的一段）必须一致：
    /// 同一系列不同期号（11065 / 11066）不能被当成重复；期号相同、张数写法不同（86P / 86张）仍算相似。
    nonisolated private static func galleryTitlesShareDigits(_ a: String, _ b: String) -> Bool {
        guard let left = galleryDistinctiveDigits(a),
              let right = galleryDistinctiveDigits(b) else { return true }
        return left == right
    }

    nonisolated private static func galleryDistinctiveDigits(_ text: String) -> String? {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.max { $0.count < $1.count }
    }

    /// 图片扩展名：以地址后缀为准，识别不了就按 jpg 落盘，导入侧再兜底。
    nonisolated private static func galleryImageExtension(from address: String) -> String {
        let path = address.split(separator: "?").first.map(String.init) ?? address
        let ext = path.split(separator: ".").last.map { $0.lowercased() } ?? ""
        let known: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "avif", "gif", "tiff", "bmp"]
        guard known.contains(ext) else { return "jpg" }
        return ext == "jpeg" ? "jpg" : ext
    }

    /// 相簿名：去掉路径分隔符并限制长度，避免建出层级错乱的目录。
    nonisolated private static func galleryAlbumTitle(_ title: String) -> String {
        let safe = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        return safe.isEmpty ? "未命名图集" : String(safe.prefix(60))
    }

    // MARK: - 图集看图（复用图库查看器 / 幻灯片）

    /// 用图库自己的查看器打开整套图集：翻页、缩放、胶片条与幻灯片全部复用图库能力。
    func openCatalogGalleryViewer(source: CatalogSource, item: CatalogItem,
                                  detail: CatalogDetail, startIndex: Int = 0) {
        let images = detail.articleImages
        guard !images.isEmpty else { return }
        finishCatalogGalleryViewer()
        // 新一轮看图：上一次的返回定位作废，避免刚打开就滚到旧位置。
        catalogGalleryReturnRequest = nil

        // 单张保存也走同一套层级：网络图集 / 网站 / 分类 / 模特 / 图集标题。
        let folders = Self.galleryFolderPath(site: source.name,
                                             sectionTitle: catalogModel.sectionTitle,
                                             detail: detail)
            + [Self.galleryAlbumTitle(item.title)]

        var photos: [PhotoItem] = []
        var contexts: [UUID: CatalogGalleryContext] = [:]
        for (index, address) in images.enumerated() {
            var photo = PhotoItem(filename: "catalog-gallery-\(item.id)-\(index + 1).jpg",
                                  originalName: "\(item.title) · 第 \(index + 1) 张",
                                  capturedAt: Date(),
                                  pixelWidth: 0,
                                  pixelHeight: 0,
                                  fileSize: 0,
                                  kind: .photo)
            photo.title = "\(item.title) · \(index + 1)/\(images.count)"
            photo.source = .cloud
            photo.cloudPath = address
            let id = photo.id
            photos.append(photo)
            contexts[id] = CatalogGalleryContext(source: source,
                                                 urlString: address,
                                                 albumTitle: item.title,
                                                 tags: detail.tags,
                                                 folders: folders,
                                                 index: index,
                                                 total: images.count)
        }
        catalogGalleryPhotos = photos
        catalogGalleryContexts = contexts
        let start = min(max(0, startIndex), photos.count - 1)
        openViewer(photos[start].id, context: photos)
        // 图集没有 EXIF 与拍摄参数，信息面板只会是一排空字段。
        showInfoPanel = false
        // 首张的尺寸 / 体积先补一次：用户按 ⇧⌘I 打开信息面板时已经就绪。
        refreshCatalogGalleryMetrics(for: photos[start].id)
    }

    /// 图集看图里的照片是虚拟条目：按需从原图读一次尺寸、体积与 EXIF，
    /// 让信息面板不再长期显示「0 × 0 / 0 KB」。
    /// 只补缺失字段，用户已经看到过的数据不会被覆盖。
    func refreshCatalogGalleryMetrics(for id: UUID) {
        guard let index = catalogGalleryPhotos.firstIndex(where: { $0.id == id }),
              let context = catalogGalleryContexts[id] else { return }
        let photo = catalogGalleryPhotos[index]
        let missingPixels = photo.pixelWidth <= 0 || photo.pixelHeight <= 0
        guard missingPixels || photo.fileSize <= 0 else { return }
        guard !catalogGalleryMetricsLoading.contains(id) else { return }
        catalogGalleryMetricsLoading.insert(id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.catalogGalleryMetricsLoading.remove(id) }
            guard let provider = CatalogProviders.provider(for: context.source.kind),
                  let data = try? await provider.coverData(source: context.source,
                                                           urlString: context.urlString),
                  !data.isEmpty else { return }
            let exif = CloudEXIF.metadata(from: data)
            guard let index = self.catalogGalleryPhotos.firstIndex(where: { $0.id == id }) else {
                return
            }
            var updated = self.catalogGalleryPhotos[index]
            if missingPixels, let width = exif?.pixelWidth, let height = exif?.pixelHeight,
               width > 0, height > 0 {
                updated.pixelWidth = width
                updated.pixelHeight = height
            }
            if updated.fileSize <= 0 {
                updated.fileSize = Int64(data.count)
            }
            // 站点原图如果带 EXIF，顺手补上拍摄时间与机身信息，信息面板更完整。
            if let captured = exif?.capturedAt { updated.capturedAt = captured }
            updated.make = updated.make ?? exif?.make
            updated.model = updated.model ?? exif?.model
            updated.lens = updated.lens ?? exif?.lens
            updated.focalLength = updated.focalLength ?? exif?.focalLength
            updated.aperture = updated.aperture ?? exif?.aperture
            updated.shutterSpeed = updated.shutterSpeed ?? exif?.shutterSpeed
            updated.iso = updated.iso ?? exif?.iso
            updated.latitude = updated.latitude ?? exif?.latitude
            updated.longitude = updated.longitude ?? exif?.longitude
            self.catalogGalleryPhotos[index] = updated
        }
    }

    func catalogGalleryPhoto(for id: UUID) -> PhotoItem? {
        catalogGalleryPhotos.first(where: { $0.id == id })
    }

    func catalogGalleryContext(for id: UUID) -> CatalogGalleryContext? {
        catalogGalleryContexts[id]
    }

    /// 查看器取图：优先内存里刚看过的原图，其次清晰图，失败再退快速层，保证至少能显示。
    func catalogGalleryDisplayImage(for id: UUID) async -> NSImage? {
        if let cached = catalogGalleryViewerCache.object(forKey: id.uuidString as NSString) {
            return cached
        }
        guard let context = catalogGalleryContexts[id] else { return nil }
        var image = await CatalogArtworkCache.shared.image(source: context.source,
                                                          urlString: context.urlString,
                                                          quick: false)
        if image == nil {
            image = await CatalogArtworkCache.shared.image(source: context.source,
                                                           urlString: context.urlString,
                                                           quick: true)
        }
        if let image {
            catalogGalleryViewerCache.setObject(image, forKey: id.uuidString as NSString)
        }
        return image
    }

    /// 胶片条 / 背景模糊层取缩略图：内存命中就直接给，翻页不再重复读盘。
    func catalogGalleryThumbnail(for id: UUID) async -> NSImage? {
        guard let context = catalogGalleryContexts[id] else { return nil }
        let key = CatalogArtworkCache.cacheKey(sourceID: context.source.id,
                                               urlString: context.urlString,
                                               quick: true)
        if let cached = CatalogArtworkMemory.shared.image(for: key) { return cached }
        let image = await CatalogArtworkCache.shared.image(source: context.source,
                                                           urlString: context.urlString,
                                                           quick: true)
        if let image { CatalogArtworkMemory.shared.store(image, for: key) }
        return image
    }

    /// 同步缩略图：内存 → 磁盘上已生成的 320px 缓存。
    /// 查看器切页时先在首帧铺上它，原图随后到，不会出现整块空白。
    func catalogGalleryCachedThumbnail(for id: UUID) -> NSImage? {
        guard let context = catalogGalleryContexts[id] else { return nil }
        let key = CatalogArtworkCache.cacheKey(sourceID: context.source.id,
                                               urlString: context.urlString,
                                               quick: true)
        if let cached = CatalogArtworkMemory.shared.image(for: key) { return cached }
        guard FileManager.default.fileExists(atPath: key),
              let image = NSImage(contentsOfFile: key) else { return nil }
        CatalogArtworkMemory.shared.store(image, for: key)
        return image
    }

    /// 预热相邻的原图：翻到下一张 / 上一张时直接命中缓存，不再等网络。
    /// 原图体积大，只留紧邻的两张，避免内存被图集占满。
    func prefetchCatalogGalleryNeighbors(around id: UUID) {
        guard let index = catalogGalleryPhotos.firstIndex(where: { $0.id == id }) else { return }
        let neighbors: [PhotoItem] = [1, -1].compactMap { delta in
            let target = index + delta
            guard catalogGalleryPhotos.indices.contains(target) else { return nil }
            return catalogGalleryPhotos[target]
        }
        guard !neighbors.isEmpty else { return }
        Task {
            for photo in neighbors {
                if Task.isCancelled { break }
                if catalogGalleryViewerCache.object(forKey: photo.id.uuidString as NSString) != nil {
                    continue
                }
                guard let context = catalogGalleryContexts[photo.id] else { continue }
                var image = await CatalogArtworkCache.shared.image(source: context.source,
                                                                  urlString: context.urlString,
                                                                  quick: false)
                if image == nil {
                    image = await CatalogArtworkCache.shared.image(source: context.source,
                                                                   urlString: context.urlString,
                                                                   quick: true)
                }
                if let image {
                    catalogGalleryViewerCache.setObject(image, forKey: photo.id.uuidString as NSString)
                }
            }
        }
    }

    /// 只保存当前这一张：与「全部保存」共用同一套相簿结构与重复检测。
    func saveCatalogGalleryPhotoToLibrary(id: UUID) {
        guard let context = catalogGalleryContexts[id],
              let provider = CatalogProviders.provider(for: context.source.kind) else { return }
        let folders = context.folders.isEmpty
            ? ["网络图集", Self.galleryAlbumTitle(context.albumTitle)]
            : context.folders
        // 已经保存过这一张：先提示，让用户决定要不要重存。
        if let existing = catalogGalleryAlbum(at: folders)
            ?? catalogGalleryAlbum(at: ["网络图集", folders.last ?? ""]),
           catalogGalleryImportedIndexes(in: existing).contains(context.index + 1) {
            let choice = presentAlert(LibraryAlertRequest(
                title: "这张已经在图库里",
                message: "「\(folders.last ?? "相簿")」里已经有第 \(context.index + 1) 张。\n还要再保存一次吗？",
                buttons: ["取消", "仍然保存"]))
            guard choice == 1 else { return }
        } else if let similar = catalogGallerySimilarAlbum(to: folders.last ?? context.albumTitle) {
            // 目标相簿不存在，但图库里有名字很像的相册：同样先提醒。
            let similarPath = catalogGalleryAlbumPath(of: similar.album).joined(separator: " / ")
            let percent = Int((similar.score * 100).rounded())
            let choice = presentAlert(LibraryAlertRequest(
                title: "图库里已有相似的相册",
                message: "「\(similar.album.name)」在 \(similarPath)，与这套图集的名字相似度 \(percent)%。\n仍要保存这一张吗？",
                buttons: ["取消", "仍然保存"]))
            guard choice == 1 else { return }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let data = try? await provider.coverData(source: context.source,
                                                           urlString: context.urlString),
                  !data.isEmpty else {
                self.showToast("图片保存失败")
                return
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("luma-gallery-photo-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let ext = Self.galleryImageExtension(from: context.urlString)
            // 文件名与「全部保存」一致：下次再存同一张时能按序号识别出来。
            let file = directory.appendingPathComponent(
                String(format: "%03d", context.index + 1) + "." + ext)
            do {
                try data.write(to: file, options: .atomic)
                self.runImport(entries: [(url: file, folders: folders)],
                               options: ImportOptions())
            } catch {
                self.showToast("图片保存失败")
            }
        }
    }

    /// 关闭看图会话：虚拟照片只在本次浏览内有效。
    func finishCatalogGalleryViewer() {
        catalogGalleryPhotos = []
        catalogGalleryContexts = [:]
    }

    // MARK: - 播放

    /// 把一次网络资源播放接进查看器：每一集映射成一个虚拟视频，
    /// 这样左右翻页就是切集，播放控件与影院完全一致。
    func playCatalog(_ request: CatalogPlaybackRequest) {
        finishCatalogPlayback()

        var photos: [PhotoItem] = []
        var contexts: [UUID: CatalogPlaybackContext] = [:]
        for episode in request.episodes {
            let label = episode.name ?? "第 \(episode.index) 集"
            var photo = PhotoItem(
                filename: "catalog-\(request.item.id)-ep\(episode.index).m3u8",
                originalName: "\(request.item.title) \(label)",
                capturedAt: Date(),
                pixelWidth: 1920,
                pixelHeight: 1080,
                fileSize: 0,
                kind: .video
            )
            photo.title = "\(request.item.title) · \(label)"
            photo.source = .cloud
            photo.cloudPath = episode.pageURL
            photos.append(photo)
            contexts[photo.id] = CatalogPlaybackContext(source: request.source,
                                                        item: request.item,
                                                        episode: episode)
        }
        guard !photos.isEmpty else { return }

        catalogPlaybackPhotos = photos
        catalogPlaybackContexts = contexts
        // 从详情页起的播：记住返回目标，退出播放器后回到那一页详情。
        // 这里用详情页点播放时留下的标记，而不是比较 catalog.detail——
        // 详情刚打开还没加载完就点播放时，detail 可能仍然是 nil。
        if let returnItem = catalogModel.takePlaybackReturnItem(), returnItem.id == request.item.id {
            catalogReturnSourceID = request.source.id
            catalogReturnItem = returnItem
        } else {
            catalogReturnSourceID = nil
            catalogReturnItem = nil
        }
        catalogPendingSeek = request.startSeconds > 3 ? request.startSeconds : nil

        let start = min(request.startIndex, photos.count - 1)
        // 详情是页内视图，不再需要等弹层收起；立刻铺开查看器，点播放不再有半秒空窗。
        openViewer(photos[start].id, context: photos)
    }

    /// 自定义片单整单连播：把每部片的第一集铺成同一个查看器会话。
    func playCatalogPlaylist(_ items: [CatalogPlaylistPlaybackItem]) {
        finishCatalogPlayback()
        catalogReturnSourceID = nil
        catalogReturnItem = nil
        _ = catalogModel.takePlaybackReturnItem()

        var photos: [PhotoItem] = []
        var contexts: [UUID: CatalogPlaybackContext] = [:]
        for entry in items {
            var photo = PhotoItem(
                filename: "catalog-\(entry.item.id)-ep\(entry.episode.index).m3u8",
                originalName: entry.item.title,
                capturedAt: Date(),
                pixelWidth: 1920,
                pixelHeight: 1080,
                fileSize: 0,
                kind: .video
            )
            photo.title = entry.item.title
            photo.source = .cloud
            photo.cloudPath = entry.episode.pageURL
            photos.append(photo)
            contexts[photo.id] = CatalogPlaybackContext(source: entry.source,
                                                        item: entry.item,
                                                        episode: entry.episode)
        }
        guard let first = photos.first else { return }

        catalogPlaybackPhotos = photos
        catalogPlaybackContexts = contexts
        catalogPendingSeek = nil

        openViewer(first.id, context: photos)
    }

    /// 查看器当前的虚拟分集（非图库内容）。
    func catalogPlaybackPhoto(for id: UUID) -> PhotoItem? {
        catalogPlaybackPhotos.first(where: { $0.id == id })
    }

    func catalogPlaybackContext(for id: UUID) -> CatalogPlaybackContext? {
        catalogPlaybackContexts[id]
    }

    /// 关闭查看器 / 切走时落盘并释放虚拟分集。
    func finishCatalogPlayback() {
        if let viewerID, let context = catalogPlaybackContexts[viewerID] {
            let current = viewerModel.videoPlayer.currentTime
            let duration = viewerModel.videoPlayer.duration
            if duration > 0, current > 3 {
                playbackProgressStore.recordCatalogProgress(source: context.source,
                                                            item: context.item,
                                                            episode: context.episode.index,
                                                            seconds: current,
                                                            duration: duration)
            }
        }
        catalogPlaybackPhotos = []
        catalogPlaybackContexts = [:]
        catalogPendingSeek = nil
    }

    /// 关闭播放器后回到刚才的详情页：把条目交给频道页恢复内联详情。
    func restoreCatalogDetailIfNeeded() {
        guard let item = catalogReturnItem, let sourceID = catalogReturnSourceID else { return }
        catalogReturnItem = nil
        catalogReturnSourceID = nil
        catalogModel.pendingInlineItem = item
        catalogModel.focus(sourceID)
        navigate(to: .catalogSource(sourceID))
    }
}
