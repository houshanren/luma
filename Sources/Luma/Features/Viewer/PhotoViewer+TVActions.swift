import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    // MARK: - 电视直播：工具栏动作

    /// 时移开关：进入时暂停直播回看刚过去的画面，再点一次回到直播边缘。
    func toggleTVTimeshift() {
        if viewer.tvTimeshiftActive {
            viewer.tvTimeshiftActive = false
            videoModel.requestSeek(to: max(0, videoModel.bufferedEndTime - 0.5))
            videoModel.play()
            store.showToast("已回到直播")
        } else {
            videoModel.pause()
            viewer.tvTimeshiftActive = true
        }
    }

    /// 顶栏中部的照片信息：地点 / 实况 / 拍摄时间 / 地理位置 / 序号。
    /// 单行紧凑排版，高度严格控制在工具栏内，既不裁切也不会把旁边的控件顶大。
    func viewerToolbarInfo(_ photo: PhotoItem) -> some View {
        let tvName = tvChannelName(for: photo)
        let title = burstTitle ?? tvName ?? infoTitle(for: photo)
        let showsLead = title != nil || photo.isLivePhoto
        return HStack(spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(-0.01)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if photo.isLivePhoto {
                liveTag
            }

            if showsLead {
                Capsule()
                    .fill(Color.primary.opacity(0.20))
                    .frame(width: 1, height: 12)
            }

            if tvName == nil {
                if photo.hasKnownCaptureDate {
                    captureStamp(photo.capturedAt, size: 11.5)
                } else {
                    Text("时间未知")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .lineLimit(1)
                }
            }

            if let place = infoPlaceLine(for: photo) {
                infoSeparator
                HStack(spacing: 2) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(place)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineLimit(1)
                }
            }

            if let currentIndex {
                infoSeparator
                progressRing
                HStack(spacing: 2) {
                    Text("\((currentIndex + 1).formatted())")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Text("/ \(totalCount.formatted())")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            // 工具栏底下可能是深色照片，必须用不透明度更高的材质托底才看得清。
            Capsule().fill(.regularMaterial)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .help(photo.displayTitle)
        .accessibilityElement(children: .combine)
    }

    /// 拍摄时间：年月日 + 时分秒。突出「月日」，时间整体弱化成次级信息；
    /// 秒不加强调色，保持顶栏安静。
    func captureStamp(_ date: Date, size: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(DateText.dayFormatter.string(from: date))
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary.opacity(0.95))
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 0.8, height: size - 2)
            Text(DateText.secondTimeFormatter.string(from: date))
                .foregroundStyle(Color.primary.opacity(0.58))
        }
        .font(.system(size: size, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("拍摄于 \(DateText.dayFormatter.string(from: date)) "
                            + DateText.secondTimeFormatter.string(from: date))
    }

    /// 实况标记：和地点、时间同一套信息语言，不再依赖画面上的角标。
    var liveTag: some View {
        HStack(spacing: 2) {
            Image(systemName: "livephoto")
                .font(.system(size: 8.5, weight: .semibold))
            Text("实况")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.accentColor.opacity(0.13), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(0.20), lineWidth: LumaControlMetrics.hairline)
        }
    }

    var infoSeparator: some View {
        Circle()
            .fill(Color.primary.opacity(0.28))
            .frame(width: 2.5, height: 2.5)
    }

    var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.28), lineWidth: 1.7)
            Circle()
                .trim(from: 0, to: progressFraction)
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .animation(settings.motion.overlay, value: progressFraction)
    }

    /// 缩放胶囊左侧的小圆环：随放大程度填充，让百分比多一层直觉读数。
    var zoomRing: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: zoomRingFraction)
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 9, height: 9)
    }

    /// 放大范围 1x–上限映射到圆环的 0–1。
    var zoomRingFraction: CGFloat {
        min(1, max(0, (zoom - 1) / (PhotoViewerView.maxZoom - 1)))
    }

    /// 连拍标题：与官方「照片」一致，显示整组的有效成员数。
    var burstTitle: String? {
        guard burstMembers.count > 1 else { return nil }
        return "连拍快照（\(burstMembers.count) 张照片）"
    }

    /// 连拍顶栏用带秒的时间，与官方「照片」的「09:22:40」一致。
    static let burstTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 顶栏主标题：与信息面板 / 网格地点标签同一套层级（街道 → 城市 → 区县 → 省 → 国家）。
    /// 没有地点信息时返回 nil，顶栏只显示时间与序号，不用文件名冒充标题。
    func infoTitle(for photo: PhotoItem) -> String? {
        photo.placeTitle
    }

    /// 电视直播的频道名：直播没有真实拍摄时间，顶栏用它替代日期时间。
    func tvChannelName(for photo: PhotoItem) -> String? {
        store.tvPlaybackChannel(for: photo.id)?.name
    }

    /// 地点副行：标题已占用街道时补城市 / 区县，标题是城市时补区县或省份。
    /// 没有地名但有坐标时显示经纬度；完全没有地理信息时整段隐藏。
    func infoPlaceLine(for photo: PhotoItem) -> String? {
        if let subtitle = photo.placeSubtitle { return subtitle }
        return coordinateText(for: photo)
    }

    /// 经纬度文案：地名还没解析出来时用它兜底，避免定位段整段消失。
    func coordinateText(for photo: PhotoItem) -> String? {
        guard let latitude = photo.latitude, let longitude = photo.longitude,
              CoordinateValidator.isValid(latitude: latitude, longitude: longitude) else {
            return nil
        }
        let lat = String(format: "%.2f°%@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat) · \(lon)"
    }

    /// 窗口内浏览的工具栏：返回、缩放、拍摄时间 / 序号、操作。
    @ToolbarContentBuilder
    var embeddedToolbar: some ToolbarContent {
        @Bindable var viewer = viewer
        if let photo {
            ToolbarItem(placement: .navigation) {
                // 返回与视频播放控制放在同一个工具栏项里：系统会把它们收进同一块玻璃胶囊，
                // 和照片模式一样只占最左侧一条，不再多出一块悬空的控制条。
                HStack(spacing: 8) {
                    Button {
                        // 视频全屏里「返回」只退出系统全屏：画面继续播放，查看器不关、不回列表。
                        if viewer.videoImmersiveFullScreen {
                            FullScreenDiagnostics.log("toolbarBack -> exit fullscreen")
                            hostWindow?.toggleFullScreen(nil)
                        } else {
                            FullScreenDiagnostics.log("toolbarBack -> close viewer")
                            store.closeViewer()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(viewer.videoImmersiveFullScreen ? "退出全屏 (Esc)" : "返回图库 (Esc)")

                    if showsVideoToolbarControls {
                        let episodeMode = store.usesEpisodeTransport(for: photo)
                        VideoToolbarTransport(model: videoModel,
                                              hasPrev: episodeMode
                                                  ? store.hasAdjacentVideo(from: photo.id, delta: -1) : true,
                                              hasNext: episodeMode
                                                  ? store.hasAdjacentVideo(from: photo.id, delta: 1) : true,
                                              onPrev: {
                            if episodeMode {
                                store.viewerStepVideo(-1)
                            } else {
                                store.viewerStep(-1)
                            }
                        },
                                              onNext: {
                            if episodeMode {
                                store.viewerStepVideo(1)
                            } else {
                                store.viewerStep(1)
                            }
                        },
                                              seekStep: settings.videoSeekStep,
                                              episodeMode: episodeMode)
                    }
                }
                .padding(.horizontal, showsVideoToolbarControls ? 3 : 0)
            }

            // 连拍选择模式：与官方「照片」一致，左上角显示「连拍快照（N张照片）」。
            if viewer.burstSelectionMode, !burstMembers.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Text(burstTitle ?? "连拍快照")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ToolbarItem(placement: .navigation) {
                // 工具栏里不再放整条缩放滑杆（在玻璃工具栏里会撑成一条空白长条）；
                // 只在放大后显示一个紧凑的缩放胶囊，点一下回到适应窗口。
                if zoom > 1.01 {
                    Button {
                        resetZoom()
                    } label: {
                        // 背景与内容放在同一个固定尺寸的容器里：
                        // 之前胶囊按内容自适应，工具栏会在缩放时把它压窄，百分比就溢出到胶囊外。
                        ZStack {
                            Capsule().fill(Color.accentColor.opacity(0.14))
                            Capsule().strokeBorder(
                                LinearGradient(colors: [Color.accentColor.opacity(0.55),
                                                        Color.accentColor.opacity(0.15)],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing),
                                lineWidth: LumaControlMetrics.hairline)
                            HStack(spacing: 4) {
                                zoomRing
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .fixedSize()
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 64, height: 20)
                        .contentShape(Capsule())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("恢复到适应窗口 (0)")
                    .animation(settings.motion.overlay, value: zoom)
                }
            }

            // 地点 / 实况 / 拍摄时间 / 序号：与顶部工具栏同一行；连拍时换成官方的两行信息。
            ToolbarItem(placement: .principal) {
                if showsVideoToolbarControls {
                    videoToolbarDeck(photo)
                } else {
                    principalInfo(photo)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewer.burstSelectionMode, !burstMembers.isEmpty {
                    // 与官方「照片」一致：完成选择只保留「取消 / 完成」两个按钮。
                    Button("取消") {
                        endBurstSelection()
                    }
                    .help("取消连拍选择")

                    Button("完成") {
                        endBurstSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .help("完成连拍选择")
                } else {
                    // 视频规格与照片操作共用同一块操作胶囊：
                    // 播放选项 / 全屏排在信息、胶片条等照片操作之前，顺序与参考图一致。
                    if showsVideoToolbarControls {
                        VideoToolbarOptions(model: videoModel,
                                            settings: settings,
                                            quarterTurns: viewer.videoQuarterTurns,
                                            onRotate: rotateVideoPlayer,
                                            onCapture: captureVideoFrame)
                        VideoDeckButton(icon: "arrow.up.left.and.arrow.down.right",
                                        help: "全屏 (F)",
                                        action: toggleVideoFullScreen)

                        // 电视频道：直播动作 + 频道动作全部收进工具栏，
                        // 与画面 OSD 共用同一个动作组，顺序与行为不会各写一套。
                        if let channel = store.tvPlaybackChannel(for: photo.id) {
                            TVChannelActionCluster(channel: channel,
                                                   photoID: photo.id,
                                                   isLive: !channel.isCatchUp,
                                                   timeshiftActive: $viewer.tvTimeshiftActive,
                                                   showGuide: $viewer.tvGuideShown,
                                                   style: .toolbar,
                                                   onToggleTimeshift: toggleTVTimeshift,
                                                   onCapture: captureVideoFrame)
                        }
                    }

                    // 电视频道：信息 / 胶片条 / 共享 / 收藏照片 / 幻灯片 / 编辑这些照片向操作没有意义，
                    // 全部交给播放页的频道工具，工具栏只保留播放器通用能力。
                    if store.tvPlaybackChannel(for: photo.id) == nil {
                        Button {
                            viewer.showInfoPanel.toggle()
                        } label: {
                            Image(systemName: viewer.showInfoPanel ? "info.circle.fill" : "info.circle")
                        }
                        .help("信息")

                        // 连拍的帧条只在选择模式浮出，普通浏览时不提供胶片条开关。
                        if burstMembers.isEmpty {
                            Button {
                                settings.viewerFilmstrip.toggle()
                            } label: {
                                Image(systemName: "film")
                            }
                            .foregroundStyle(settings.viewerFilmstrip ? Color.accentColor : Color.primary)
                            .help(settings.viewerFilmstrip ? "隐藏底部缩略图" : "显示底部缩略图")
                        }

                        ShareLink(items: store.shareURLs) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(store.shareURLs.isEmpty)
                        .help("共享")

                        if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                            Button {
                                store.toggleFavorite(photo.id)
                            } label: {
                                Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                            }
                            .foregroundStyle(photo.isFavorite ? Color.pink : Color.primary)
                            .help(photo.isFavorite ? "取消收藏" : "收藏")
                        }

                        if !photo.isVideo, (!photo.isReadOnly || photo.isSystem), store.canScanBeauty {
                            Button {
                                store.showBeautyPanel = true
                            } label: {
                                Image(systemName: "wand.and.stars")
                            }
                            .help("智能美化…")
                        }

                        Button {
                            store.presentSlideshow()
                        } label: {
                            Image(systemName: "play.rectangle")
                        }
                        .disabled(store.visibleCount == 0)
                        .help("幻灯片播放")

                        if burstMembers.count > 1 {
                            Button {
                                toggleBurstPlayback()
                            } label: {
                                Image(systemName: viewer.burstPlaying ? "pause.fill" : "play.fill")
                            }
                            .help(viewer.burstPlaying ? "暂停连拍播放 (P)" : "播放连拍快照 (P)")
                        }

                        moreMenu(photo)

                        if !photo.isVideo,
                           !photo.isReadOnly || (photo.isSystem && store.canWriteSystemLibrary) {
                            Button {
                                store.openEditor(photo.id)
                            } label: {
                                Text("编辑")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("编辑照片")
                        }
                    }
                }
            }
        }
    }

    /// 顶栏中部信息：连拍时按官方「照片」排成两行（标题 / 连拍标签 + 日期 + 组内序号）。
    @ViewBuilder
    func principalInfo(_ photo: PhotoItem) -> some View {
        if burstMembers.isEmpty {
            viewerToolbarInfo(photo)
        } else if viewer.burstSelectionMode {
            // 选择模式：上行「日期 时间 · i/N」，下行「进行选择」。
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(DateText.dayFormatter.string(from: photo.capturedAt))
                    Text(Self.burstTimeFormatter.string(from: photo.capturedAt))
                    if let currentIndex {
                        Text("·")
                        Text("\(currentIndex + 1)/\(burstMembers.count)")
                            .contentTransition(.numericText())
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

                Text("进行选择")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
        } else {
            // 普通浏览：上行地点标题，下行「连拍快照（N张照片） · 日期 时间 · i/N」。
            VStack(spacing: 1) {
                if let title = infoTitle(for: photo) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(-0.01)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(burstTitle ?? "连拍快照")
                    Text("·")
                    Text(DateText.dayFormatter.string(from: photo.capturedAt))
                    Text(Self.burstTimeFormatter.string(from: photo.capturedAt))
                    if let currentIndex {
                        Text("·")
                        Text("\(currentIndex + 1)/\(burstMembers.count)")
                            .contentTransition(.numericText())
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 退出连拍选择模式（取消与完成都只收起选择，不改动照片）。
    func endBurstSelection() {
        viewer.burstSelectionMode = false
        viewer.burstSelection = []
    }

    func stage(_ photo: PhotoItem) -> some View {
        @Bindable var viewer = viewer
        return GeometryReader { proxy in
            // 角标要打在照片本身上：先按实际显示尺寸算出照片在舞台里的留边，
            // 竖图 / 宽图两侧或上下的空白区域不能出现「人像」「实况」和定位图钉。
            let shownForBadges = image ?? animatedImage ?? placeholder
            let fittedForBadges = shownForBadges.map { fittedSize($0, in: proxy.size) } ?? proxy.size
            let imageInsetX = max(0, (proxy.size.width - fittedForBadges.width) / 2)
            let imageInsetY = max(0, (proxy.size.height - fittedForBadges.height) / 2)
            // 全屏时顶部还有一排 chrome 按钮，角标再往下让一档。
            let badgeTop = max(imageInsetY + 14, embedded ? 14 : 58)
            ZStack {
                if photo.isVideo {
                    // 视频只缩放画面本身，播放控件保持原尺寸；放大后同样可以拖动。
                    VideoPlayerStage(photo: photo,
                                     model: videoModel,
                                     ui: videoUI,
                                     quarterTurns: $viewer.videoQuarterTurns,
                                     onCaptureFrame: { captureVideoFrame() },
                                     transparentBackground: embedded,
                                     zoom: zoom,
                                     offset: offset)
                        .simultaneousGesture(magnifyGesture(stage: proxy.size, fitted: proxy.size))
                        .simultaneousGesture(panGesture(
                            stage: proxy.size,
                            fitted: proxy.size,
                            bottomGuard: settings.videoControlPlacement == .topIntegrated && embedded ? 0 : 170))
                } else if livePlaying, let livePlayer {
                    // 实况就在照片原位播放：尺寸与静态照片完全一致，
                    // 不走视频播放器，也不显示时长 / 进度 / 播放信息。
                    let fitted = image.map { fittedSize($0, in: proxy.size) }
                    LivePhotoLayerView(player: livePlayer)
                        .frame(width: fitted?.width ?? proxy.size.width,
                               height: fitted?.height ?? proxy.size.height)
                } else if photo.playsAnimation, let animated = animatedImage {
                    // 动图在查看器里直接播放，不需要额外的播放按钮。
                    let fitted = fittedSize(animated, in: proxy.size)
                    AnimatedImageView(image: animated)
                        .frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .shadow(color: .black.opacity(embedded ? 0.28 : 0),
                                radius: embedded ? 20 : 0,
                                y: embedded ? 8 : 0)
                } else if let shown = image ?? placeholder {
                    let fitted = fittedSize(shown, in: proxy.size)
                    ZStack {
                        // 占位层一直垫在下面，全尺寸图淡入时不会出现“先糊后清”的跳变。
                        if let placeholder {
                            Image(nsImage: placeholder)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                        }
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(offset)
                    .shadow(color: .black.opacity(embedded ? 0.28 : 0),
                            radius: embedded ? 20 : 0,
                            y: embedded ? 8 : 0)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(embedded ? Color.secondary : Color.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { stageSize = proxy.size }
            .onChange(of: proxy.size) { _, size in stageSize = size }
            .overlay {
                if !photo.isVideo, let shown = image ?? animatedImage ?? placeholder, !livePlaying {
                    let fitted = fittedSize(shown, in: proxy.size)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    toggleZoom(at: value.location, stage: proxy.size, fitted: fitted)
                                }
                        )
                        .simultaneousGesture(magnifyGesture(stage: proxy.size, fitted: fitted))
                        .simultaneousGesture(panGesture(stage: proxy.size, fitted: fitted))
                }
            }
            .clipped()
            // 画面角标：连拍「进行选择…」与 RAW / 人像 / 实况角标一起贴在照片左上内侧；
            // 已识别并命名的人物，名字紧跟角标打在照片上。
            .overlay(alignment: .topLeading) {
                let names = showsStageBadges(photo) ? store.personNames(for: photo.id) : []
                VStack(alignment: .leading, spacing: 6) {
                    if burstMembers.count > 1, !viewer.burstSelectionMode {
                        burstSelectBadge
                    }
                    if showsStageBadges(photo), hasStageBadgeContent(photo) {
                        HStack(spacing: 6) {
                            if photo.isRAWFile {
                                rawBadge
                            }
                            if photo.isPortraitCapture {
                                portraitBadge
                                    .allowsHitTesting(false)
                            }
                            if livePhotoURL(for: photo) != nil {
                                Button {
                                    toggleLivePhoto()
                                } label: {
                                    liveStageBadge
                                }
                                .buttonStyle(.plain)
                                .help("播放实况照片 (L)")
                            }
                        }
                    }
                    if showsStageBadges(photo), !names.isEmpty {
                        personNameRow(names)
                    }
                }
                .padding(.leading, imageInsetX + 14)
                .padding(.top, badgeTop)
            }
            .overlay(alignment: .topTrailing) {
                if showsStageBadges(photo), photo.hasLocation {
                    locationBadge
                        .padding(.trailing, imageInsetX + 14)
                        .padding(.top, badgeTop)
                }
            }
            // 连拍选择模式：照片右下角的圆形勾选，与官方「照片」一致，点按勾选当前这一张。
            .overlay(alignment: .bottomTrailing) {
                if viewer.burstSelectionMode, !burstMembers.isEmpty {
                    Button {
                        store.toggleBurstSelection(photo.id)
                    } label: {
                        Image(systemName: viewer.burstSelection.contains(photo.id)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, imageInsetX + 16)
                    .padding(.bottom, imageInsetY + 16)
                    .help(viewer.burstSelection.contains(photo.id) ? "取消勾选这张" : "勾选这张")
                }
            }
        }
    }

    /// 照片本体上的左上角标（RAW / 人像 / 实况）是否有内容。
    func hasStageBadgeContent(_ photo: PhotoItem) -> Bool {
        photo.isRAWFile || photo.isPortraitCapture || livePhotoURL(for: photo) != nil
    }

    /// 照片本体上的角标只在静态照片、未缩放时出现；实况播放与放大查看时让位给画面。
    func showsStageBadges(_ photo: PhotoItem) -> Bool {
        guard !photo.isVideo, !livePlaying, zoom <= 1.01 else { return false }
        return hasStageBadgeContent(photo) || photo.hasLocation
            || !store.personNames(for: photo.id).isEmpty
    }
}
