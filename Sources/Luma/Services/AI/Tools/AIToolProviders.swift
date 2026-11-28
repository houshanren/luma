import Foundation

/// 各业务模块注册给智能助手的工具来源。
/// 每个 provider 自己声明定义与执行，中央 switch 只保留图库基础工具。
/// 「是否由本 provider 处理」由定义列表推导（`AIToolProvider.handles`），不在这里重复维护名字集合。
enum AIToolProviders {
    /// 网络资源工具：来源列表、检索、稍后看与档案跟随都在这里。
    @MainActor
    static func catalog(store: LibraryStore) -> AIToolProvider {
        AIToolProvider(
            name: "catalog",
            definitions: AILibraryTools.catalogToolDefinitions,
            execute: { call, args in
                switch call.name {
                case "list_catalog_sources": return store.listCatalogSourcesTool()
                case "search_catalog": return await store.searchCatalogTool(args)
                case "list_catalog_following": return store.listCatalogFollowingTool()
                case "list_catalog_watchlist": return store.listCatalogWatchlistTool(args)
                case "catalog_new_today": return store.catalogNewTodayTool(args)
                case "browse_catalog": return store.browseCatalogTool(args)
                case "play_catalog_item": return store.playCatalogItemTool(args)
                case "set_catalog_watchlist": return store.setCatalogWatchlistTool(args)
                case "follow_catalog_person": return store.followCatalogPersonTool(args)
                default:
                    return store.failure("资源工具未注册：\(call.name)")
                }
            }
        )
    }

    /// 网络影院工具：聚合列表、跨源搜索、续看与播放。影视源仍由资源页管理。
    @MainActor
    static func networkCinema(store: LibraryStore) -> AIToolProvider {
        AIToolProvider(
            name: "networkCinema",
            definitions: AILibraryTools.networkCinemaToolDefinitions,
            execute: { call, args in
                switch call.name {
                case "list_network_cinema_sources": return store.listNetworkCinemaSourcesTool()
                case "list_network_cinema": return store.listNetworkCinemaTool(args)
                case "search_network_cinema": return await store.searchNetworkCinemaTool(args)
                case "network_cinema_history": return store.networkCinemaHistoryTool(args)
                case "play_network_cinema": return store.playNetworkCinemaTool(args)
                default:
                    return store.failure("网络影院工具未注册：\(call.name)")
                }
            }
        )
    }

    /// 网络电视工具：源库、频道、节目单、直播 / 回看与导航。
    @MainActor
    static func television(store: LibraryStore) -> AIToolProvider {
        AIToolProvider(
            name: "television",
            definitions: AILibraryTools.tvToolDefinitions,
            execute: { call, args in
                switch call.name {
                case "list_tv_sources": return store.listTVSourcesTool()
                case "list_tv_channels": return await store.listTVChannelsTool(args)
                case "get_tv_guide": return await store.getTVGuideTool(args)
                case "tv_tonight": return await store.tvTonightTool(args)
                case "play_tv_channel": return await store.playTVChannelTool(args)
                case "favorite_tv_channel": return store.favoriteTVChannelTool(args)
                case "navigate_tv": return store.navigateTVTool(args)
                default:
                    return store.failure("电视工具未注册：\(call.name)")
                }
            }
        )
    }

    /// 影院工具：定义与执行都留在这个 provider 里，中央 switch 不再感知影院细节。
    @MainActor
    static func cinema(store: LibraryStore) -> AIToolProvider {
        AIToolProvider(
            name: "cinema",
            definitions: AILibraryTools.cinemaToolDefinitions,
            execute: { call, args in
                switch call.name {
                case "list_cinema_items": return store.listCinemaItemsTool(args)
                case "list_cinema_scopes": return store.listCinemaScopesTool()
                case "cinema_health_report": return store.cinemaHealthReportTool(args)
                case "cinema_tree": return store.cinemaTreeTool(args)
                case "search_cinema_candidates": return await store.searchCinemaCandidatesTool(args)
                case "apply_cinema_match": return store.applyCinemaMatchTool(args)
                case "scrape_cinema": return store.scrapeCinemaTool(args)
                case "match_cinema": return await store.matchCinemaTool(args)
                case "search_cinema_library": return store.searchCinemaLibraryTool(args)
                case "list_cinema_series": return store.listCinemaSeriesTool(args)
                case "list_cinema_activity": return store.listCinemaActivityTool(args)
                case "list_cinema_lists": return store.listCinemaListsTool(args)
                case "navigate_cinema": return store.navigateCinemaTool(args)
                case "play_cinema": return store.playCinemaTool(args)
                case "update_cinema_state": return store.updateCinemaStateTool(args)
                case "manage_cinema_list": return store.manageCinemaListTool(args)
                case "ignore_cinema": return store.ignoreCinemaTool(args)
                case "restore_cinema_ignored": return store.restoreCinemaIgnoredTool(args)
                case "refresh_cinema_metadata": return await store.refreshCinemaMetadataTool(args)
                case "set_cinema_intro_skip": return store.setCinemaIntroSkipTool(args)
                case "manage_cinema_progress": return store.manageCinemaProgressTool(args)
                default:
                    return store.failure("影院工具未注册：\(call.name)")
                }
            }
        )
    }
}
