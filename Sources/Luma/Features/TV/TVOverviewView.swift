import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 总览

/// 网络电视总览：与「网络存储 · 存储」页同构——大标题 + 聚合入口 + 源卡片，
/// 源卡片上直接完成启用、检测与进入频道墙。
struct TVOverviewView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var epgEditingID: UUID?
    @State private var epgDraft = ""
    /// 拖动源时的落点行：画一条提示线。
    @State private var dropTargetID: UUID?
    /// 直播缓存统计：进入页面或清理后刷新。
    @State private var cacheStats: [TVCacheStat] = []
    @State private var cacheBusy: TVCacheKind?
    @State private var cacheTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                aggregateCard
                if tv.playlists.isEmpty {
                    emptyState
                } else {
                    sourceList
                }
                liveCacheSection
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: cacheTick) {
            TVStorageCenter.pruneIfNeeded()
            cacheStats = TVStorageCenter.stats(
                probeRecords: tv.probeStates.count + tv.probeReports.count,
                sourceCount: tv.playlists.count)
        }
        .onChange(of: tv.playlists.count) { _, _ in
            cacheTick += 1
        }
        .alert("重命名电视源", isPresented: Binding(get: { renamingID != nil },
                                              set: { if !$0 { renamingID = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingID = nil }
            Button("保存") {
                if let id = renamingID { tv.renamePlaylist(id, to: renameText) }
                renamingID = nil
            }
        } message: {
            Text("只改显示名称，播放地址不变。")
        }
        .sheet(isPresented: Binding(get: { epgEditingID != nil },
                                   set: { if !$0 { epgEditingID = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("EPG 节目单地址")
                    .font(.system(size: 15, weight: .semibold))
                Text("填写 XMLTV 地址后，「节目单」与「回看」会用它匹配频道。留空表示不额外使用该源的 EPG；拾光还会自动合并内置的公共补充节目单（历史 3 天、未来 3 天）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://example.com/epg.xml", text: $epgDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { epgEditingID = nil }
                    Button("保存") {
                        if let id = epgEditingID {
                            tv.setEPGURL(epgDraft, for: id)
                        }
                        epgEditingID = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 440)
        }
    }

    /// 检测 / 导入：从前一行标题区挪到「电视源」分组标题右侧。
    private var sourceActions: some View {
        HStack(spacing: 8) {
            if tv.isChecking {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("检测中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                tv.checkAllSources()
            } label: {
                Label("检测全部", systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(TVBrand.panel, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(tv.isChecking)
            .help("按顺序逐一检测每个已启用的电视源")
            Button {
                tv.showWizard = true
            } label: {
                Label("接入电视源", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(TVBrand.panel, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            transferMenu
        }
    }

    /// 电视源导出：导入统一收进「接入电视源」，这里只负责分享给其他人。
    private var transferMenu: some View {
        SourceExportButton(scope: .television,
                           count: tv.playlists.count,
                           exportData: { tv.exportPlaylistBundle() })
    }

    /// 聚合入口：所有已启用源合并成一堵频道墙。
    private var aggregateCard: some View {
        Button {
            tv.focusAllSources()
            tv.setHubTab(.channels)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [TVBrand.wave, TVBrand.signal],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.78))
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("全频直播")
                            .font(.system(size: 15, weight: .semibold))
                        Text("聚合")
                            .font(.system(size: 9))
                            .foregroundStyle(TVBrand.wave)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TVBrand.wave.opacity(0.14),
                                        in: Capsule(style: .continuous))
                    }
                    Text("\(tv.playlists.filter(\.isEnabled).count) 个源 · \(tv.aggregateChannelCount) 个频道合并展示")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TVBrand.cardTop)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(TVBrand.wave.opacity(0.35), lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(tv.aggregateChannelCount == 0)
        .help("不区分来源，展示所有已启用源的全部频道")
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("电视源")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(tv.playlists.filter(\.isEnabled).count) / \(tv.playlists.count) 已启用")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                sourceActions
            }
            LazyVStack(spacing: 10) {
                ForEach(tv.playlists) { playlist in
                    sourceRow(playlist)
                        .overlay(alignment: .top) {
                            if dropTargetID == playlist.id {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .padding(.horizontal, 10)
                            }
                        }
                        .onDrop(of: [tvSourceDragType],
                                delegate: TVSourceReorderDropDelegate(
                                    target: playlist.id,
                                    tv: tv,
                                    onTargeted: { targeted in
                                        if targeted {
                                            dropTargetID = playlist.id
                                        } else if dropTargetID == playlist.id {
                                            dropTargetID = nil
                                        }
                                    }))
                }
                // 拖到末尾 → 排到最后。
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [tvSourceDragType],
                            delegate: TVSourceEndDropDelegate(tv: tv))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LumaEmptyState(symbol: "antenna.radiowaves.left.and.right.slash",
                           title: "还没有电视源",
                           actions: [
                               LumaEmptyAction(title: "接入电视源…",
                                               symbol: "square.and.arrow.down",
                                               filled: true) {
                                   tv.showWizard = true
                               }
                           ])
        }
    }

    // MARK: - 直播缓存

    /// 直播电视产生的各类缓存：逐项列出数量与占用，可单独清理，
    /// 台标 / 截帧可设体积上限，节目单可设保留天数，超出后自动淘汰。
    private var liveCacheSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("直播缓存")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(cacheStats.count) 项")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if cacheBusy != nil {
                    ProgressView().controlSize(.mini)
                }
                Button("全部清理") {
                    clearAllLiveCaches()
                }
                .controlSize(.small)
                .disabled(cacheBusy != nil)
                .help("清理除本地 M3U 之外的全部直播缓存")
            }
            Text("刷新源、抓节目单与截帧留下的缓存；清理不会删除电视源。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            if !cacheStats.isEmpty {
                VStack(spacing: 0) {
                    ForEach(cacheStats) { stat in
                        liveCacheRow(stat)
                        if stat.id != cacheStats.last?.id {
                            Divider()
                                .opacity(0.25)
                                .padding(.leading, 43)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
            }
        }
    }

    private func liveCacheRow(_ stat: TVCacheStat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: stat.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TVBrand.wave)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(stat.title)
                    .font(.system(size: 12, weight: .medium))
                Text(stat.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let policy = stat.policy {
                    Text(policy)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(stat.sizeText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)

            limitMenu(for: stat.kind)

            if stat.canClear {
                Button("清理") { clearLiveCache(stat.kind) }
                    .controlSize(.small)
                    .disabled(cacheBusy != nil)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func limitMenu(for kind: TVCacheKind) -> some View {
        switch kind {
        case .logos:
            limitPicker(options: TVStorageCenter.logoLimitOptions,
                        current: TVStorageCenter.logoLimitMB,
                        unit: "MB",
                        help: "台标缓存上限") { value in
                TVStorageCenter.setLogoLimitMB(value)
                cacheTick += 1
            }
        case .previews:
            limitPicker(options: TVStorageCenter.previewLimitOptions,
                        current: TVStorageCenter.previewLimitMB,
                        unit: "MB",
                        help: "画面截帧上限") { value in
                TVStorageCenter.setPreviewLimitMB(value)
                cacheTick += 1
            }
        case .epg:
            limitPicker(options: TVStorageCenter.epgRetentionOptions,
                        current: TVStorageCenter.epgRetentionDays,
                        unit: "天",
                        help: "节目单保留天数") { value in
                TVStorageCenter.setEPGRetentionDays(value)
                cacheTick += 1
            }
        default:
            EmptyView()
        }
    }

    private func limitPicker(options: [Int],
                             current: Int,
                             unit: String,
                             help: String,
                             onPick: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { value in
                Button {
                    onPick(value)
                } label: {
                    if value == current {
                        Label(limitTitle(value, unit: unit), systemImage: "checkmark")
                    } else {
                        Text(limitTitle(value, unit: unit))
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    private func limitTitle(_ value: Int, unit: String) -> String {
        value > 0 ? "\(value) \(unit)" : "不限"
    }

    private func clearLiveCache(_ kind: TVCacheKind) {
        guard cacheBusy == nil else { return }
        cacheBusy = kind
        Task {
            await TVStorageCenter.clear(kind, model: tv)
            cacheBusy = nil
            cacheTick += 1
        }
    }

    private func clearAllLiveCaches() {
        guard cacheBusy == nil else { return }
        cacheBusy = .channels
        Task {
            await TVStorageCenter.clearAll(model: tv)
            cacheBusy = nil
            cacheTick += 1
        }
    }

    private func sourceRow(_ playlist: TVPlaylist) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 卡片主体与「网络存储」一致：点一下进入该源的频道墙。
            Button {
                tv.focusPlaylist(playlist.id)
                tv.setHubTab(.channels)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: playlist.isEnabled ? "tv.fill" : "tv.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(playlist.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(playlist.name)
                                .font(.system(size: 12.5, weight: .semibold))
                            // 导入时不再区分地区，默认按大陆处理；只有历史源还带上港台等标记时才显示。
                            if playlist.region != .mainland {
                                Text(playlist.region.title)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.07),
                                                in: Capsule(style: .continuous))
                            }
                        }
                        Text(playlist.displayAddress)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        if let epg = playlist.epgURLString, !epg.isEmpty {
                            Text("EPG · \(epg)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        healthLine(playlist)
                        let categories = tv.categoryGroups(for: playlist.id)
                        if !categories.isEmpty {
                            Text(categories.prefix(5).map { "\($0.group) \($0.count)" }
                                .joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 拖动排序：顺序写进电视库，侧边栏与频道页同步生效。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .contentShape(Rectangle())
                .onDrag { tvSourceDragProvider(playlist.id) }
                .help("拖动调整源顺序")

            Toggle("", isOn: Binding(get: { playlist.isEnabled },
                                     set: { tv.setPlaylistEnabled(playlist.id, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Button("检测") { tv.enqueueConnectionChecks([playlist.id]) }
                .controlSize(.small)
                .disabled(tv.isChecking)

            Menu {
                Button("重命名…") {
                    renameText = playlist.name
                    renamingID = playlist.id
                }
                Button("设置 EPG 地址…") {
                    epgDraft = playlist.epgURLString ?? ""
                    epgEditingID = playlist.id
                }
                Button("删除这个源", role: .destructive) { tv.removePlaylist(playlist.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .opacity(playlist.isEnabled ? 1 : 0.72)
    }

    @ViewBuilder
    private func healthLine(_ playlist: TVPlaylist) -> some View {
        if let message = playlist.lastError, !message.isEmpty {
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(TVBrand.danger)
                .lineLimit(2)
        } else if let checkedAt = playlist.lastCheckedAt {
            HStack(spacing: 8) {
                Label("\(playlist.lastChannelCount ?? 0) 个频道", systemImage: "tv")
                if let latency = playlist.lastLatencyMilliseconds {
                    Label("\(latency) ms", systemImage: "bolt.fill")
                }
                Text(relativeText(checkedAt))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        } else {
            Text("尚未检测")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func relativeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return "检测于 " + formatter.localizedString(for: date, relativeTo: Date())
    }
}
