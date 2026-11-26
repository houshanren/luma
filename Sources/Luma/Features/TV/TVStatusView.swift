import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 状态

struct TVStatusView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv

    /// 信号页筛选：全部 / 异常 / 4K / 收藏。
    private enum SignalFilter: String, CaseIterable, Identifiable {
        case all, issues, uhd, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .issues: return "异常"
            case .uhd: return "4K"
            case .favorites: return "收藏"
            }
        }
    }

    @State private var filter: SignalFilter = .all
    @State private var detailChannel: TVChannel?

    private var runningChecks: [JobProgress] {
        store.activeSourceJobs.filter { $0.kind == .connectivity }
    }

    private var scopedChannels: [TVChannel] {
        let base = tv.channelsForFocusedSource
        switch filter {
        case .all:
            return base
        case .issues:
            return base.filter {
                if case .unavailable = tv.probeState(for: $0.id) { return true }
                return false
            }
        case .uhd:
            return base.filter { tv.probeReport(for: $0.id)?.resolutionText == "4K" }
        case .favorites:
            return base.filter { tv.isFavorite($0) }
        }
    }

    /// 排序：异常优先 → 正常按首帧延迟升序 → 未探测垫底。
    private var sortedChannels: [TVChannel] {
        scopedChannels.sorted { lhs, rhs in
            let left = tv.probeReport(for: lhs.id)
            let right = tv.probeReport(for: rhs.id)
            let leftRank = left.map { $0.isSuccess ? 1 : 0 } ?? 2
            let rightRank = right.map { $0.isSuccess ? 1 : 0 } ?? 2
            if leftRank != rightRank { return leftRank < rightRank }
            let leftLatency = left?.ttfbMilliseconds ?? Int.max
            let rightLatency = right?.ttfbMilliseconds ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 延迟最低的三个正常频道，给「最稳」角标。
    private var bestChannelIDs: Set<String> {
        let ranked = tv.channelsForFocusedSource.compactMap { channel -> (String, Int)? in
            guard let report = tv.probeReport(for: channel.id),
                  report.isSuccess,
                  let latency = report.ttfbMilliseconds else { return nil }
            return (channel.id, latency)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(3)
        .map(\.0)
        return Set(ranked)
    }

    /// 信号雷达：按 24 小时可用率 + 首帧延迟给频道排序，给出「今晚最稳的 10 个台」。
    private var radarChannels: [(channel: TVChannel, availability: Double, latency: Int?)] {
        var ranked: [(TVChannel, Double, Int?)] = []
        for channel in tv.visibleChannels {
            let report = tv.probeReport(for: channel.id)
            let availability = tv.availability(for: channel.id)
            guard availability != nil || report?.ttfbMilliseconds != nil else { continue }
            let score = availability ?? (report?.isSuccess == true ? 1 : 0)
            ranked.append((channel, score, report?.ttfbMilliseconds))
        }
        return ranked
            .sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 0.001 { return lhs.1 > rhs.1 }
                return (lhs.2 ?? Int.max) < (rhs.2 ?? Int.max)
            }
            .prefix(10)
            .map { (channel: $0.0, availability: $0.1, latency: $0.2) }
    }

    private var radarStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("信号雷达 · 今晚最稳")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("按 24 小时可用率与延迟排序")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(radarChannels.enumerated()), id: \.offset) { pair in
                        radarCard(rank: pair.offset + 1,
                                  channel: pair.element.channel,
                                  availability: pair.element.availability,
                                  latency: pair.element.latency)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func radarCard(rank: Int, channel: TVChannel,
                           availability: Double, latency: Int?) -> some View {
        Button {
            detailChannel = channel
        } label: {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(rank <= 3 ? TVBrand.gold : Color.secondary.opacity(0.6))
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("可用 \(Int(availability * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(availability >= 0.8 ? TVBrand.success : TVBrand.warning)
                        if let latency {
                            Text("\(latency)ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 176, alignment: .leading)
            .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(rank <= 3 ? TVBrand.gold.opacity(0.28) : TVBrand.stroke, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help("查看 \(channel.name) 的信号详情")
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        if tv.isProbingChannels {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer(minLength: 8)
                        if tv.isProbingChannels {
                            Button("停止探测") { tv.cancelProbes() }
                                .controlSize(.small)
                        }
                        Button {
                            tv.probeFocusedSourceChannels()
                        } label: {
                            Label("探测全部", systemImage: "waveform.path.ecg")
                                .font(.system(size: 11))
                        }
                        .disabled(tv.channelsForFocusedSource.isEmpty || tv.isProbingChannels)
                        Menu {
                            Button("检测全部源") { tv.checkAllSources() }
                                .disabled(tv.isChecking)
                            Button("清空截帧缓存") { tv.clearImageCaches() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("更多信号操作")
                    }

                    if !runningChecks.isEmpty {
                        sectionTitle("正在检测", count: runningChecks.count)
                        ForEach(runningChecks) { job in
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(jobTitle(job)).font(.system(size: 12, weight: .medium))
                                    Text(job.message ?? "排队中…")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.accentColor.opacity(0.07)))
                        }
                    }

                    sectionTitle("探测画面", count: sortedChannels.count)
                    if !radarChannels.isEmpty {
                        radarStrip
                    }
                    filterChips
                    if tv.probeReports.isEmpty {
                        emptySignalState
                    } else if sortedChannels.isEmpty {
                        Text("当前筛选下没有频道。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 208), spacing: 10)],
                                  spacing: 10) {
                            ForEach(sortedChannels) { channel in
                                TVSignalCard(channel: channel,
                                             number: tv.channelNumber(for: channel),
                                             report: tv.probeReport(for: channel.id),
                                             state: tv.probeState(for: channel.id),
                                             isFavorite: tv.isFavorite(channel),
                                             isBest: bestChannelIDs.contains(channel.id),
                                             onPlay: { store.openTVChannel(channel) },
                                             onProbe: {
                                                 Task { await tv.requestPreview(for: channel, force: true) }
                                             },
                                             onToggleFavorite: { tv.toggleFavorite(channel) },
                                             onDetail: { detailChannel = channel })
                            }
                        }
                    }

                    Rectangle()
                        .fill(TVBrand.hairline)
                        .frame(height: 0.8)
                        .padding(.vertical, 2)

                    sectionTitle("源状态", count: tv.playlists.count)
                    if tv.playlists.isEmpty {
                        Text("还没有电视源。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tv.playlists) { playlist in
                            statusRow(playlist)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        .sheet(item: $detailChannel) { channel in
            TVSignalDetailView(channel: channel,
                               report: tv.probeReport(for: channel.id),
                               state: tv.probeState(for: channel.id),
                               playlistName: tv.playlistName(for: channel.playlistID),
                               onPlay: {
                                   detailChannel = nil
                                   store.openTVChannel(channel)
                               },
                               onProbe: {
                                   Task { await tv.requestPreview(for: channel, force: true) }
                               },
                               onToggleFavorite: { tv.toggleFavorite(channel) },
                               isFavorite: tv.isFavorite(channel))
        }
        // 低频巡检：收藏频道先探，其余只补 6 小时前的旧结果。
        .task { tv.patrolStaleSignals() }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(SignalFilter.allCases) { item in
                let active = filter == item
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(active ? Color.accentColor : Color.primary.opacity(0.06),
                                    in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if tv.isProbingChannels {
                Text("已标注 \(tv.probeStates.values.filter { $0 == .available || $0 == .unavailable }.count) / \(tv.channelsForFocusedSource.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var emptySignalState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(TVBrand.wave)
                VStack(alignment: .leading, spacing: 2) {
                    Text("还没有探测结果")
                        .font(.system(size: 12, weight: .medium))
                    Text("探测会抓一帧真实画面，并记录首帧延迟、分辨率与码率。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("探测当前源") { tv.probeFocusedSourceChannels() }
                    .disabled(tv.channelsForFocusedSource.isEmpty)
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.06)))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 0.6)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }

    private func statusRow(_ playlist: TVPlaylist) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(playlist))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor(playlist))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(playlist.name).font(.system(size: 12, weight: .medium))
                    if !playlist.isEnabled {
                        Text("已停用").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
                if let message = playlist.lastError, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TVBrand.danger)
                        .lineLimit(2)
                } else if let checkedAt = playlist.lastCheckedAt {
                    HStack(spacing: 8) {
                        Text("\(playlist.lastChannelCount ?? 0) 个频道")
                        if let latency = playlist.lastLatencyMilliseconds { Text("\(latency) ms") }
                        Text(checkedAtText(checkedAt))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                } else {
                    Text("尚未检测").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button("检测") { tv.enqueueConnectionChecks([playlist.id]) }
                .controlSize(.small)
                .disabled(!playlist.isEnabled || tv.isChecking)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.regularMaterial))
        .opacity(playlist.isEnabled ? 1 : 0.7)
    }

    private func statusSymbol(_ playlist: TVPlaylist) -> String {
        if playlist.lastError != nil { return "exclamationmark.triangle.fill" }
        if playlist.lastCheckedAt != nil { return "checkmark.circle.fill" }
        return "circle.dashed"
    }

    private func statusColor(_ playlist: TVPlaylist) -> Color {
        if playlist.lastError != nil { return TVBrand.warning }
        if playlist.lastCheckedAt != nil { return TVBrand.success }
        return .secondary
    }

    private func checkedAtText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func jobTitle(_ job: JobProgress) -> String {
        guard let uuid = UUID(uuidString: String(job.sourceID.rawValue.dropFirst("tv:".count))) else {
            return "检测电视源"
        }
        return "检测 \(tv.playlistName(for: uuid))"
    }
}
