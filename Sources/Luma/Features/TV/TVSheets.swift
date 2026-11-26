import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 多画面

/// 2×2 四个频道：静音同时预览，点击某一格把声音切过去，双击放大进播放器。
struct TVMultiviewSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv
    @Environment(\.dismiss) private var dismiss

    @State private var channels: [TVChannel] = []
    @State private var players: [String: AVPlayer] = [:]
    @State private var audioChannelID: String?

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("多画面")
                    .font(.system(size: 15, weight: .semibold))
                Text("声音跟随：\(audioChannel?.name ?? "—")")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            if channels.isEmpty {
                Text("没有可同时播放的 HLS 频道。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(channels) { channel in
                        cell(channel)
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(TVBrand.background)
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
    }

    private var audioChannel: TVChannel? {
        channels.first { $0.id == audioChannelID }
    }

    private func setup() {
        let favorites = tv.visibleChannels.filter { tv.isFavorite($0) }
        var pool = favorites.isEmpty ? tv.channelsForFocusedSource : favorites
        // AVPlayer 只认 HLS：FLV / 无后缀直播地址在这里会黑屏，先筛一轮。
        let hls = pool.filter(\.isHLS)
        if hls.count >= 4 { pool = hls }
        channels = Array(pool.prefix(4))
        for (index, channel) in channels.enumerated() {
            let player = makePlayer(channel, muted: index != 0)
            players[channel.id] = player
            if index == 0 { audioChannelID = channel.id }
            player.play()
        }
    }

    private func teardown() {
        for player in players.values {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players = [:]
        channels = []
    }

    private func makePlayer(_ channel: TVChannel, muted: Bool) -> AVPlayer {
        let url = URL(string: channel.streamURL)
        let options: [String: Any]? = channel.headers.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": channel.headers]
        let asset = url.map { AVURLAsset(url: $0, options: options) }
        let item = asset.map { AVPlayerItem(asset: $0) }
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        return player
    }

    private func cell(_ channel: TVChannel) -> some View {
        let focused = channel.id == audioChannelID
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
            TVStreamLayer(player: players[channel.id])
            LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .center)
                .allowsHitTesting(false)
            HStack(spacing: 6) {
                Text(String(format: "%02d", tv.channelNumber(for: channel)))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(focused ? TVBrand.gold : .white.opacity(0.7))
                Text(channel.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if focused {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TVBrand.gold)
                }
                Button {
                    dismiss()
                    store.openTVChannel(channel)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 20)
                        .background(Color.white.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("放大播放 \(channel.name)")
            }
            .padding(9)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? TVBrand.gold.opacity(0.8) : Color.white.opacity(0.10),
                              lineWidth: focused ? 1.2 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2) {
            dismiss()
            store.openTVChannel(channel)
        }
        .onTapGesture {
            selectAudio(channel)
        }
    }

    private func selectAudio(_ channel: TVChannel) {
        audioChannelID = channel.id
        for (id, player) in players {
            player.isMuted = id != channel.id
        }
    }
}

/// 我的追剧：订阅的节目 + 未来 7 天的播出日历，提醒自动排好。
struct TVSubscriptionsSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var occurrences: [(channel: TVChannel, program: TVEPGProgram)] {
        tv.subscriptionOccurrences(days: 7)
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        // 扫描一次 EPG，页头、日签与列表共用同一份结果。
        let all = occurrences
        return VStack(spacing: 0) {
            header(all: all)
            Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
            if tv.subscriptions.isEmpty {
                emptyState
            } else {
                subscriptionChips
                dayStrip(all: all)
                Rectangle().fill(TVBrand.hairline).frame(height: 0.8)
                calendarList(all: all)
            }
        }
        .frame(width: 760, height: 600)
        .background { LumaAmbientBackground(intensity: 0.5) }
    }

    private func header(all: [(channel: TVChannel, program: TVEPGProgram)]) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(TVBrand.gold.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TVBrand.gold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("我的追剧")
                    .font(.system(size: 17, weight: .semibold))
                Text(tv.subscriptions.isEmpty
                     ? "订阅节目后，未来 7 天的播出会自动排好提醒"
                     : "\(tv.subscriptions.count) 个订阅 · 未来 7 天 \(all.count) 次播出")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        LumaEmptyState(symbol: "bookmark",
                       title: "还没有追的节目",
                       message: "在节目单的节目详情里点书签，或在「黄金时段」卡片上点书签；\n同名节目未来几天的播出都会自动提醒。",
                       actions: [LumaEmptyAction(title: "去节目单挑一档", symbol: nil, filled: true) {
                           tv.setHubTab(.guide)
                           dismiss()
                       }])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subscriptionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tv.subscriptions) { subscription in
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(TVBrand.gold)
                        Text(subscription.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                        Button {
                            tv.removeSubscription(subscription)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("取消追《\(subscription.title)》")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(TVBrand.surface, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func dayStrip(all: [(channel: TVChannel, program: TVEPGProgram)]) -> some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let count = all.filter {
                    Calendar.current.isDate($0.program.start, inSameDayAs: day)
                }.count
                let active = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selectedDay = day }
                } label: {
                    VStack(spacing: 1) {
                        Text(dayLabel(day))
                            .font(.system(size: 9.5, weight: .semibold))
                        HStack(spacing: 3) {
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(active ? TVBrand.gold : Color.secondary)
                            }
                        }
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(active ? TVBrand.gold.opacity(0.16) : TVBrand.surface,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(active ? TVBrand.gold.opacity(0.45) : TVBrand.hairline,
                                      lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func calendarList(all: [(channel: TVChannel, program: TVEPGProgram)]) -> some View {
        let items = all.filter {
            Calendar.current.isDate($0.program.start, inSameDayAs: selectedDay)
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Text("这一天没有追的节目")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("换一天看看，或到节目单里追新的节目。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { pair in
                        subscriptionRow(channel: pair.element.channel,
                                        program: pair.element.program)
                        if pair.offset < items.count - 1 {
                            Rectangle()
                                .fill(TVBrand.hairline)
                                .frame(height: 0.6)
                                .padding(.leading, 62)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func subscriptionRow(channel: TVChannel, program: TVEPGProgram) -> some View {
        let live = program.isLive
        let past = program.end <= Date()
        let canCatchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        return HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(live ? TVBrand.signal : TVBrand.gold)
                Text("\(Int(program.duration / 60)) 分")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 46)

            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 34, height: 18),
                        cornerRadius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(channel.name)
                        .lineLimit(1)
                    Text(live ? "正在播" : (past ? (canCatchUp ? "可回看" : "已结束") : "待播"))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(live ? TVBrand.signal : Color.secondary)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if live {
                Button("看直播") { store.openTVChannel(channel) }
                    .controlSize(.small)
            } else if past, canCatchUp {
                Button("回看") { store.openTVCatchup(channel, program: program) }
                    .controlSize(.small)
            } else if !past {
                Button(reminded ? "已预约" : "预约") {
                    tv.toggleReminder(program, channel: channel)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(live ? TVBrand.signal.opacity(0.05) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dayLabel(_ day: Date) -> String {
        DateText.relativeDayOffset(day) ?? day.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// 给多画面用的 AVPlayerLayer 容器。
struct TVStreamLayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.player = player
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer?.sublayers?.first as? AVPlayerLayer)?.player = player
    }
}
