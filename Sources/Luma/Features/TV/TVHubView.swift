import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

/// 网络电视总览：直播 / 节目回看 / 信号 / 源库四个分页，分页切换在窗口工具栏里，
/// 与「网络存储」「网络资源」保持同一套结构。
struct TVHubView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv

    var body: some View {
        ZStack {
            TVBrand.background
            Group {
                if !tv.enabled {
                    TVDisabledView()
                } else {
                    switch tv.hubTab {
                    case .channels:
                        TVChannelsView()
                    case .tonight:
                        TVTonightView()
                    case .guide:
                        TVGuideView()
                    case .status:
                        TVStatusView()
                    case .overview:
                        TVOverviewView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 进入网络电视就按当前上限淘汰一次：台标 / 截帧 / 节目单的
            // 上限与保留天数不应只在「电视源」页生效。
            TVStorageCenter.pruneIfNeeded()
            // 不再强制落到某个源：没有焦点时频道页展示所有源聚合的频道墙。
            tv.refreshIfNeeded()
        }
        .onChange(of: tv.reminderNotice) { _, notice in
            guard let notice else { return }
            store.showToast(notice)
            tv.clearReminderNotice()
        }
        .onDisappear { tv.cancelProbes() }
    }
}

/// 工具栏中区的分页胶囊：频道 / 电视源 / 状态。
struct TVHubTabs: View {
    @Environment(IPTVBrowserModel.self) private var tv

    var body: some View {
        HubTabBar(items: TVHubTab.allCases,
                  active: tv.hubTab,
                  title: \.title,
                  symbol: \.symbol,
                  badge: badge(for:)) { tab in
            withAnimation(.easeOut(duration: 0.18)) {
                tv.setHubTab(tab)
            }
        }
        .disabled(!tv.enabled)
        .opacity(tv.enabled ? 1 : 0.5)
    }

    private func badge(for tab: TVHubTab) -> Int? {
        switch tab {
        case .overview: return tv.playlists.count
        case .channels: return tv.channelsForFocusedSource.count
        case .tonight: return nil
        case .guide: return tv.isLoadingEPG ? 1 : nil
        case .status: return tv.isChecking ? 1 : nil
        }
    }
}

/// 点开具体电视源后的工具栏中区：不再是总览分页，只保留「全部频道 + 当前源」。
struct TVFocusedSourceBar: View {
    @Environment(IPTVBrowserModel.self) private var tv
    let playlistID: UUID

    var body: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    tv.focusAllSources()
                    tv.setHubTab(.channels)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("全部频道")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回全部频道的聚合频道墙")

            Rectangle()
                .fill(TVBrand.hairline)
                .frame(width: 0.6, height: 13)

            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TVBrand.gold.opacity(0.9))
                Text(tv.playlistName(for: playlistID))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(tv.channelsForFocusedSource.count.formatted()) 频道")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
