import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

/// 「夜航」页派生数据缓存：签名不变就复用上一次的结果。
/// 用引用类型装缓存，命中时不触发 SwiftUI 的状态更新，只在真正需要时重建。
@MainActor
final class TVTonightCache {
    private var key: String?
    private var snapshot = TVTonightSnapshot()

    func value(for key: String, build: () -> TVTonightSnapshot) -> TVTonightSnapshot {
        if key == self.key { return snapshot }
        let fresh = build()
        snapshot = fresh
        self.key = key
        return fresh
    }
}

// MARK: - 今晚

/// 独立「夜航」页：把直播页上的两条创意货架展开成长页面，
/// 赛事按角度与体育类型列出，黄金时段按类型分组，最后把匹配规则摊开。
struct TVTonightView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv

    @State private var rulesShown = false
    /// 赛事角度：当前热播 / 即将开赛 / 历史 / 未来。
    @State private var sportAngle: TVSportAngle = .live
    /// 体育类型筛选：全部 / 篮球 / 足球 / 世界杯……
    @State private var sportType: TVSportType = .all
    /// 黄金时段类型筛选：nil 表示全部。
    @State private var primeCategory: TVGuideCategory?
    /// 黄金时段时段筛选：nil 表示整个黄金时段。
    @State private var primeSlot: Int?
    /// 综艺 / 人物货架是否展开全部。
    @State private var expandedShelves: Set<String> = []
    /// 悬停高亮：整页共用一组状态，卡片与行不再各自维护。
    @State private var hoveredSportKey: String?
    @State private var hoveredPrimeKey: String?
    @State private var hoveredShowKey: String?

    /// 整页派生数据的缓存：签名不变就直接复用，预约 / 追剧这类重绘不再重扫节目单。
    @State private var cache = TVTonightCache()

    var body: some View {
        // 一分钟一跳的稳定时钟：整页共用同一个时刻，
        // 「直播 / 已结束 / 明天」的翻面也就卡在分钟边界上，不会一帧一个样。
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 60)) { context in
            page(now: context.date)
        }
        // 进入夜航也把节目单补齐：缓存过期 / 首次进入都会在这里排一次更新，
        // 不然赛事、黄金时段、综艺全是空的。
        .task { tv.loadEPGIfNeeded() }
    }

    /// 节目单缺失提示：夜航整页的货架都来自节目单，没有时必须说清楚并给出更新入口。
    private var epgNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tv.isLoadingEPG ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tv.isLoadingEPG ? TVBrand.gold : LumaBrand.coral)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(tv.isLoadingEPG ? "正在更新节目单…" : "还没有节目单")
                    .font(.system(size: 12, weight: .semibold))
                Text(epgNoticeDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !tv.isLoadingEPG {
                Button("立即更新") { tv.reloadEPG() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(TVBrand.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6)
        }
    }

    private var epgNoticeDetail: String {
        if tv.isLoadingEPG {
            return "拉取完成后，赛事 / 黄金时段 / 综艺会自动填满这一页。"
        }
        if let error = tv.epgError, !error.isEmpty {
            return "上次更新失败：\(error)。点右侧重试。"
        }
        return "这一页的赛事、黄金时段与综艺都来自节目单；点右侧立即拉取，或在「源库」里补一份 XMLTV 地址。"
    }

    private func page(now: Date) -> some View {
        let snapshot = cache.value(for: cacheKey(now: now)) { buildSnapshot(now: now) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if tv.epgPrograms.isEmpty {
                    epgNotice
                }
                sportsSection(snapshot, now: now)
                primeSection(snapshot, followed: snapshot.followedProgramIDs, now: now)
                showShelf(title: "热播综艺",
                          symbol: "sparkles",
                          tint: LumaBrand.coral,
                          detail: "今晚 18:00 后 · \(snapshot.variety.count) 档",
                          picks: snapshot.variety,
                          emptyText: "节目单里还没有识别到今晚的综艺。",
                          now: now)
                showShelf(title: "人物记录",
                          symbol: "person.text.rectangle",
                          tint: LumaBrand.mint,
                          detail: "纪实 / 人物 · \(snapshot.people.count) 档",
                          picks: snapshot.people,
                          emptyText: "这段时间没有人物 / 纪实类节目；节目单更新后会自动出现。",
                          now: now)
                TVRecordingsPanel()
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
    }

    /// 缓存签名：节目单 / 频道集合 / 筛选条件 / 分钟 / 追剧状态任一变化才重建整页数据。
    private func cacheKey(now: Date) -> String {
        "\(tv.tonightDataSignature)|\(Int(now.timeIntervalSince1970 / 60))"
            + "|\(tv.subscriptions.count)"
    }

    /// 收集两天的节目单后一次算完：同一档节目的赛事判定、栏目分类都只做一次。
    private func buildSnapshot(now: Date) -> TVTonightSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let channels = tv.visibleChannels
        var snapshot = TVTonightRules.tonightSnapshot(
            today: channels.map {
                TVChannelDay(channel: $0, programs: tv.programs(on: today, for: $0))
            },
            tomorrow: channels.map {
                TVChannelDay(channel: $0, programs: tv.programs(on: tomorrow, for: $0))
            },
            now: now
        )
        let subscribed = Set(tv.subscriptions.map(\.key))
        if !subscribed.isEmpty {
            snapshot.followedProgramIDs = Set(
                snapshot.picks
                    .filter { subscribed.contains(tv.programKey($0.program.title)) }
                    .map { $0.program.id }
            )
        }
        return snapshot
    }

    // MARK: 头部

    private var refreshButton: some View {
        Button {
            tv.reloadEPG()
        } label: {
            HStack(spacing: 6) {
                if tv.isLoadingEPG {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(tv.isLoadingEPG ? "刷新中…" : "刷新节目单")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(tv.isLoadingEPG)
        .help("重新拉取节目单")
    }

    private var rulesButton: some View {
        Button {
            rulesShown.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("推荐规则")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(TVBrand.panel, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $rulesShown, arrowEdge: .top) {
            TVTonightRulesCard()
                .padding(16)
                .frame(width: 400)
        }
    }

    // MARK: 赛事

    private func sportsSection(_ snapshot: TVTonightSnapshot, now: Date) -> some View {
        let live = snapshot.sports.filter { $0.program.isLive }
        let upcoming = snapshot.sports.filter { !$0.program.isLive }
        let buckets: [TVSportAngle: [TVSportEvent]] = [
            .live: live,
            .upcoming: upcoming,
            .history: snapshot.history,
            .future: snapshot.future
        ]
        let current = buckets[sportAngle] ?? []
        let types = snapshot.sportTypes
        let filtered = sportType == .all
            ? current
            : current.filter { types[$0.key] == sportType }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                sectionTitle(symbol: "sportscourt.fill",
                             tint: TVBrand.gold,
                             title: "最近赛事",
                             detail: "\(snapshot.sports.count) 场 · 未来 14 小时")
                refreshButton
                rulesButton
            }
            angleBar(buckets)
            typeChips(in: current, types: types)
            if !tv.sportFollows.isEmpty {
                followBar(snapshot: snapshot)
            }

            if filtered.isEmpty {
                emptyHint(symbol: "sportscourt", text: emptySportText(angle: sportAngle))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { event in
                        sportRow(event, type: types[event.key] ?? .other, now: now)
                    }
                }
            }
        }
    }

    /// 四个角度：当前热播 / 即将开赛 / 历史 / 未来。
    private func angleBar(_ buckets: [TVSportAngle: [TVSportEvent]]) -> some View {
        HStack(spacing: 5) {
            ForEach(TVSportAngle.allCases) { angle in
                let active = sportAngle == angle
                let count = buckets[angle]?.count ?? 0
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { sportAngle = angle }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: angle.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(angle.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .opacity(0.78)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(active ? TVBrand.onGold.opacity(0.16)
                                               : Color.primary.opacity(0.06),
                                        in: Capsule(style: .continuous))
                    }
                    .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
                    .padding(.horizontal, 13)
                    .frame(height: 31)
                    .background {
                        if active {
                            Capsule(style: .continuous).fill(angle.tint)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("\(angle.title) · \(count) 场")
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .fixedSize()
    }

    /// 体育类型：只列出当前角度里真的出现过的类型；换行平铺，不用左右拖。
    private func typeChips(in events: [TVSportEvent], types: [String: TVSportType]) -> some View {
        let present = Set(events.map { types[$0.key] ?? .other })
        let visible = TVSportType.allCases.filter { $0 == .all || present.contains($0) }
        return CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(visible) { type in
                typeChip(type)
            }
        }
    }

    private func typeChip(_ type: TVSportType) -> some View {
        let active = sportType == type
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { sportType = type }
        } label: {
            Text(type.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 27)
                .background(active ? TVBrand.gold : Color.primary.opacity(0.05),
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 「我的关注」：关注词一键取消，并可批量给相关赛事排开赛提醒。
    private func followBar(snapshot: TVTonightSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("我的关注", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TVBrand.gold)
                Text("\(tv.sportFollows.count) 个关键词")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("为关注赛事排提醒") {
                    let items = (snapshot.sports + snapshot.future)
                        .map { (channel: $0.channel, program: $0.program) }
                    tv.remindFollowedSports(items)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            }
            CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(tv.sportFollows) { follow in
                    Button {
                        tv.removeSportFollow(follow)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(follow.keyword)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .opacity(0.6)
                        }
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(TVBrand.gold.opacity(0.12), in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(TVBrand.gold.opacity(0.30), lineWidth: 0.6))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("取消关注「\(follow.keyword)」")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6)
        }
    }

    private func emptySportText(angle: TVSportAngle) -> String {
        switch angle {
        case .live: return "此刻没有识别到正在直播的赛事。"
        case .upcoming: return "接下来 14 小时里还没有还没开播的赛事。"
        case .history: return "今天结束的节目单里还没识别到赛事。"
        case .future: return "节目单里还没有明天的赛事；等 EPG 补上后会自动出现。"
        }
    }

    private func sportRow(_ event: TVSportEvent, type: TVSportType, now: Date) -> some View {
        let program = event.program
        let channel = event.channel
        let live = program.isLive
        let past = program.end <= now
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let tint: Color = live ? TVBrand.signal : (past ? Color.secondary : TVBrand.gold)
        let isTomorrow = !Calendar.current.isDateInToday(program.start)
        let hovered = hoveredSportKey == event.key
        return HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.clock.string(from: program.start))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(Self.clock.string(from: program.end))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .trailing)

            // 时间轨：直播是实心亮点，过去是灰点，未来是描边点。
            VStack(spacing: 0) {
                Circle()
                    .fill(live ? tint : Color.clear)
                    .overlay {
                        Circle().strokeBorder(tint.opacity(past ? 0.5 : 0.9),
                                              lineWidth: live ? 0 : 1.5)
                    }
                    .frame(width: 9, height: 9)
                    .shadow(color: live ? tint.opacity(0.75) : .clear, radius: 6)
                Rectangle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 1, height: 34)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(program.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(past && !canCatchUp ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TVLogoImage(urlString: channel.logoURL,
                                size: CGSize(width: 34, height: 17),
                                cornerRadius: 3)
                    Text("\(String(format: "%02d", tv.channelNumber(for: channel))) · \(channel.name)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .lineLimit(1)
                    Text(type.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TVBrand.gold.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(TVBrand.gold.opacity(0.13), in: Capsule(style: .continuous))
                    if tv.isFollowedSport(program.title) {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("关注")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(TVBrand.gold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(TVBrand.gold.opacity(0.16), in: Capsule(style: .continuous))
                    }
                    if isTomorrow {
                        Text("明天")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(TVBrand.wave.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                    }
                    if event.simulcast > 1 {
                        // 同播多台：赛事详情直接在这里换台，不必先进入某一家再翻。
                        Menu {
                            ForEach(Array(event.channels.enumerated()), id: \.element.id) { _, item in
                                Button {
                                    openSport(event, channel: item, now: now)
                                } label: {
                                    Text("\(String(format: "%02d", tv.channelNumber(for: item))) · \(item.name)")
                                }
                            }
                        } label: {
                            Text("\(event.simulcast) 台同播")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(TVBrand.wave.opacity(0.85))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("换一台同播频道")
                    }
                }
            }

            Spacer(minLength: 10)

            Button {
                openSport(event, now: now)
            } label: {
                HStack(spacing: 5) {
                    if live {
                        Circle()
                            .fill(TVBrand.onGold)
                            .frame(width: 5, height: 5)
                    }
                    Text(live ? "看直播"
                         : (past ? (canCatchUp ? "回看" : "已结束")
                            : (reminded ? "已提醒" : "开赛提醒")))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(live || reminded ? TVBrand.onGold : tint)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(live ? TVBrand.signal : (reminded ? TVBrand.gold : Color.clear),
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(live || reminded ? Color.clear : tint.opacity(0.5),
                                  lineWidth: 0.7))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(past && !canCatchUp)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? tint.opacity(0.75) : Color.clear)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(TVBrand.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(tint.opacity(hovered ? 0.07 : 0))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(live ? TVBrand.signal.opacity(0.35)
                                   : (hovered ? tint.opacity(0.42) : TVBrand.stroke),
                              lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { openSport(event, now: now) }
        .onHover { inside in
            if inside {
                hoveredSportKey = event.key
            } else if hoveredSportKey == event.key {
                hoveredSportKey = nil
            }
        }
        .contextMenu {
            // 关注：从标题里拆出的球队 / 联赛各给一个开关。
            ForEach(tv.followCandidates(in: program.title), id: \.self) { keyword in
                Button(tv.isFollowingSport(keyword)
                       ? "取消关注「\(keyword)」"
                       : "关注「\(keyword)」") {
                    tv.toggleSportFollow(keyword)
                }
            }
            Divider()
            Button("定时录制") {
                tv.scheduleRecording(channel: channel, program: program)
            }
            if program.isLive {
                Button("立即录制 30 秒") {
                    tv.recordNow(channel: channel, title: program.title)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 行与按钮共用一套动作：直播直接进频道，结束的能回看就回看，未开赛的加提醒。
    private func openSport(_ event: TVSportEvent, now: Date) {
        openSport(event, channel: event.channel, now: now)
    }

    /// 指定同播频道时的动作：多台同播菜单与默认动作走同一份判断。
    private func openSport(_ event: TVSportEvent, channel: TVChannel, now: Date) {
        let program = event.program
        if program.isLive {
            store.openTVChannel(channel)
        } else if program.end <= now {
            if !(channel.catchUpSource ?? "").isEmpty {
                store.openTVCatchup(channel, program: program)
            }
        } else {
            tv.toggleReminder(program, channel: channel)
        }
    }

    // MARK: 黄金时段

    private func primeSection(_ snapshot: TVTonightSnapshot,
                              followed: Set<String>,
                              now: Date) -> some View {
        let picks = snapshot.picks
        // 按类型分组一次，类型胶囊与网格共用。
        let grouped = Dictionary(grouping: picks, by: \.category)
        let available = TVGuideCategory.allCases.filter { !(grouped[$0] ?? []).isEmpty }
        let selected = primeCategory.flatMap { grouped[$0] } ?? []
        var shown = selected.isEmpty ? picks : selected
        if let primeSlot {
            shown = shown.filter { primeSlotIndex(for: $0.program.start, now: now) == primeSlot }
        }
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(symbol: "sparkles",
                         tint: TVBrand.wave,
                         title: "黄金时段",
                         detail: "19:30–23:30 · \(picks.count) 档精选 · 跨频道同播合并")
            if picks.isEmpty {
                emptyHint(symbol: "sparkles",
                          text: "这一时段还没有可推荐的节目；没有节目单的源不会参与。")
            } else {
                primeHeatStrip(snapshot.primeSlots, now: now)
                // 类型平铺 + 自适应网格：不再一排排横向拖动。
                CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                    primeChip(nil, label: "全部", count: picks.count, tint: TVBrand.wave)
                    ForEach(available) { category in
                        primeChip(category, label: category.title,
                                  count: (grouped[category] ?? []).count,
                                  tint: category.tint)
                    }
                }
                if shown.isEmpty {
                    emptyHint(symbol: "line.3.horizontal.decrease.circle",
                              text: "这个时段没有符合当前筛选的精选；点一下热度条或「全部」恢复。")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460),
                                                 spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(shown) { pick in
                            primeCard(pick, followed: followed.contains(pick.program.id), now: now)
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: primeCategory)
                    .animation(.easeOut(duration: 0.18), value: primeSlot)
                }
            }
        }
    }

    /// 节目开播时间落在黄金时段的第几个 30 分钟格子里。
    private func primeSlotIndex(for start: Date, now: Date) -> Int {
        guard let window = TVTonightRules.primeWindow(on: now) else { return 0 }
        return max(0, Int(start.timeIntervalSince(window.start) / 1800))
    }

    /// 黄金时段类型胶囊：点一下只看这一类。
    private func primeChip(_ category: TVGuideCategory?, label: String,
                           count: Int, tint: Color) -> some View {
        let active = primeCategory == category
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { primeCategory = category }
        } label: {
            HStack(spacing: 6) {
                if let category {
                    Image(systemName: category.symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.8)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background((active ? TVBrand.onGold : Color.primary).opacity(0.12),
                                in: Capsule(style: .continuous))
            }
            .foregroundStyle(active ? TVBrand.onGold : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(active ? tint : Color.primary.opacity(0.05),
                        in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Color.clear : TVBrand.hairline, lineWidth: 0.6))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "点一下取消筛选" : "只看\(label)")
    }

    /// 黄金时段热力条：19:30 起每 30 分钟一格，格子的颜色是该时段占比最高的类型，
    /// 深浅表示这一格有多少档节目。数字来自全量节目统计，点格子可只看这一时段。
    private func primeHeatStrip(_ slots: [TVPrimeSlot], now: Date) -> some View {
        let base = TVTonightRules.primeWindow(on: now)?.start ?? now
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("时段热度")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("19:30 — 23:30 · 每格 30 分钟 · 点格子筛选")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if primeSlot != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { primeSlot = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("显示全部时段")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(TVBrand.wave)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(slots) { slot in
                    let start = base.addingTimeInterval(Double(slot.index) * 1800)
                    let end = start.addingTimeInterval(1800)
                    let active = primeSlot == slot.index
                    let tint = slot.category?.tint ?? Color.secondary
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            primeSlot = active ? nil : slot.index
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(Self.clock.string(from: start))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(active ? tint : Color.secondary.opacity(0.8))
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tint.opacity(slot.count == 0
                                                   ? 0.06
                                                   : 0.16 + min(0.36, Double(slot.count) * 0.05)))
                                .frame(height: 38)
                                .overlay {
                                    Text(slot.count == 0 ? "–" : "\(slot.count)")
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(slot.count == 0
                                                         ? Color.secondary.opacity(0.6)
                                                         : tint)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(active ? tint : tint.opacity(slot.count == 0 ? 0.06 : 0.28),
                                                      lineWidth: active ? 1.6 : 0.5)
                                }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(slot.count == 0)
                    .help("\(Self.clock.string(from: start))–\(Self.clock.string(from: end)) · \(slot.count) 档\(slot.category.map { " · 以\($0.title)为主" } ?? "")")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(TVBrand.stroke, lineWidth: 0.6)
        }
    }

    private func primeCard(_ pick: TVPrimePick, followed: Bool, now: Date) -> some View {
        let program = pick.program
        let channel = pick.channel
        let live = program.isLive
        let past = program.end <= now
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let tint = pick.category.tint
        let hovered = hoveredPrimeKey == pick.key
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(Self.clock.string(from: program.start))
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text("– " + Self.clock.string(from: program.end))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if live {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(TVBrand.onGold)
                            .frame(width: 4, height: 4)
                        Text("直播中")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(TVBrand.onGold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(TVBrand.signal, in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
                Button {
                    tv.toggleSubscription(program, channel: channel)
                } label: {
                    Image(systemName: followed ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(followed ? TVBrand.gold : Color.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(followed ? "取消追这档节目" : "追这档节目：未来几天自动提醒")
            }

            Text(program.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 34, height: 17),
                            cornerRadius: 3)
                Text("\(String(format: "%02d", tv.channelNumber(for: channel))) · \(channel.name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
                if pick.simulcast > 1 {
                    Text("\(pick.simulcast) 台同播")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TVBrand.wave.opacity(0.85))
                }
            }

            HStack(spacing: 5) {
                ForEach(pick.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
                }
                Spacer(minLength: 4)
                Button {
                    openPrime(pick, now: now)
                } label: {
                    Text(live ? "看直播"
                         : (past ? (canCatchUp ? "回看" : "已结束")
                            : (reminded ? "已提醒" : "开播提醒")))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(live || reminded ? TVBrand.onGold : tint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(live ? TVBrand.signal : (reminded ? TVBrand.gold : Color.clear),
                                    in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(live || reminded ? Color.clear : tint.opacity(0.5),
                                          lineWidth: 0.7))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(past && !canCatchUp)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBrand.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(hovered ? 0.14 : 0.06),
                                                      Color.clear],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(live ? 0.6 : (hovered ? 0.55 : 0.3)),
                                                      tint.opacity(0.08)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: hovered ? 1.1 : 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { openPrime(pick, now: now) }
        .onHover { inside in
            if inside {
                hoveredPrimeKey = pick.key
            } else if hoveredPrimeKey == pick.key {
                hoveredPrimeKey = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 卡片与按钮共用一套动作。
    private func openPrime(_ pick: TVPrimePick, now: Date) {
        let program = pick.program
        let channel = pick.channel
        if program.isLive {
            store.openTVChannel(channel)
        } else if program.end <= now {
            if !(channel.catchUpSource ?? "").isEmpty {
                store.openTVCatchup(channel, program: program)
            }
        } else {
            tv.toggleReminder(program, channel: channel)
        }
    }

    // MARK: 综艺 / 人物记录

    /// 综艺与人物记录共用一条横向货架：同名节目跨台合并，正在播的排最前。
    private func showShelf(title: String, symbol: String, tint: Color, detail: String,
                           picks: [TVShowPick], emptyText: String, now: Date) -> some View {
        let expanded = expandedShelves.contains(title)
        let collapseLimit = 6
        let shown = expanded ? picks : Array(picks.prefix(collapseLimit))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                sectionTitle(symbol: symbol, tint: tint, title: title, detail: detail)
                if picks.count > collapseLimit {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { toggleShelf(title) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "收起" : "全部 \(picks.count) 档")
                                .font(.system(size: 11.5, weight: .medium))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if picks.isEmpty {
                emptyHint(symbol: symbol, text: emptyText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360),
                                             spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(shown) { pick in
                        showCard(pick, tint: tint, now: now)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: expanded)
            }
        }
    }

    private func toggleShelf(_ title: String) {
        if expandedShelves.contains(title) {
            expandedShelves.remove(title)
        } else {
            expandedShelves.insert(title)
        }
    }

    private func showCard(_ pick: TVShowPick, tint: Color, now: Date) -> some View {
        let program = pick.program
        let channel = pick.channel
        let live = program.isLive
        let past = program.end <= now
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let hovered = hoveredShowKey == pick.key
        return VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 7) {
                    Text(Self.clock.string(from: program.start))
                        .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint)
                    Text("– " + Self.clock.string(from: program.end))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if live {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(TVBrand.onGold)
                                .frame(width: 4, height: 4)
                            Text("直播中")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .foregroundStyle(TVBrand.onGold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(TVBrand.signal, in: Capsule(style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                // 节目名首字做一枚淡色水印，卡片不用封面也有辨识度。
                Text(String(program.title.prefix(1)))
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(tint.opacity(0.10))
                    .offset(x: 2, y: -22)
                    .allowsHitTesting(false)
            }

            Text(program.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(past && !canCatchUp ? Color.secondary : Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 34, height: 17),
                            cornerRadius: 3)
                Text("\(String(format: "%02d", tv.channelNumber(for: channel))) · \(channel.name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1)
                if pick.simulcast > 1 {
                    Text("\(pick.simulcast) 台")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TVBrand.wave.opacity(0.8))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    openShow(pick, now: now)
                } label: {
                    Text(live ? "看直播"
                         : (past ? (canCatchUp ? "回看" : "已结束")
                            : (reminded ? "已提醒" : "开播提醒")))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(live || reminded ? TVBrand.onGold : tint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(live ? TVBrand.signal : (reminded ? TVBrand.gold : Color.clear),
                                    in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(live || reminded ? Color.clear : tint.opacity(0.5),
                                          lineWidth: 0.7))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(past && !canCatchUp)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVBrand.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(hovered ? 0.14 : 0.06),
                                                      Color.clear],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(live ? 0.6 : (hovered ? 0.5 : 0.28)),
                                                      tint.opacity(0.06)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: hovered ? 1.1 : 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { openShow(pick, now: now) }
        .onHover { inside in
            if inside {
                hoveredShowKey = pick.key
            } else if hoveredShowKey == pick.key {
                hoveredShowKey = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 卡片与按钮共用一套动作。
    private func openShow(_ pick: TVShowPick, now: Date) {
        let program = pick.program
        let channel = pick.channel
        if program.isLive {
            store.openTVChannel(channel)
        } else if program.end <= now {
            if !(channel.catchUpSource ?? "").isEmpty {
                store.openTVCatchup(channel, program: program)
            }
        } else {
            tv.toggleReminder(program, channel: channel)
        }
    }

    // MARK: 小件

    private func sectionTitle(symbol: String, tint: Color,
                              title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.13))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func emptyHint(symbol: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TVBrand.stroke, lineWidth: 0.6)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 右上角「推荐规则」弹层。
struct TVTonightRulesCard: View {

    private struct Rule: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let rules: [Rule] = [
        Rule(symbol: "sportscourt",
             title: "赛事识别",
             detail: "标题里出现足球 / 篮球 / 联赛 / 杯 / 决赛 / NBA / 世界杯 等关键词；体育频道的整档节目也算。体育新闻、赛事预告这类栏目会被排除。"),
        Rule(symbol: "square.grid.2x2",
             title: "四个角度",
             detail: "当前热播＝正在直播；即将开赛＝今天接下来 14 小时；历史＝今天已经结束（有回看源的给「回看」）；未来＝明天的节目单。"),
        Rule(symbol: "sportscourt.fill",
             title: "体育类型",
             detail: "从标题识别世界杯 / 奥运 / 足球 / 篮球 / 排球 / 羽毛球 / 乒乓球 / 网球 / 斯诺克 / 田径 / 游泳 / 冰雪 / 格斗 / 赛车 / 电竞 / 高尔夫 / 棒球 / 综合；只列出当前角度里出现过的类型。"),
        Rule(symbol: "clock.badge.checkmark",
             title: "黄金时段",
             detail: "19:30–23:30 每 30 分钟一格做「时段热度」：格子颜色是该时段占比最高的类型，数量是这一格的档数；下面按类型过滤，自适应网格排开，点卡片直接播放或回看。"),
        Rule(symbol: "sparkles",
             title: "综艺与人物",
             detail: "综艺看标题里的节目名与类型词；人物记录优先「讲人」的纪实（人物 / 大师 / 匠心 / 传奇 / 档案）。同名节目跨台只留一条，正在播的排最前，默认先看 6 档、可展开全部。"),
        Rule(symbol: "chart.bar",
             title: "合并与排序",
             detail: "同播优先 CCTV-5、体育频道、CCTV 与卫视；黄金时段评分看同播台数、类型权重、决赛 / 首播 / 直播与靠近 20:00 的程度。")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("夜航推荐规则")
                    .font(.system(size: 13.5, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rules) { rule in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: rule.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TVBrand.wave.opacity(0.9))
                            .frame(width: 16)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(rule.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
