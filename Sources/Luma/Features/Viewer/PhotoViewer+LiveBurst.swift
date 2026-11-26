import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    // MARK: - 实况照片

    func livePhotoURL(for photo: PhotoItem) -> URL? {
        guard photo.isLivePhoto, !photo.isVideo,
              let url = LibraryPaths.livePhotoURL(for: photo),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func toggleLivePhoto() {
        guard let photo else { return }
        if livePlaying {
            stopLivePhoto()
            return
        }
        guard let url = livePhotoURL(for: photo) else {
            store.showToast("找不到实况照片的配对视频")
            return
        }
        let player = AVPlayer(url: url)
        livePlayer = player
        livePlaying = true
        liveEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                stopLivePhoto()
            }
        }
        player.play()
    }

    func stopLivePhoto() {
        livePlayer?.pause()
        livePlayer = nil
        livePlaying = false
        if let liveEndObserver {
            NotificationCenter.default.removeObserver(liveEndObserver)
            self.liveEndObserver = nil
        }
    }

    // MARK: - 连拍快照

    /// 播放 / 暂停连拍：按拍摄顺序逐帧切换，与官方「照片」的连播观感一致。
    func toggleBurstPlayback() {
        if viewer.burstPlaying {
            stopBurstPlayback()
            return
        }
        guard burstMembers.count > 1 else { return }
        guard let current = burstMembers.firstIndex(where: { $0.id == viewer.viewerID }) else { return }
        // 已经在最后一张时从头播放。
        if current == burstMembers.count - 1, let first = burstMembers.first {
            viewer.viewerID = first.id
        }
        viewer.burstPlaying = true
        burstPlayTask?.cancel()
        burstPlayTask = Task { @MainActor in
            // 约每秒 8 帧：既保留连拍的连续感，也给全尺寸解码留出时间。
            while !Task.isCancelled, viewer.burstPlaying {
                guard let position = viewer.burstMembers.firstIndex(where: { $0.id == viewer.viewerID }),
                      position + 1 < viewer.burstMembers.count else { break }
                try? await Task.sleep(nanoseconds: 125_000_000)
                guard !Task.isCancelled, viewer.burstPlaying else { break }
                let next = position + 1
                // 预取后两帧，播放时不会每帧都停在占位层。
                for offset in 1...2 where next + offset < viewer.burstMembers.count {
                    ImageLoader.prefetchDisplay(for: viewer.burstMembers[next + offset],
                                                sdr: !settings.viewFullHDR)
                }
                viewer.viewerID = viewer.burstMembers[next].id
            }
            if viewer.burstPlaying { viewer.burstPlaying = false }
        }
    }

    func stopBurstPlayback() {
        burstPlayTask?.cancel()
        burstPlayTask = nil
        viewer.burstPlaying = false
    }

    /// 进入「进行选择…」：停掉播放，从空选择开始。
    func beginBurstSelection() {
        stopBurstPlayback()
        viewer.burstSelection = []
        viewer.burstSelectionMode = true
    }

    /// 为窗口内浏览准备一张铺满舞台的缩略图；视频没有解码帧时也能拿到封面帧。
    /// 系统图库的缩略图可能正在后台生成，未就绪时短暂重试，避免舞台两侧一直是黑的。
    func loadBackdrop() async {
        backdropImage = nil
        // 设置里关闭背景虚化时不加载模糊底图，翻页少一次缩略图读取。
        guard settings.viewerBackdrop, let photo else { return }
        for _ in 0..<6 {
            guard !Task.isCancelled, store.viewerPhoto?.id == photo.id else { return }
            let loaded = await PhotoThumbnailLoader.load(photo: photo,
                                                         purpose: .cover(320),
                                                         store: store)
            guard !Task.isCancelled, store.viewerPhoto?.id == photo.id else { return }
            if let loaded {
                backdropImage = loaded
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    func load() async {
        stopLivePhoto()
        zoom = 1
        offset = .zero
        baseOffset = .zero
        pinchStartZoom = nil
        guard let photo else {
            image = nil
            animatedImage = nil
            placeholder = nil
            return
        }
        let fullHDR = settings.viewFullHDR
        if photo.isVideo {
            image = nil
            animatedImage = nil
            placeholder = nil
        } else {
            // 切换照片时先清掉上一张；占位层直接用网格里已解码的那一档，开图即有内容。
            image = nil
            animatedImage = nil
            placeholder = ImageLoader.cachedPreview(for: photo)

            let target = photo
            if target.isCloud {
                let loaded = await store.cloudDisplayImage(for: target)
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                let result = fullHDR ? loaded : loaded.map(ImageLoader.sdrImage)
                if placeholder == nil { image = result } else { show(result) }
            } else if let cached = ImageLoader.cachedDisplayImage(for: target, sdr: !fullHDR) {
                // 命中全尺寸缓存：直接出图，不做多余动画。
                image = cached
            } else {
                // 二级占位：磁盘上的 1200px 缩略图，比 192px 放大清晰得多。
                let medium = await Task.detached(priority: .userInitiated) {
                    ImageLoader.gridThumbnail(for: target, maxPixel: 1024)
                }.value
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                if let medium { placeholder = medium }
                prefetchQuickNeighbors(of: target)
                let loaded = await Task.detached(priority: .userInitiated) {
                    ImageLoader.displayImage(for: target, sdr: !fullHDR)
                }.value
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                if placeholder == nil {
                    image = loaded
                } else {
                    show(loaded)
                }
            }
            // 动图：额外取一份保留全部帧的图像，查看器里打开即循环播放。
            if target.playsAnimation {
                let animated: NSImage?
                if target.isCloud {
                    animated = await store.cloudAnimatedImage(for: target)
                } else {
                    animated = await Task.detached(priority: .userInitiated) {
                        ImageLoader.animatedImage(for: target)
                    }.value
                }
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                animatedImage = animated
            }
        }
        prefetchNeighbors(of: photo, fullHDR: fullHDR)
    }

    /// 全尺寸图就绪后直接替换占位层：切换照片不做淡入 / 位移，连翻时更干脆。
    func show(_ newImage: NSImage?) {
        image = newImage
    }

    /// 预取前后各两张的快速层，连翻时每一张都能立刻显示。
    func prefetchQuickNeighbors(of photo: PhotoItem) {
        let photos = items
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        for delta in [1, 2, -1, -2] {
            var next = index + delta
            if next < 0 { next += photos.count }
            if next >= photos.count { next -= photos.count }
            guard next >= 0, next < photos.count else { continue }
            let target = photos[next]
            guard !target.isVideo, !target.isCloud else { continue }
            ImageLoader.prefetchQuick(for: target)
            // 紧邻的一张额外预取 1024px 中等层，翻过去时占位更清晰。
            if abs(delta) == 1 {
                ImageLoader.prefetchMedium(for: target)
            }
        }
    }

    /// 预取前后各一张的全尺寸显示图。
    func prefetchNeighbors(of photo: PhotoItem, fullHDR: Bool) {
        let photos = items
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        for delta in [1, -1] {
            var next = index + delta
            if next < 0 { next = photos.count - 1 }
            if next >= photos.count { next = 0 }
            let target = photos[next]
            guard !target.isVideo, !target.isCloud else { continue }
            ImageLoader.prefetchDisplay(for: target, sdr: !fullHDR)
        }
    }
}
