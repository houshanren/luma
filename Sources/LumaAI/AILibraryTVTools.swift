import Foundation
import LumaDomain

/// 网络电视的智能助手工具：源库、频道、节目单、直播 / 回看、收藏与导航。
package extension AILibraryTools {
    static let tvWriteToolNames: Set<String> = ["favorite_tv_channel"]

    static var tvToolDefinitions: [AIRequestTool] {
        [listTVSources, listTVChannels, getTVGuide, tvTonight,
         playTVChannel, favoriteTVChannel, navigateTV]
    }

    private static var listTVSources: AIRequestTool {
        AIRequestTool(
            name: "list_tv_sources",
            description: "列出网络电视的全部电视源：id、名称、地区、是否启用、频道数、延迟与错误。之后可用源 id 过滤频道或直接打开某个源。",
            parameters: objectSchema([:])
        )
    }

    private static var listTVChannels: AIRequestTool {
        AIRequestTool(
            name: "list_tv_channels",
            description: "列出网络电视的频道（可跨源聚合）：频道 id、名称、分组、省份、来源、画质、线路数与可回看天数。支持关键词、电视源与分组筛选，一次最多 2000 个。",
            parameters: objectSchema([
                "query": stringSchema("频道名、分组或省份关键词，可省略"),
                "source": stringSchema("只列某个电视源：源 id 或名称，可省略"),
                "group": stringSchema("只看某个分组，例如「央视」「卫视」，可省略"),
                "limit": integerSchema("最多返回多少个频道，默认 200，最大 2000", minimum: 1, maximum: 2000)
            ])
        )
    }

    private static var getTVGuide: AIRequestTool {
        AIRequestTool(
            name: "get_tv_guide",
            description: "查看某个频道某天的节目单：开始 / 结束时间、标题、简介与是否可回看。day_offset 0 为今天，-1 昨天，最多前后 3 天。",
            parameters: objectSchema([
                "channel": stringSchema("频道名称或频道 id"),
                "source": stringSchema("限定电视源：源 id 或名称，可省略"),
                "day_offset": integerSchema("相对今天的天数偏移，-3…3，默认 0", minimum: -3, maximum: 3),
                "limit": integerSchema("最多返回多少个节目，默认 60，最大 200", minimum: 1, maximum: 200)
            ], required: ["channel"])
        )
    }

    private static var tvTonight: AIRequestTool {
        AIRequestTool(
            name: "tv_tonight",
            description: "今晚节目聚合：默认看收藏频道，也可以传 channels 指定频道；返回每个频道从现在开始的若干档节目与是否正在直播。回答「今晚看什么」「收藏的频道在播什么」时用它；只看单个频道用 get_tv_guide。",
            parameters: objectSchema([
                "channels": arraySchema(["type": "string"],
                                        description: "频道名称或 id 列表，可省略则用收藏频道"),
                "day_offset": integerSchema("相对今天的天数偏移，0…3，默认 0", minimum: 0, maximum: 3),
                "limit": integerSchema("每个频道最多返回几个节目，默认 4，最大 20", minimum: 1, maximum: 20)
            ])
        )
    }

    private static var playTVChannel: AIRequestTool {
        AIRequestTool(
            name: "play_tv_channel",
            description: "播放电视直播，或回看某个节目。channel 传频道名称或 id；回看时传 catch_up=true 并用 program 指定节目标题片段。只打开播放器，不修改数据。",
            parameters: objectSchema([
                "channel": stringSchema("频道名称或频道 id"),
                "source": stringSchema("限定电视源：源 id 或名称，可省略"),
                "catch_up": booleanSchema("true 为回看节目，默认 false 播放直播"),
                "program": stringSchema("要回看的节目名称片段；catch_up 时使用，可省略则取当天第一个节目"),
                "day_offset": integerSchema("回看日期相对今天的天数偏移，-3…3，默认 0",
                                            minimum: -3, maximum: 3)
            ], required: ["channel"])
        )
    }

    private static var favoriteTVChannel: AIRequestTool {
        AIRequestTool(
            name: "favorite_tv_channel",
            description: "收藏或取消收藏电视频道。targets 可传频道名称或频道 id。",
            parameters: objectSchema([
                "targets": arraySchema(["type": "string"], description: "频道名称或频道 id"),
                "favorite": booleanSchema("true 收藏，false 取消收藏"),
                "source": stringSchema("限定电视源：源 id 或名称，可省略")
            ], required: ["targets", "favorite"])
        )
    }

    private static var navigateTV: AIRequestTool {
        AIRequestTool(
            name: "navigate_tv",
            description: "打开网络电视并切换分页 / 源 / 分组 / 搜索：tab 可选 channels 直播、tonight 夜航、guide 节目回看、status 信号、overview 源库。只改变界面，不修改数据。",
            parameters: objectSchema([
                "source": stringSchema("电视源 id 或名称；省略则全部频道"),
                "tab": enumSchema(["channels", "tonight", "guide", "status", "overview"],
                                  "要打开的分页，默认 channels"),
                "group": stringSchema("频道分组，例如「央视」「卫视」，可省略"),
                "search": stringSchema("频道搜索词，可省略"),
                "day_offset": integerSchema("节目回看的日期偏移，-3…3，可省略",
                                            minimum: -3, maximum: 3)
            ])
        )
    }

    // MARK: - 确认弹窗文案

    static func describeTV(_ call: AIToolCall) -> String? {
        guard call.name == "favorite_tv_channel" else { return nil }
        let args = arguments(call.arguments)
        let favorite = bool(args["favorite"], fallback: true)
        let count = stringArray(args["targets"]).count
        return "\(favorite ? "收藏" : "取消收藏") \(count) 个电视频道"
    }
}
