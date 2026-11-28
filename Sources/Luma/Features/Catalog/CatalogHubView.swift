import SwiftUI

/// 网络资源区：资源 / 图集 / 榜单 / 日历 / 足迹 / 片单 / 关注七个分页。
/// 分页切换在窗口工具栏里（与标题同一行），内容区不再叠一条控制栏。
struct CatalogHubView: View {
    @Environment(CatalogBrowserModel.self) private var catalog

    var body: some View {
        Group {
            switch catalog.hubTab {
            case .browse:
                CatalogSourcesOverviewView()
            case .galleries:
                CatalogGalleryHubView()
            case .following:
                CatalogFollowingView()
            case .ranking:
                CatalogRankingView(sourceScope: catalog.resourceSourceIDs, compact: true)
            case .history:
                CatalogHistoryView(sourceScope: catalog.resourceSourceIDs, compact: true)
            case .playlists:
                CatalogPlaylistsView()
            case .calendar:
                CatalogCalendarView(sourceScope: catalog.resourceSourceIDs, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumaAmbientBackground(intensity: 0.55))
        // 进入网络资源就顺手预热图集墙：切到「图集」分页时不用再等一轮请求。
        .task { catalog.loadGalleryFeed() }
        // 图集站被删光时，「图集」分页要从工具栏消失，界面也退回资源总览。
        .onAppear { catalog.ensureHubTabAvailable() }
        .onChange(of: catalog.gallerySources.count) { _, _ in
            catalog.ensureHubTabAvailable()
        }
        // 切分页 / 离开网络资源区时收起二级页：工具栏的返回按钮不会残留到别的页面。
        .onChange(of: catalog.hubTab) { _, _ in
            catalog.followedProfile = nil
            catalog.openPlaylistPage = nil
        }
        .onDisappear {
            catalog.followedProfile = nil
            catalog.openPlaylistPage = nil
        }
    }
}

/// 工具栏中区的分页胶囊：资源 / 图集 / 榜单 / 日历 / 足迹 / 片单 / 关注。
struct CatalogHubTabs: View {
    @Environment(CatalogBrowserModel.self) private var catalog

    var body: some View {
        HubTabBar(items: catalog.visibleHubTabs,
                  active: catalog.hubTab,
                  title: \.title,
                  symbol: \.symbol) { tab in
            withAnimation(.easeOut(duration: 0.18)) {
                catalog.setHubTab(tab)
            }
        }
    }
}
