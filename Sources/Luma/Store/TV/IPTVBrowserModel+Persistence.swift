import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 持久化与重建

    func rebuildChannels() {
        let merged = playlists
            .filter(\.isEnabled)
            .flatMap { channelCache[$0.id] ?? [] }
        channels = TVChannelOrder.sorted(Self.sharingLogos(merged))
    }

    /// 同名频道跨源共用台标：只要有一个源给了图标，其它同名频道都复用它。
    /// 4K / 高清等画质版本缺台标时，复用同一频道的普通版本台标；
    /// 全都没有的保持为空，由界面统一用同一枚占位图标，节目单和播放窗口一致。
    static func sharingLogos(_ list: [TVChannel]) -> [TVChannel] {
        var shared: [String: String] = [:]
        for channel in list {
            guard let logo = channel.logoURL, !logo.isEmpty else { continue }
            let key = aggregationKey(channel.name)
            if shared[key] == nil { shared[key] = logo }
        }

        // 去掉画质后缀后的台标池：优先采用普通版本（非 4K / 高清）的图标。
        var baseShared: [String: String] = [:]
        var baseIsVariant: [String: Bool] = [:]
        for channel in list {
            guard let logo = channel.logoURL, !logo.isEmpty else { continue }
            let key = logoKey(channel.name)
            let variant = key != aggregationKey(channel.name)
            if baseShared[key] == nil || (baseIsVariant[key] == true && !variant) {
                baseShared[key] = logo
                baseIsVariant[key] = variant
            }
        }

        guard !shared.isEmpty || !baseShared.isEmpty else { return list }
        return list.map { channel in
            if let logo = channel.logoURL, !logo.isEmpty { return channel }
            let exact = aggregationKey(channel.name)
            guard let logo = shared[exact] ?? baseShared[logoKey(channel.name)] else { return channel }
            var copy = channel
            copy.logoURL = logo
            return copy
        }
    }

    /// 台标匹配键：先去掉 4K / 高清 / HDR 等画质标记，再归一化，
    /// 让「深圳卫视 4K」与「深圳卫视」共用同一枚台标。
    static func logoKey(_ name: String) -> String {
        var text = name.lowercased()
        for token in ["超高清", "高清", "标清", "蓝光", "4k", "8k", "uhd", "fhd",
                      "h265", "h.265", "hevc", "hdr"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // HD / SD 只在两侧不是英文字母时去掉，避免误伤 NHK 这类台名。
        text = text.replacingOccurrences(of: "(?<![a-z])(hd|sd)(?![a-z])",
                                          with: "",
                                          options: .regularExpression)
        return text.filter { $0.isLetter || $0.isNumber }
    }

    func persistPlaylists() {
        database.savePlaylists(playlists)
    }
}
