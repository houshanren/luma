import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 节目单

/// 节目回看的三种看法：横向时间轴看「谁在播什么」，传送门回到某一天，环形表盘看「这一天怎么走」。
enum TVGuideMode: String, CaseIterable, Identifiable {
    case timeline
    case portal
    case ring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "时间轴"
        case .portal: return "传送门"
        case .ring: return "时间环"
        }
    }

    var symbol: String {
        switch self {
        case .timeline: return "rectangle.split.3x1"
        case .portal: return "sparkles"
        case .ring: return "circle.dashed"
        }
    }
}

/// 节目单：优先回答「现在播什么、接下来是什么」。
/// 数据来自 M3U 头部的 XMLTV 地址；没有 EPG 时明确说明，不伪造节目。
struct TVGuideView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv

    /// Guide 是「时间轴视图」：今天 / 明天，两小时窗口，30 分钟一格。
    /// 选中日期放在模型里，顶部工具栏的分页胶囊同步显示「N 个频道有节目单 · 昨天」。
    /// 非 mutating setter 让页面里已有的 `dayOffset = n` 写法继续可用。
    private var dayOffset: Int {
        get { min(2, max(-2, tv.guideDayOffset)) }
        nonmutating set { tv.guideDayOffset = min(2, max(-2, newValue)) }
    }
    @State private var windowHour = Calendar.current.component(.hour, from: Date())
    @State private var selected: TVEPGProgram?
    /// 时间轴：鼠标悬停的节目，只影响那一块的高亮。
    @State private var hoveredGuideProgramID: String?

    /// 节目回看的三种视图，默认落在时间轴。
    @AppStorage("tv.guideMode.v2") private var guideModeRaw = TVGuideMode.timeline.rawValue
    /// 时间环：选中频道、拖动时间、悬停时间（限频）。
    @State private var guideChannelID: String?
    /// 时间环「回到现在」的信号：把表盘指针收回此刻。
    @State private var ringResetTick = 0
    /// 「有节目的频道」缓存：避免每次重绘都遍历上千频道并排序。
    @State private var guideChannelsCache: [TVChannel] = []
    @State private var guideChannelsKey = ""
    /// 当前频道当天的节目缓存。
    @State private var ringProgramsCache: [TVEPGProgram] = []
    @State private var ringProgramsKey = ""

    private let channelColumnWidth: CGFloat = 200
    private let guideRowHeight: CGFloat = 58
    private let slotMinutes = 30
    /// 时间轴时间窗：默认 2 小时，可拖动调整到 1–12 小时。
    @State private var windowHours: Double = 2
    @State private var windowDragStartHours: Double?

    private var clampedWindowHours: Double {
        min(12, max(1, windowHours))
    }

    /// 刻度的格子数：固定 30 分钟一格，窗口拉长后格子变多。
    private var slotCount: Int {
        max(2, Int((clampedWindowHours * 60 / Double(slotMinutes)).rounded()))
    }

    /// 时间窗不能跨过午夜。
    private var maxWindowHour: Int {
        max(0, 24 - Int(ceil(clampedWindowHours)))
    }

    private var selectedDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    private var guideMode: TVGuideMode {
        TVGuideMode(rawValue: guideModeRaw) ?? .timeline
    }

    private var windowStart: Date {
        Calendar.current.date(bySettingHour: windowHour,
                              minute: 0,
                              second: 0,
                              of: selectedDay) ?? selectedDay
    }

    private var windowEnd: Date {
        windowStart.addingTimeInterval(clampedWindowHours * 3600)
    }

    /// 缓存键：日期 / EPG 规模变化时才重算。
    private var guideCacheKey: String {
        "\(selectedDay.timeIntervalSince1970)-\(tv.epgPrograms.count)-\(tv.visibleChannels.count)-\(tv.epgUpdatedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// 只读缓存：计算交给 `.task(id:)`，body 里绝不做全量遍历，
    /// 否则首帧 / 拖动时会用上千个频道反复卡住主线程。
    private var channelsWithEPG: [TVChannel] {
        guideChannelsCache
    }

    private func computeChannelsWithEPG() -> [TVChannel] {
        tv.channelsWithPrograms(on: selectedDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            if let selected, guideMode == .timeline {
                detailBand(selected)
                Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            }
            content
        }
        .task { tv.loadEPGIfNeeded() }
        // 名单与节目只在数据变化时重算一次，滚动 / 悬停 / 拖动都直接读缓存。
        .task(id: guideCacheKey) {
            let key = guideCacheKey
            let channels = computeChannelsWithEPG()
            guideChannelsCache = channels
            guideChannelsKey = key
        }
        .task(id: ringProgramsKeyNow) {
            let key = ringProgramsKeyNow
            let programs = computeRingPrograms()
            ringProgramsCache = programs
            ringProgramsKey = key
        }
        .onChange(of: dayOffset) { _, _ in
            selected = nil
            let hour = dayOffset == 0 ? Calendar.current.component(.hour, from: Date()) : 19
            windowHour = min(maxWindowHour, max(0, hour))
        }
        // 时间窗变长后起点不能越界；变短时不额外挪动。
        .onChange(of: windowHours) { _, _ in
            windowHour = min(maxWindowHour, max(0, windowHour))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                // 日期只看五天：前天 / 昨天 / 今天 / 明天 / 后天。历史用于回看，未来用于预约。
                ForEach(Array(-2...2), id: \.self) { offset in
                    dayChip(offset)
                }

                Rectangle()
                    .fill(TVBrand.hairline)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                modeSwitcher

                Rectangle()
                    .fill(TVBrand.hairline)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                if guideMode == .timeline {
                    windowButton("chevron.left", help: "往前一小时") { shiftWindow(-1) }
                    windowChip
                    windowButton("chevron.right", help: "往后一小时") { shiftWindow(1) }
                    Button("回到现在") { jumpToNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TVBrand.wave)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                } else {
                    Button("回到现在") { jumpRingToNow() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(TVBrand.gold.opacity(0.12), in: Capsule(style: .continuous))
                }

                refreshButton

                // 节目单最近一次刷新时间：从标题栏挪回内容页，贴着刷新按钮。
                if let updated = tv.epgUpdatedAt {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("节目单最近一次成功刷新的时间")
                }

                Spacer(minLength: 0)
                if guideMode == .timeline { legend }
            }

            if let error = tv.epgError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TVBrand.warning)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func dayChip(_ offset: Int) -> some View {
        let active = dayOffset == offset
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { dayOffset = offset }
        } label: {
            Text(guideDayTitle(offset))
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? TVBrand.onWave : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(active ? TVBrand.wave : TVBrand.panel,
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help(fullDayTitle(offset))
    }

    /// 标题：大前天 / 前天 / 昨天 / 今天 / 明天 / 后天 / 大后天。
    private func guideDayTitle(_ offset: Int) -> String {
        switch offset {
        case -3: return "大前天"
        case -2: return "前天"
        case -1: return "昨天"
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case 3: return "大后天"
        default:
            guard let date = Calendar.current.date(byAdding: .day, value: offset,
                                                   to: Calendar.current.startOfDay(for: Date()))
            else { return "—" }
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
    }

    /// 悬浮提示：带具体日期。
    private func fullDayTitle(_ offset: Int) -> String {
        guard let date = Calendar.current.date(byAdding: .day, value: offset,
                                               to: Calendar.current.startOfDay(for: Date()))
        else { return guideDayTitle(offset) }
        return "\(guideDayTitle(offset)) · \(date.formatted(.dateTime.month(.defaultDigits).day().weekday(.wide)))"
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(TVGuideMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.24)) {
                        guideModeRaw = mode.rawValue
                        selected = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 10.5,
                                          weight: guideMode == mode ? .semibold : .regular))
                    }
                    .foregroundStyle(guideMode == mode ? TVBrand.onWave : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        if guideMode == mode {
                            Capsule(style: .continuous).fill(TVBrand.wave)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode == .ring ? "环形表盘：拖动看一天"
                      : (mode == .portal ? "传送门：回到某一天的节目" : "横向时间轴"))
            }
        }
        .padding(2)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
    }

    private var refreshButton: some View {
        Button {
            tv.reloadEPG()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text("刷新节目单")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(tv.isLoadingEPG)
        .help("重新拉取节目单（主源 + 补充源）")
    }

    private func windowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(TVBrand.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 时间窗读数：带上具体日期，避免只看到时间不知道是哪一天。
    /// 左右拖动胶囊可把窗口从 1 小时拉到 12 小时。
    private var windowChip: some View {
        HStack(spacing: 6) {
            Text(guideDayTitle(dayOffset))
                .foregroundStyle(TVBrand.gold.opacity(0.9))
            Text(selectedDay.formatted(.dateTime.month(.defaultDigits).day()))
                .foregroundStyle(Color.primary.opacity(0.62))
            Rectangle()
                .fill(TVBrand.hairline)
                .frame(width: 1, height: 10)
            Text("\(clock(windowStart)) – \(clock(windowEnd))")
                .foregroundStyle(Color.primary.opacity(0.82))
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(TVBrand.wave.opacity(0.85))
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        .fixedSize()
        .contentShape(Capsule(style: .continuous))
        .gesture(windowResizeGesture)
        .help("左右拖动调整时间窗（1–12 小时）")
    }

    /// 横向拖动换算成窗口长度：30pt ≈ 1 小时，按半小时吸附。
    private var windowResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = windowDragStartHours ?? clampedWindowHours
                windowDragStartHours = base
                let hours = base + value.translation.width / 30
                windowHours = min(12, max(1, (hours * 2).rounded() / 2))
            }
            .onEnded { _ in
                windowDragStartHours = nil
            }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendDot(TVBrand.signal.opacity(0.75), "正在播")
            legendDot(TVBrand.wave.opacity(0.75), "可回看 / 已播")
            legendDot(Color.primary.opacity(0.14), "无节目")
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func shiftWindow(_ delta: Int) {
        windowHour = min(maxWindowHour, max(0, windowHour + delta))
        selected = nil
    }

    private func jumpToNow() {
        dayOffset = 0
        windowHour = min(maxWindowHour,
                         max(0, Calendar.current.component(.hour, from: Date())))
        withAnimation(.easeOut(duration: 0.2)) { selected = nil }
    }

    private func jumpRingToNow() {
        dayOffset = 0
        ringResetTick &+= 1
        withAnimation(.easeOut(duration: 0.2)) { selected = nil }
    }

    @ViewBuilder
    private var content: some View {
        if tv.isLoadingEPG, tv.epgPrograms.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在拉取节目单…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tv.epgPrograms.isEmpty {
            emptyState
        } else if channelsWithEPG.isEmpty {
            if dayOffset != 0 {
                emptyState(message: "\(guideDayTitle(dayOffset))还没有节目单。EPG 只覆盖源站已发布的日期，换一天或刷新节目单试试。")
            } else {
                emptyState(message: "已经拿到 EPG，但没有频道能匹配上。检查源的 tvg-id 是否与 XMLTV 一致。")
            }
        } else {
            switch guideMode {
            case .timeline:
                timeline
                    .transition(.opacity)
            case .portal:
                guidePortal
                    .transition(.opacity)
            case .ring:
                guideRing
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
    }

    /// 时间轴：左侧固定频道列，右侧两小时窗口。
    /// 节目按真实起止时间铺成连续的块，跨半点不再被切成重复的两格。
    private var timeline: some View {
        GeometryReader { proxy in
            let gridWidth = max(520, proxy.size.width - channelColumnWidth - 44)
            let slotWidth = gridWidth / CGFloat(slotCount)
            ScrollView {
                LazyVStack(spacing: 0) {
                    timeHeader(slotWidth: slotWidth)
                    ForEach(channelsWithEPG) { channel in
                        timelineRow(channel: channel, slotWidth: slotWidth)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
                .overlay(alignment: .topLeading) {
                    nowLine(slotWidth: slotWidth)
                }
            }
        }
    }

    /// 表头：整点更重、半点更轻，像一条真实的刻度尺。
    private func timeHeader(slotWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("频道")
                Text("\(channelsWithEPG.count)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: channelColumnWidth, height: 34, alignment: .leading)

            ForEach(0..<slotCount, id: \.self) { slot in
                let minute = Calendar.current.component(.minute, from: slotStart(slot))
                // 窗口拉长后格子变窄，只保留整点读数，避免时间串在一起。
                let showsLabel = slotWidth >= 54 || minute == 0
                Text(showsLabel ? clock(slotStart(slot)) : "")
                    .font(.system(size: minute == 0 ? 10.5 : 9,
                                  weight: minute == 0 ? .semibold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(minute == 0 ? Color.primary.opacity(0.72)
                                                 : Color.secondary.opacity(0.55))
                    .frame(width: slotWidth, height: 34, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(minute == 0 ? TVBrand.hairline : TVBrand.hairline.opacity(0.45))
                            .frame(height: 0.6)
                    }
            }
        }
        .frame(height: 34)
    }

    private func timelineRow(channel: TVChannel, slotWidth: CGFloat) -> some View {
        let isPlaying = channel.id == playingChannelID
        return HStack(spacing: 0) {
            channelCell(channel, isPlaying: isPlaying)
            programTrack(channel: channel, slotWidth: slotWidth)
        }
        .frame(height: guideRowHeight)
        .background {
            if isPlaying { TVBrand.signal.opacity(0.045) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(TVBrand.hairline.opacity(0.55)).frame(height: 0.5)
        }
    }

    private func channelCell(_ channel: TVChannel, isPlaying: Bool) -> some View {
        Button {
            store.openTVChannel(channel)
        } label: {
            HStack(spacing: 9) {
                Text(String(format: "%02d", tv.channelNumber(for: channel)))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isPlaying ? TVBrand.signal
                                               : Color.secondary.opacity(0.7))
                    .frame(width: 24, alignment: .leading)
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 36, height: 22),
                            cornerRadius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(channel.group)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isPlaying {
                    Circle().fill(TVBrand.signal).frame(width: 5, height: 5)
                } else if tv.isFavorite(channel) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(TVBrand.gold)
                }
            }
            .padding(.trailing, 10)
            .frame(width: channelColumnWidth, height: guideRowHeight)
            .overlay(alignment: .trailing) {
                Rectangle().fill(TVBrand.hairline).frame(width: 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("播放 \(channel.name)")
    }

    // MARK: 时间轴 · 节目块

    private struct GuideSlice: Identifiable {
        let program: TVEPGProgram
        /// 落在时间窗里的那一段：块的宽度和读数都以它为准，避免「窗口是 19:00 起，
        /// 块上却写着 18:00」的错觉。
        let visibleStart: Date
        var visibleEnd: Date
        let x: CGFloat
        var width: CGFloat
        /// 碎片合并后的显示名与档数（正常节目为空 / 0）。
        var label: String? = nil
        var extraCount: Int = 0

        var id: String { program.id }
    }

    private func programTrack(channel: TVChannel, slotWidth: CGFloat) -> some View {
        let totalWidth = slotWidth * CGFloat(slotCount)
        let slices = programSlices(channel: channel, totalWidth: totalWidth)
        return ZStack(alignment: .topLeading) {
            hourGrid(slotWidth: slotWidth)
            ForEach(slices) { slice in
                programBlock(channel: channel, slice: slice)
                    .offset(x: slice.x, y: 6)
            }
        }
        .frame(width: totalWidth, height: guideRowHeight, alignment: .topLeading)
        .clipped()
    }

    /// 只取落在时间窗里的节目，并按真实时长换算成横向位置。
    /// 宽度不再强行撑到最小可读宽度，而是夹在「下一档的起点」之前，
    /// 长时间窗里短节目很多时也不会互相压住。
    private func programSlices(channel: TVChannel, totalWidth: CGFloat) -> [GuideSlice] {
        let start = windowStart
        let end = windowEnd
        let span = max(1, end.timeIntervalSince(start))
        var raw: [(program: TVEPGProgram, vs: Date, ve: Date, x: CGFloat, width: CGFloat)] = []
        for program in tv.programs(on: selectedDay, for: channel) {
            let visibleStart = max(program.start, start)
            let visibleEnd = min(program.end, end)
            guard visibleEnd > visibleStart else { continue }
            let x = CGFloat(visibleStart.timeIntervalSince(start) / span) * totalWidth
            let width = CGFloat(visibleEnd.timeIntervalSince(visibleStart) / span) * totalWidth
            raw.append((program, visibleStart, visibleEnd, x, max(1.5, width - 1.2)))
        }
        var slices: [GuideSlice] = []
        slices.reserveCapacity(raw.count)
        for (index, item) in raw.enumerated() {
            let limit = index + 1 < raw.count ? raw[index + 1].x : totalWidth
            let width = max(1.5, min(item.width, limit - item.x - 1))
            slices.append(GuideSlice(program: item.program,
                                     visibleStart: item.vs,
                                     visibleEnd: item.ve,
                                     x: item.x,
                                     width: width))
        }
        // 频道级自适应：几十秒一档的碎片（8K 轮播、宣传片）单独画只剩一条细线。
        // 规则：足够宽的节目单独成块；连续的碎片聚成一段并标注档数；
        // 夹在空档里的孤立碎片直接忽略，保持时间轴的真实性。
        var merged: [GuideSlice] = []
        merged.reserveCapacity(slices.count)
        let microWidth: CGFloat = 20
        var pendingMicro: GuideSlice?
        func flushPending() {
            if let pending = pendingMicro { merged.append(pending) }
            pendingMicro = nil
        }
        for slice in slices {
            if slice.width >= microWidth {
                flushPending()
                merged.append(slice)
                continue
            }
            if var pending = pendingMicro,
               slice.x - (pending.x + pending.width) <= 10 {
                pending.width = max(pending.width, slice.x + slice.width - pending.x)
                pending.visibleEnd = max(pending.visibleEnd, slice.visibleEnd)
                pending.extraCount += slice.extraCount + 1
                pendingMicro = pending
            } else {
                flushPending()
                pendingMicro = slice
            }
        }
        flushPending()
        return merged
    }

    /// 半小时细线 + 整点稍重的竖线，横向贯穿整行。
    private func hourGrid(slotWidth: CGFloat) -> some View {
        Canvas { context, size in
            for index in 0...slotCount {
                let x = CGFloat(index) * slotWidth
                let isHour = index % 2 == 0
                context.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)),
                             with: .color(Color.primary.opacity(isHour ? 0.07 : 0.03)))
            }
        }
        .frame(width: slotWidth * CGFloat(slotCount), height: guideRowHeight)
        .allowsHitTesting(false)
    }

    /// 一档节目：底色区分状态，左侧细色条区分前后节目，正在播带进度线。
    /// 信息量随块宽收敛：长时间窗里窄块只留色条和标题，宽块才显示完整时间、时长与状态，
    /// 不再让文字互相压住。
    private func programBlock(channel: TVChannel, slice: GuideSlice) -> some View {
        let program = slice.program
        let width = slice.width
        let minutes = max(1, Int(slice.visibleEnd.timeIntervalSince(slice.visibleStart) / 60))
        let live = program.isLive && dayOffset == 0
        let past = program.end <= Date() && !live
        let canCatchUp = !(channel.catchUpSource ?? "").isEmpty
        let isSelected = selected?.id == program.id
        let isHovered = hoveredGuideProgramID == program.id
        let tint = TVRingPalette.colors[Self.programTintIndex(program)]
        let fillOpacity: Double = {
            if live { return 0.30 }
            if isSelected { return 0.24 }
            if isHovered { return past ? 0.16 : 0.15 }
            if past { return canCatchUp ? 0.13 : 0.05 }
            return 0.09
        }()
        let accent: Color = live ? TVBrand.signal
            : (past && !canCatchUp ? Color.primary.opacity(0.16) : tint)
        let progress: Double? = {
            guard live else { return nil }
            let span = program.end.timeIntervalSince(program.start)
            guard span > 0 else { return nil }
            return min(1, max(0, Date().timeIntervalSince(program.start) / span))
        }()
        // 宽度分档：哪些信息值得占地方。
        let showsRange = width >= 104
        let showsTime = width >= 50
        let showsTitle = width >= 26
        let showsBadge = width >= 126
        let showsDuration = width >= 172
        let tight = width < 62
        let corner = min(8, max(3, width * 0.28))
        let blockTitle: String = {
            guard let label = slice.label else { return program.title }
            if slice.extraCount > 0, width >= 96 {
                return "\(label) 等 \(slice.extraCount + 1) 档"
            }
            return label
        }()
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = program }
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(fillOpacity))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(isSelected ? TVBrand.gold.opacity(0.65)
                                             : (live ? TVBrand.signal.opacity(0.42)
                                                     : Color.primary.opacity(0.06)),
                                  lineWidth: isSelected ? 1 : 0.6)

                VStack(alignment: .leading, spacing: tight ? 1 : 3) {
                    if showsTime {
                        HStack(spacing: 5) {
                            Text(showsRange
                                 ? "\(clock(slice.visibleStart)) – \(clock(slice.visibleEnd))"
                                 : clock(slice.visibleStart))
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(live ? TVBrand.signal
                                                      : Color.primary.opacity(0.52))
                                .lineLimit(1)
                            if live, showsBadge {
                                Text("正在播")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(TVBrand.signal)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(TVBrand.signal.opacity(0.16),
                                                in: Capsule(style: .continuous))
                            } else if past, canCatchUp, showsBadge {
                                Text("可回看")
                                    .font(.system(size: 7.5, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.85))
                            }
                            Spacer(minLength: 0)
                            if showsDuration {
                                Text("\(minutes) 分")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if showsTitle {
                        Text(blockTitle)
                            .font(.system(size: tight ? 9.5 : 11.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(past && !canCatchUp ? 0.5 : 0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, tight ? 4 : 11)
                .padding(.trailing, tight ? 3 : 8)
                .padding(.vertical, tight ? 4 : 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let progress {
                    GeometryReader { geo in
                        Capsule(style: .continuous)
                            .fill(TVBrand.signal.opacity(0.7))
                            .frame(width: max(0, geo.size.width * progress), height: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                    }
                    .padding(.bottom, 1)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: guideRowHeight - 12)
            .overlay(alignment: .leading) {
                if width >= 18 {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent)
                        .frame(width: 2.6)
                        .padding(.vertical, 9)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredGuideProgramID = program.id
            } else if hoveredGuideProgramID == program.id {
                hoveredGuideProgramID = nil
            }
        }
        .help(slice.extraCount > 0
              ? "\(program.title) 等 \(slice.extraCount + 1) 档碎片节目 · \(timeRange(program))"
              : "\(program.title) · \(timeRange(program))")
    }

    /// 节目底色取自和时间环同一组配色，按开播时间稳定取色。
    private static func programTintIndex(_ program: TVEPGProgram) -> Int {
        let slot = Int(program.start.timeIntervalSince1970 / 1800)
        return abs(slot) % TVRingPalette.colors.count
    }

    private func nowLine(slotWidth: CGFloat) -> some View {
        Group {
            if dayOffset == 0, Date() >= windowStart, Date() < windowEnd {
                let fraction = Date().timeIntervalSince(windowStart)
                    / windowEnd.timeIntervalSince(windowStart)
                VStack(spacing: 0) {
                    Circle()
                        .fill(TVBrand.signal)
                        .frame(width: 6, height: 6)
                    Rectangle()
                        .fill(LinearGradient(colors: [TVBrand.signal,
                                                      TVBrand.signal.opacity(0.22)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1.4)
                }
                .frame(maxHeight: .infinity)
                .offset(x: 22 + channelColumnWidth
                        + slotWidth * CGFloat(slotCount) * fraction - 3)
                .allowsHitTesting(false)
            }
        }
    }

    private func slotStart(_ slot: Int) -> Date {
        windowStart.addingTimeInterval(TimeInterval(slot * slotMinutes * 60))
    }

    // MARK: - 传送门 / 时间环

    /// 传送门：与时间环共用左侧频道与顶部日期，中间是一扇回到某一天的门。
    private var guidePortal: some View {
        HStack(spacing: 0) {
            guideChannelRail
            Rectangle().fill(TVBrand.hairline).frame(width: 0.8)
            TVCatchupView(day: selectedDayBinding,
                          selectedID: $guideChannelID,
                          channel: guideChannel)
        }
    }

    /// 日期与传送门共用：传送门里换日时，顶部日期胶囊同步。
    private var selectedDayBinding: Binding<Date> {
        Binding(
            get: { selectedDay },
            set: { newValue in
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let target = calendar.startOfDay(for: newValue)
                let offset = calendar.dateComponents([.day], from: today, to: target).day ?? 0
                dayOffset = min(2, max(-2, offset))
            }
        )
    }

    /// 时间环：把一整天卷成一个表盘。指针扫过哪一段，中央就显示那一档节目，可直接播放。
    /// 指针 / 悬停状态都收在 `TVTimeRingStage` 里：拖动时只有表盘重绘，
    /// 左侧频道栏和顶部日期条不再跟着重算。
    private var guideRing: some View {
        HStack(spacing: 0) {
            guideChannelRail
            Rectangle().fill(TVBrand.hairline).frame(width: 0.8)
            TVTimeRingStage(day: selectedDay,
                            dayOffset: dayOffset,
                            channel: guideChannel,
                            programs: ringPrograms,
                            dayLabel: ringDayLabel,
                            resetToken: "\(guideChannel?.id ?? "-")-\(selectedDay.timeIntervalSince1970)-\(ringResetTick)")
        }
    }

    private var guideChannel: TVChannel? {
        if let id = guideChannelID,
           let channel = channelsWithEPG.first(where: { $0.id == id }) {
            return channel
        }
        if let playing = playingChannelID,
           let channel = channelsWithEPG.first(where: { $0.id == playing }) {
            return channel
        }
        return channelsWithEPG.first
    }

    private var ringProgramsKeyNow: String {
        "\(guideChannel?.id ?? "-")-\(selectedDay.timeIntervalSince1970)-\(tv.epgPrograms.count)"
    }

    private var ringPrograms: [TVEPGProgram] {
        if ringProgramsKey == ringProgramsKeyNow { return ringProgramsCache }
        return computeRingPrograms()
    }

    private func computeRingPrograms() -> [TVEPGProgram] {
        guard let channel = guideChannel else { return [] }
        return tv.programs(on: selectedDay, for: channel)
    }

    private var guideChannelRail: some View {
        // 选中频道只查一次：每行都去 first(where:) 会退化成 O(n²)。
        let activeID = guideChannel?.id
        let playingID = playingChannelID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(guideMode == .portal ? "可回看频道" : "转动的频道")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(channelsWithEPG.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(channelsWithEPG) { channel in
                        guideChannelRow(channel, activeID: activeID, playingID: playingID)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 218, alignment: .top)
    }

    private func guideChannelRow(_ channel: TVChannel,
                                 activeID: String?,
                                 playingID: String?) -> some View {
        let active = channel.id == activeID
        let live = channel.id == playingID
        return Button {
            withAnimation(.easeOut(duration: 0.22)) {
                guideChannelID = channel.id
                selected = nil
            }
        } label: {
            HStack(spacing: 8) {
                Text(String(format: "%02d", tv.channelNumber(for: channel)))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(active ? TVBrand.gold : Color.secondary)
                    .frame(width: 26, alignment: .leading)
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 32, height: 20),
                            cornerRadius: 4)
                Text(channel.name)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if live {
                    Circle().fill(TVBrand.signal).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(active ? TVBrand.gold.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ringDayLabel: String {
        let name = guideDayTitle(dayOffset)
        let date = selectedDay.formatted(.dateTime.month(.defaultDigits).day())
        let weekday = selectedDay.formatted(.dateTime.weekday(.abbreviated))
        return "\(name) · \(date) \(weekday)"
    }

    private var playingChannelID: String? {
        guard let viewerID = store.viewerID else { return nil }
        return store.tvPlaybackChannel(for: viewerID)?.id
    }

    private func programChannel(_ program: TVEPGProgram) -> TVChannel {
        channelsWithEPG.first {
            tv.programs(on: selectedDay, for: $0).contains(where: { $0.id == program.id })
        } ?? channelsWithEPG[0]
    }

    private func detailBand(_ program: TVEPGProgram) -> some View {
        let channel = programChannel(program)
        let past = program.end <= Date()
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        return HStack(spacing: 10) {
            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 46, height: 27),
                        cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(program.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(program.isLive && dayOffset == 0 ? "正在播" : (past ? "已播" : "待播"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(program.isLive && dayOffset == 0 ? TVBrand.signal : Color.secondary)
                }
                Text("\(channel.name) · \(timeRange(program)) · \(Int(program.duration / 60)) 分钟")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // 节目摘要：优先用 EPG 简介，没有就按节目名 / 时段兜底，稳定两行。
                Text(programSummary(program))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if program.isLive, dayOffset == 0 {
                Button("播放直播") { store.openTVChannel(channel) }
                    .controlSize(.small)
            }
            Button("回看") {
                store.openTVCatchup(channel, program: program)
            }
            .controlSize(.small)
            .disabled(!canCatchUp)
            .help(canCatchUp ? "回看这档节目" : "该源未声明回看，或节目尚未结束")
            if program.start > Date() {
                let reminded = tv.isReminded(program)
                Button(reminded ? "已预约" : "预约") {
                    tv.toggleReminder(program, channel: channel)
                }
                .controlSize(.small)
                .help(reminded ? "点击取消开播提醒" : "节目开播时用系统通知提醒")
            }
            if program.end > Date() {
                let scheduled = tv.pendingRecordings.contains {
                    $0.channelID == channel.id && $0.title == program.title
                        && abs($0.start.timeIntervalSince(program.start)) < 60
                }
                Button(scheduled ? "已排录制" : "录制") {
                    tv.scheduleRecording(channel: channel, program: program)
                }
                .controlSize(.small)
                .disabled(scheduled)
                .help("节目开始后自动录进图库")
            }
            Button {
                tv.toggleSubscription(program, channel: channel)
            } label: {
                Image(systemName: tv.isSubscribed(program) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tv.isSubscribed(program) ? TVBrand.gold : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(tv.isSubscribed(program)
                  ? "取消追这档节目"
                  : "追这档节目：未来几天的同名播出自动提醒")
            Button {
                tv.toggleFavorite(channel)
            } label: {
                Image(systemName: tv.isFavorite(channel) ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tv.isFavorite(channel) ? TVBrand.gold : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(tv.isFavorite(channel) ? "取消收藏 \(channel.name)" : "收藏 \(channel.name)")
            Button {
                withAnimation(.easeOut(duration: 0.18)) { selected = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("收起节目详情")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(TVBrand.surface)
    }

    private var emptyState: some View {
        emptyState(message: tv.epgError ?? "当前源没有提供 EPG 节目单。")
    }

    private func emptyState(message: String) -> some View {
        LumaEmptyState(symbol: "calendar.badge.exclamationmark",
                       title: "还没有节目单",
                       message: message + "\nM3U 头部需要 url-tvg / x-tvg-url；也可以在「源库」的源菜单里填写 XMLTV 地址。")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clock(_ date: Date) -> String {
        Self.guideClockFormatter.string(from: date)
    }

    private func timeRange(_ program: TVEPGProgram) -> String {
        "\(clock(program.start)) – \(clock(program.end))"
    }

    /// 两行节目摘要：优先用 EPG 简介，清洗 HTML 与多余空白；没有简介时用确定信息兜底。
    private func programSummary(_ program: TVEPGProgram) -> String {
        let raw = (program.overview ?? program.subtitle ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let minutes = max(1, Int(program.duration / 60))
        return "\(program.title) · \(timeRange(program)) · 时长约 \(minutes) 分钟。"
    }

    private static let guideClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
