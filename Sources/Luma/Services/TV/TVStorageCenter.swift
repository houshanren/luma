import Foundation

/// 直播电视产生的缓存种类。
enum TVCacheKind: String, CaseIterable, Identifiable {
    case channels
    case epg
    case logos
    case previews
    case probes
    case localPlaylists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .channels: return "频道缓存"
        case .epg: return "节目单缓存"
        case .logos: return "台标缓存"
        case .previews: return "频道画面预览"
        case .probes: return "检测结果"
        case .localPlaylists: return "本地 M3U 文件"
        }
    }

    var symbol: String {
        switch self {
        case .channels: return "tv"
        case .epg: return "calendar"
        case .logos: return "photo.on.rectangle"
        case .previews: return "rectangle.on.rectangle"
        case .probes: return "waveform.path.ecg"
        case .localPlaylists: return "doc"
        }
    }

    /// 本地 M3U 属于导入数据：清掉会让对应电视源失效，只统计占用，不提供清理。
    var canClear: Bool { self != .localPlaylists }
}

/// 一条缓存的状态：数量、占用与当前的淘汰策略。
struct TVCacheStat: Identifiable {
    var kind: TVCacheKind
    var detail: String
    var sizeText: String
    var policy: String?

    var id: String { kind.rawValue }
    var title: String { kind.title }
    var symbol: String { kind.symbol }
    var canClear: Bool { kind.canClear }
}

/// 直播缓存的统计、清理与淘汰。
/// 上限 / 保留天数写进电视库设置，跟着图库走；改动后立即按新策略淘汰一次。
enum TVStorageCenter {
    static let logoLimitOptions = [100, 200, 500, 0]
    static let previewLimitOptions = [50, 100, 200, 0]
    static let epgRetentionOptions = [3, 7, 30, 0]

    private static let logoLimitKey = "cache.logoLimitMB"
    private static let previewLimitKey = "cache.previewLimitMB"
    private static let epgRetentionKey = "cache.epgRetentionDays"

    static var logoLimitMB: Int {
        intValue(logoLimitKey, fallback: 200)
    }

    static var previewLimitMB: Int {
        intValue(previewLimitKey, fallback: 100)
    }

    static var epgRetentionDays: Int {
        intValue(epgRetentionKey, fallback: 7)
    }

    static func setLogoLimitMB(_ value: Int) {
        TVDatabase.shared.setSetting(logoLimitKey, String(value))
        pruneIfNeeded()
    }

    static func setPreviewLimitMB(_ value: Int) {
        TVDatabase.shared.setSetting(previewLimitKey, String(value))
        pruneIfNeeded()
    }

    static func setEPGRetentionDays(_ value: Int) {
        TVDatabase.shared.setSetting(epgRetentionKey, String(value))
        pruneIfNeeded()
    }

    // MARK: - 统计

    static func stats(probeRecords: Int, sourceCount: Int) -> [TVCacheStat] {
        var result: [TVCacheStat] = []

        let channels = TVDatabase.shared.channelCacheStats()
        result.append(TVCacheStat(
            kind: .channels,
            detail: "\(channels.rows.formatted()) 个频道 · \(sourceCount) 个电视源",
            sizeText: sizeText(channels.bytes),
            policy: "清理后进入源会重新拉取"))

        let epg = TVEPGService.diskUsage()
        let epgCount = max(0, epg.files / 2)
        result.append(TVCacheStat(
            kind: .epg,
            detail: "\(epgCount) 份节目单" + (epg.newest.map { " · 最新 \(dateText($0))" } ?? ""),
            sizeText: sizeText(epg.bytes),
            policy: epgRetentionDays > 0 ? "保留 \(epgRetentionDays) 天" : "不自动淘汰"))

        let logos = directoryUsage(LibraryPaths.tvLogosDir)
        result.append(TVCacheStat(
            kind: .logos,
            detail: "\(logos.files.formatted()) 张台标",
            sizeText: sizeText(logos.bytes),
            policy: limitText(logoLimitMB)))

        let previews = directoryUsage(LibraryPaths.tvPreviewsDir)
        result.append(TVCacheStat(
            kind: .previews,
            detail: "\(previews.files.formatted()) 张截帧 · 30 分钟保鲜",
            sizeText: sizeText(previews.bytes),
            policy: limitText(previewLimitMB)))

        result.append(TVCacheStat(
            kind: .probes,
            detail: "\(probeRecords.formatted()) 条可用性 / 延迟记录",
            sizeText: "内存",
            policy: "不写磁盘"))

        let local = directoryUsage(LibraryPaths.tvPlaylistsDir)
        result.append(TVCacheStat(
            kind: .localPlaylists,
            detail: "\(local.files.formatted()) 个导入文件",
            sizeText: sizeText(local.bytes),
            policy: "导入数据，清理会让对应源失效"))

        return result
    }

    // MARK: - 清理

    @MainActor
    static func clear(_ kind: TVCacheKind, model: IPTVBrowserModel) async {
        switch kind {
        case .channels: model.clearChannelCache()
        case .epg: model.clearEPGCache()
        case .logos: await TVLogoCache.shared.clearAll()
        case .previews: await TVPreviewCache.shared.clearAll()
        case .probes: model.clearProbeCache()
        case .localPlaylists: break
        }
    }

    @MainActor
    static func clearAll(model: IPTVBrowserModel) async {
        for kind in TVCacheKind.allCases where kind.canClear {
            await clear(kind, model: model)
        }
    }

    // MARK: - 淘汰

    /// 按当前上限淘汰：台标 / 截帧按体积删最旧，节目单按保留天数删过期文件。
    static func pruneIfNeeded() {
        pruneDirectory(LibraryPaths.tvLogosDir, limitMB: logoLimitMB)
        pruneDirectory(LibraryPaths.tvPreviewsDir, limitMB: previewLimitMB)
        if epgRetentionDays > 0 {
            TVEPGService.pruneCache(olderThan: Double(epgRetentionDays))
        }
    }

    private static func pruneDirectory(_ directory: URL, limitMB: Int) {
        guard limitMB > 0 else { return }
        let limit = Int64(limitMB) * 1024 * 1024
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ), !urls.isEmpty else { return }

        var entries: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((url, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - 工具

    private struct DirectoryUsage {
        var files: Int
        var bytes: Int64
    }

    private static func directoryUsage(_ directory: URL) -> DirectoryUsage {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return DirectoryUsage(files: 0, bytes: 0) }
        var bytes: Int64 = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            bytes += Int64(values?.fileSize ?? 0)
        }
        return DirectoryUsage(files: urls.count, bytes: bytes)
    }

    private static func intValue(_ key: String, fallback: Int) -> Int {
        guard let raw = TVDatabase.shared.setting(key), let value = Int(raw) else { return fallback }
        return value
    }

    private static func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func limitText(_ limitMB: Int) -> String {
        limitMB > 0 ? "上限 \(limitMB) MB" : "不限体积"
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
