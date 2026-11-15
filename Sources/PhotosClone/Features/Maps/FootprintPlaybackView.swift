import AppKit
import LumaCore
import MapKit
import SwiftUI

/// 足迹回放：把带定位的照片按时间顺序播成一段有镜头语言的旅程。
///
/// 与「一张大地图 + 一条线」的做法不同，这里每一段行程都单独运镜：
/// 镜头高度按本段距离缩放（街区级移动也会被放到满屏可见的尺度），
/// 光点沿大圆逐帧推进、轨迹随之生长，并配上胶片质感的相机 HUD。
struct FootprintPlaybackView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let photos: [PhotoItem]
    var onClose: () -> Void

    @State private var plan: FootprintPlan?
    @State private var sortedPhotos: [PhotoItem] = []
    @State private var density: [Double] = []
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var pinImages: [UUID: NSImage] = [:]
    @State private var camera: MapCameraPosition = .automatic
    @State private var stopIndex = 0
    @State private var head: FootprintPoint?
    @State private var legFraction: Double = 0
    @State private var playing = false
    @State private var speed: FootprintSpeed = .medium
    @State private var follow = true
    @State private var finished = false
    @State private var pulse = false
    @State private var isScrubbing = false
    @State private var scrubbingIndex = 0

    @AppStorage("map.footprintImagery") private var imagery = true

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            if let plan {
                if plan.isEmpty {
                    emptyState
                } else {
                    mapLayer(plan)
                    scrims
                    chrome(plan)
                    if finished {
                        completionCard(plan)
                    }
                }
            } else {
                loadingState
            }
        }
        .animation(settings.motion.overlay, value: finished)
        .onExitCommand { onClose() }
        .task { await run() }
    }

    // MARK: - 播放循环

    private func run() async {
        guard plan == nil else { return }
        let all = photos
        let built = await Task.detached(priority: .userInitiated) { () -> (plan: FootprintPlan, photos: [PhotoItem]) in
            let sorted = all.filter { $0.hasLocation }.sorted { $0.capturedAt < $1.capturedAt }
            let samples = sorted.map { photo in
                FootprintSample(time: photo.capturedAt,
                                point: FootprintPoint(latitude: photo.latitude ?? 0,
                                                      longitude: photo.longitude ?? 0),
                                placeKey: Self.placeKey(photo),
                                placeName: Self.placeName(photo))
            }
            return (FootprintPlanner.plan(samples: samples), sorted)
        }.value

        sortedPhotos = built.photos
        routeCoordinates = built.plan.stops.map { Self.coordinate($0.point) }
        density = Self.density(for: built.plan)
        stopIndex = 0
        head = built.plan.stops.first?.point
        // 先把镜头摆到全览，再让地图第一次出现，避免从默认区域跳过来。
        camera = .camera(Self.overviewCamera(built.plan))
        plan = built.plan
        pulse = true
        guard !built.plan.isEmpty else { return }

        loadPinImage(at: 0, in: built.plan)
        try? await Task.sleep(nanoseconds: 620_000_000)
        guard !Task.isCancelled else { return }
        playing = true

        while !Task.isCancelled {
            if playing, !finished {
                await advanceLeg(built.plan)
            } else {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    /// 推进一步：先运镜到本段的取景，再按帧把光点送过去。
    private func advanceLeg(_ plan: FootprintPlan) async {
        guard plan.legs.indices.contains(stopIndex) else {
            finish(plan)
            return
        }
        let leg = plan.legs[stopIndex]
        let from = plan.stops[stopIndex].point
        let to = plan.stops[stopIndex + 1].point
        let duration = max(0.2, leg.duration * speed.multiplier)

        if follow {
            let center = FootprintPlanner.interpolate(from: from, to: to, fraction: 0.5)
            withAnimation(.easeInOut(duration: max(0.28, duration * 0.92))) {
                camera = .camera(MapCamera(centerCoordinate: Self.coordinate(center),
                                           distance: leg.cameraDistance,
                                           heading: leg.heading,
                                           pitch: leg.pitch))
            }
        }

        let startFraction = legFraction
        let started = Date()
        while true {
            try? await Task.sleep(nanoseconds: 32_000_000)
            if Task.isCancelled { return }
            guard playing, !finished else { return }
            let elapsed = Date().timeIntervalSince(started)
            let progress = min(1, startFraction + elapsed / duration)
            legFraction = progress
            head = FootprintPlanner.interpolate(from: from, to: to, fraction: Self.smooth(progress))
            if progress >= 1 { break }
        }

        stopIndex += 1
        legFraction = 0
        head = to
        loadPinImage(at: stopIndex, in: plan)

        if plan.stops[stopIndex].photoCount >= 2 {
            let dwell = min(1.1, leg.dwell / max(0.35, speed.multiplier))
            try? await Task.sleep(nanoseconds: UInt64(max(0, dwell) * 1_000_000_000))
        }
    }

    private func finish(_ plan: FootprintPlan) {
        playing = false
        finished = true
        withAnimation(.easeInOut(duration: 1.5)) {
            camera = .camera(Self.overviewCamera(plan))
        }
    }

    private func togglePlay(_ plan: FootprintPlan) {
        if finished {
            replay(plan)
        } else {
            playing.toggle()
        }
    }

    private func replay(_ plan: FootprintPlan) {
        guard !plan.isEmpty else { return }
        stopIndex = 0
        legFraction = 0
        head = plan.stops.first?.point
        finished = false
        playing = true
        withAnimation(.easeInOut(duration: 1.0)) {
            camera = .camera(Self.overviewCamera(plan))
        }
    }

    private func seek(to index: Int) {
        guard let plan, plan.stops.indices.contains(index) else { return }
        playing = false
        finished = false
        stopIndex = index
        legFraction = 0
        head = plan.stops[index].point
        loadPinImage(at: index, in: plan)
        guard follow else { return }
        let distance = plan.legs.indices.contains(index)
            ? plan.legs[index].cameraDistance
            : (index > 0 ? plan.legs[index - 1].cameraDistance : 1_200)
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .camera(MapCamera(centerCoordinate: Self.coordinate(plan.stops[index].point),
                                       distance: distance,
                                       heading: 0,
                                       pitch: plan.legs.indices.contains(index) ? plan.legs[index].pitch : 42))
        }
    }

    // MARK: - 地图

    private func mapLayer(_ plan: FootprintPlan) -> some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: routeCoordinates)
                .stroke(Color.white.opacity(0.16),
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4, 8]))

            if visitedCoordinates.count > 1 {
                MapPolyline(coordinates: visitedCoordinates)
                    .stroke(Color.accentColor.opacity(0.20),
                            style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: visitedCoordinates)
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            }

            if let head, plan.stops.indices.contains(stopIndex), stopIndex < plan.stops.count - 1 {
                MapPolyline(coordinates: [Self.coordinate(plan.stops[stopIndex].point),
                                          Self.coordinate(head)])
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            }

            ForEach(trailIndices(plan), id: \.self) { index in
                Annotation("", coordinate: Self.coordinate(plan.stops[index].point), anchor: .center) {
                    trailDot
                }
            }

            if plan.stops.indices.contains(stopIndex) {
                Annotation("", coordinate: Self.coordinate(plan.stops[stopIndex].point), anchor: .bottom) {
                    stopPin(plan.stops[stopIndex])
                }
            }

            if let head {
                Annotation("", coordinate: Self.coordinate(head), anchor: .center) {
                    comet
                }
            }
        }
        .mapStyle(imagery ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
        .ignoresSafeArea()
    }

    /// 已走过的站点（不含逐帧光点，光点用两点折线单独绘制）。
    private var visitedCoordinates: [CLLocationCoordinate2D] {
        guard let plan, !plan.stops.isEmpty else { return [] }
        let end = min(stopIndex, plan.stops.count - 1)
        return (0...end).map { Self.coordinate(plan.stops[$0].point) }
    }

    /// 只画最近若干站的拖尾，避免上百个站点同时参与标注布局；当前站由照片图钉表示。
    private func trailIndices(_ plan: FootprintPlan) -> [Int] {
        guard !plan.stops.isEmpty else { return [] }
        let end = min(stopIndex - 1, plan.stops.count - 1)
        guard end >= 0 else { return [] }
        let start = max(0, end - 13)
        return Array(start...end)
    }

    private var trailDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    private var comet: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: 1.4)
                .frame(width: 24, height: 24)
                .scaleEffect(pulse ? 2.2 : 0.7)
                .opacity(pulse ? 0 : 0.7)
                .animation(.easeOut(duration: 1.7).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 13, height: 13)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        }
    }

    /// 当前站点的「照片图钉」：白色相框叠一张缩略图，像贴在桌面上的照片。
    private func stopPin(_ stop: FootprintStop) -> some View {
        VStack(spacing: -1) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let photo = representativePhoto(stop), let image = pinImages[photo.id] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 58, height: 58)
                            .clipped()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, height: 58)
                    }
                }
                .padding(4)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)

                if stop.photoCount > 1 {
                    Text("\(stop.photoCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .offset(x: 6, y: 4)
                }
            }
            PinTip()
                .fill(Color.white)
                .frame(width: 11, height: 7)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
        }
    }

    /// 地图标注里只放已解码的 NSImage，避免每帧重建异步缩略图视图。
    private func loadPinImage(at index: Int, in plan: FootprintPlan) {
        guard plan.stops.indices.contains(index) else { return }
        guard let photo = representativePhoto(plan.stops[index]) else { return }
        guard pinImages[photo.id] == nil else { return }
        Task {
            if let image = await PhotoThumbnailLoader.load(photo: photo, purpose: .cover(120), store: store) {
                pinImages[photo.id] = image
            }
        }
    }

    private func representativePhoto(_ stop: FootprintStop) -> PhotoItem? {
        guard !sortedPhotos.isEmpty else { return nil }
        let index = min(max(0, stop.sampleRange.upperBound), sortedPhotos.count - 1)
        return sortedPhotos[index]
    }

    private func photos(in stop: FootprintStop) -> [PhotoItem] {
        guard !sortedPhotos.isEmpty else { return [] }
        let lower = min(max(0, stop.sampleRange.lowerBound), sortedPhotos.count - 1)
        let upper = min(max(lower, stop.sampleRange.upperBound), sortedPhotos.count - 1)
        return Array(sortedPhotos[lower...upper].suffix(3))
    }

    // MARK: - 画面质感

    private var scrims: some View {
        ZStack {
            RadialGradient(colors: [.clear, .black.opacity(0.55)],
                           center: .center,
                           startRadius: 160,
                           endRadius: 1_100)
                .ignoresSafeArea()
            LinearGradient(stops: [.init(color: .black.opacity(0.62), location: 0),
                                   .init(color: .clear, location: 0.22),
                                   .init(color: .clear, location: 0.56),
                                   .init(color: .black.opacity(0.82), location: 1)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
            FilmGrain()
                .opacity(0.05)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    // MARK: - 叠层

    private func chrome(_ plan: FootprintPlan) -> some View {
        VStack(spacing: 0) {
            topBar(plan)
            Spacer(minLength: 8)
            readoutRow(plan)
            bottomPanel(plan)
        }
    }

    private func topBar(_ plan: FootprintPlan) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("足迹回放")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Text(rangeText(plan))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 8)

            glassButton(icon: imagery ? "globe.americas.fill" : "map.fill",
                        help: imagery ? "切换为标准地图" : "切换为卫星三维地图") {
                imagery.toggle()
            }

            glassButton(icon: follow ? "location.fill" : "location.slash",
                        tint: follow ? Color.accentColor : .white.opacity(0.72),
                        help: follow ? "镜头正在跟随足迹，点击改为自由查看" : "点击让镜头重新跟随足迹") {
                follow.toggle()
                if follow { seek(to: stopIndex) }
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.35), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.8) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private func glassButton(icon: String,
                             tint: Color = .white.opacity(0.85),
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.35), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.8) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func readoutRow(_ plan: FootprintPlan) -> some View {
        HStack(alignment: .bottom) {
            Text(coordinateText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(stampText)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.orange.opacity(0.92))
                .shadow(color: Color.orange.opacity(0.65), radius: 5)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    private func bottomPanel(_ plan: FootprintPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(dayText)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(yearText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text(placeText(plan))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    Text(detailText(plan))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                photoStack(plan)
            }
            .padding(.horizontal, 5)

            console(plan)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    // MARK: - 控制台

    private func console(_ plan: FootprintPlan) -> some View {
        VStack(spacing: 12) {
            timeline(plan)
            HStack(spacing: 13) {
                playButton(plan)

                Text("\(min(stopIndex + 1, plan.stops.count)) / \(plan.stops.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))

                Spacer(minLength: 8)

                Text("已走 \(traveledText(plan))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))

                speedSwitch

                Button { replay(plan) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("从头再放一次")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.black.opacity(0.68), Color.black.opacity(0.86)],
                                     startPoint: .top,
                                     endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                                             startPoint: .top,
                                             endPoint: .bottom),
                              lineWidth: 1)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.07))
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.top, 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
    }

    /// 胶片式时间条：竖条是每秒里的照片密度，拖动即可定位到某一站。
    private func timeline(_ plan: FootprintPlan) -> some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let buckets = max(1, density.count)
            let progress = timelineProgress(plan)
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let slot = size.width / CGFloat(buckets)
                    for (index, value) in density.enumerated() {
                        let height = max(2.5, CGFloat(value) * (size.height - 7) + 2.5)
                        let rect = CGRect(x: CGFloat(index) * slot + 0.6,
                                          y: size.height - height,
                                          width: max(1, slot - 1.2),
                                          height: height)
                        let isPlayed = (CGFloat(index) + 0.5) / CGFloat(buckets) <= CGFloat(progress)
                        context.fill(Path(roundedRect: rect,
                                          cornerRadius: min(rect.width / 2, 1.5)),
                                     with: .color(isPlayed ? Color.accentColor.opacity(0.95)
                                                           : .white.opacity(0.18)))
                    }
                }

                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .offset(x: CGFloat(progress) * width - 5.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !plan.stops.isEmpty else { return }
                        let ratio = min(1, max(0, value.location.x / width))
                        let index = Int((ratio * CGFloat(plan.stops.count - 1)).rounded())
                        if !isScrubbing || index != scrubbingIndex {
                            isScrubbing = true
                            scrubbingIndex = index
                            seek(to: index)
                        }
                    }
                    .onEnded { _ in isScrubbing = false }
            )
        }
        .frame(height: 26)
    }

    private func playButton(_ plan: FootprintPlan) -> some View {
        Button { togglePlay(plan) } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(LinearGradient(colors: [Color.accentColor.opacity(0.95),
                                                          Color.accentColor.opacity(0.62)],
                                                 startPoint: .top,
                                                 endPoint: .bottom))
                }
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: Color.accentColor.opacity(0.45), radius: 10, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(playing ? "暂停 (空格)" : "播放 (空格)")
    }

    private var speedSwitch: some View {
        HStack(spacing: 2) {
            ForEach(FootprintSpeed.allCases) { option in
                Button { speed = option } label: {
                    Text(option.title)
                        .font(.system(size: 10.5, weight: speed == option ? .bold : .regular))
                        .foregroundStyle(speed == option ? Color.black.opacity(0.85) : .white.opacity(0.65))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            if speed == option {
                                Capsule().fill(.white.opacity(0.88))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func photoStack(_ plan: FootprintPlan) -> some View {
        let items = plan.stops.indices.contains(stopIndex) ? photos(in: plan.stops[stopIndex]) : []
        return ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { offset, photo in
                Button {
                    store.openViewer(photo.id)
                    onClose()
                } label: {
                    PhotoThumbnailView(photo: photo, purpose: .filmstrip(120))
                        .frame(width: 54, height: 54)
                        .padding(3)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .rotationEffect(.degrees(Self.stackAngles[offset % Self.stackAngles.count]))
                        .offset(x: CGFloat(offset) * 7, y: CGFloat(offset) * 2.5)
                        .shadow(color: .black.opacity(0.45), radius: 7, y: 4)
                }
                .buttonStyle(.plain)
                .help("在查看器中打开 \(photo.displayTitle)")
            }
        }
        .frame(width: 96, height: 68, alignment: .trailing)
        .opacity(items.isEmpty ? 0 : 1)
        .animation(settings.motion.overlay, value: stopIndex)
    }

    // MARK: - 结束 / 空 / 加载

    private func completionCard(_ plan: FootprintPlan) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 5) {
                Text("这趟旅程")
                    .font(.system(size: 20, weight: .bold))
                Text(rangeText(plan))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 22) {
                summaryStat(Self.distanceText(plan.totalDistance), "总里程")
                summaryStat("\(plan.stops.count)", "站点")
                summaryStat("\(plan.places.count)", "地点")
                summaryStat("\(dayCount(plan))", "天")
            }

            HStack(spacing: 10) {
                Button("再看一遍") { replay(plan) }
                    .keyboardShortcut(.defaultAction)
                Button("完成") { onClose() }
            }
            .padding(.top, 2)
        }
        .padding(30)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private func summaryStat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text("没有带位置信息的照片")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("给照片补上拍摄地点后，就能把它们播成一段足迹。")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在整理这一路的足迹…")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - 文案

    private var currentDate: Date? {
        guard let plan, plan.stops.indices.contains(stopIndex) else { return nil }
        return plan.stops[stopIndex].lastTime
    }

    private var dayText: String {
        guard let date = currentDate else { return "—" }
        return Self.shortDayFormatter.string(from: date)
    }

    private var yearText: String {
        guard let date = currentDate else { return "" }
        return Self.yearFormatter.string(from: date)
    }

    private var stampText: String {
        guard let date = currentDate else { return "" }
        return Self.stampFormatter.string(from: date)
    }

    private var coordinateText: String {
        guard let point = head else { return "" }
        let lat = String(format: "%.4f", abs(point.latitude))
        let lon = String(format: "%.4f", abs(point.longitude))
        return "\(lat)°\(point.latitude >= 0 ? "N" : "S")  \(lon)°\(point.longitude >= 0 ? "E" : "W")"
    }

    private func placeText(_ plan: FootprintPlan) -> String {
        guard plan.stops.indices.contains(stopIndex) else { return "—" }
        let name = plan.stops[stopIndex].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名地点" : name
    }

    private func detailText(_ plan: FootprintPlan) -> String {
        guard plan.stops.indices.contains(stopIndex) else { return "" }
        let stop = plan.stops[stopIndex]
        var parts = ["第 \(stopIndex + 1) / \(plan.stops.count) 站"]
        if stop.photoCount > 1 { parts.append("\(stop.photoCount) 张照片") }
        if plan.legs.indices.contains(stopIndex) {
            parts.append("本段：\(plan.legs[stopIndex].caption)")
        }
        return parts.joined(separator: " · ")
    }

    private func rangeText(_ plan: FootprintPlan) -> String {
        guard let first = plan.firstTime, let last = plan.lastTime else { return "" }
        let start = Self.rangeFormatter.string(from: first)
        let end = Self.rangeFormatter.string(from: last)
        return start == end ? start : "\(start) – \(end)"
    }

    private func dayCount(_ plan: FootprintPlan) -> Int {
        guard let first = plan.firstTime, let last = plan.lastTime else { return 0 }
        return max(1, Int(last.timeIntervalSince(first) / 86_400) + 1)
    }

    private func timelineProgress(_ plan: FootprintPlan) -> Double {
        guard plan.stops.count > 1 else { return plan.isEmpty ? 0 : 1 }
        return min(1, max(0, (Double(stopIndex) + legFraction) / Double(plan.stops.count - 1)))
    }

    /// 里程读数随光点推进逐帧累加，像真实里程表一样跳动。
    private func traveledText(_ plan: FootprintPlan) -> String {
        guard plan.distanceToStop.indices.contains(stopIndex) else { return Self.distanceText(0) }
        var meters = plan.distanceToStop[stopIndex]
        if plan.legs.indices.contains(stopIndex) {
            meters += plan.legs[stopIndex].distance * legFraction
        }
        return Self.distanceText(meters)
    }

    // MARK: - 工具

    private static func coordinate(_ point: FootprintPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private static func overviewCamera(_ plan: FootprintPlan) -> MapCamera {
        let center = plan.stops.isEmpty
            ? FootprintPoint(latitude: 31.2304, longitude: 121.4737)
            : FootprintPlanner.interpolate(from: plan.stops[0].point,
                                           to: plan.stops[plan.stops.count - 1].point,
                                           fraction: 0.5)
        let distance = FootprintPlanner.overviewDistance(of: plan.stops.map(\.point))
        return MapCamera(centerCoordinate: coordinate(center), distance: distance, heading: 0, pitch: 0)
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    nonisolated private static func placeKey(_ photo: PhotoItem) -> String {
        let parts = [photo.placeCountry, photo.placeProvince, photo.placeCity, photo.placeDistrict]
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if parts.contains(where: { !$0.isEmpty }) { return parts.joined(separator: "|") }
        return String(format: "geo|%.2f|%.2f", photo.latitude ?? 0, photo.longitude ?? 0)
    }

    nonisolated private static func placeName(_ photo: PhotoItem) -> String {
        let key = PlaceClusterBuilder.key(for: photo).title
        return key.isEmpty ? "未命名地点" : key
    }

    private static func distanceText(_ meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int(meters.rounded())) 米"
        }
        if meters < 100_000 {
            return "\(Int((meters / 1_000).rounded())) 公里"
        }
        return "\((meters / 1_000).rounded().formatted()) 公里"
    }

    private static func density(for plan: FootprintPlan) -> [Double] {
        let buckets = min(120, max(12, plan.stops.count))
        guard !plan.stops.isEmpty else { return Array(repeating: 0, count: buckets) }
        var counts = [Double](repeating: 0, count: buckets)
        for (index, stop) in plan.stops.enumerated() {
            let bucket = min(buckets - 1, index * buckets / plan.stops.count)
            counts[bucket] += Double(stop.photoCount)
        }
        let peak = counts.max() ?? 0
        guard peak > 0 else { return counts }
        return counts.map { pow($0 / peak, 0.6) }
    }

    private static let stackAngles: [Double] = [-7, 5, -3]

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'yy  M  d"
        return formatter
    }()

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter
    }()
}

// MARK: - 速度

private enum FootprintSpeed: String, CaseIterable, Identifiable {
    case slow
    case medium
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow: return "慢"
        case .medium: return "中"
        case .fast: return "快"
        }
    }

    /// 时长倍率：越大越慢。
    var multiplier: Double {
        switch self {
        case .slow: return 1.55
        case .medium: return 1.0
        case .fast: return 0.6
        }
    }
}

// MARK: - 拟物零件

/// 图钉的针尖。
private struct PinTip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 覆盖在画面上的胶片颗粒：只生成一次，平铺铺满，避免每帧重算。
private struct FilmGrain: View {
    private static let texture: NSImage? = {
        let side = 128
        guard let context = CGContext(data: nil,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        var seed: UInt64 = 0x5EED_1234
        for y in 0..<side {
            for x in 0..<side {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = Double((seed >> 33) & 0xFF) / 255.0
                context.setFillColor(CGColor(gray: value, alpha: 0.55))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }()

    var body: some View {
        if let texture = Self.texture {
            Image(nsImage: texture)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
        }
    }
}
