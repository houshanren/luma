import Foundation
import LumaContentCore
import PlaybackCore
import TestSupport

@MainActor
func runIPTVChecks() {

    let m3uSample = """
    #EXTM3U
    #EXTINF:-1 tvg-id="CCTV1.cn@SD" tvg-logo="https://logo/1.png" group-title="News",CCTV-1 (720p)
    http://example.com/cctv1_sd.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn@HD" tvg-logo="https://logo/1.png" group-title="News" catchup-source="https://example.com/catchup/${start}/${end}" catchup-days="7",CCTV-1 (1080p)
    https://example.com/cctv1_hd.m3u8
    #EXTINF:-1 tvg-id="RTHKTV31.hk@SD" group-title="General",RTHK TV 31 (1080p) [Geo-blocked]
    rtmp://example.com/live
    #EXTINF:-1 tvg-id="FTV.tw@SD" group-title="General",FTV (Taiwan) (720p) [Not 24/7]
    http://example.com/ftv.m3u8
    """
    let m3uEntries = M3UPlaylist.parse(m3uSample)
    expectEqual(m3uEntries.count, 4, "M3U 解析条数")
    expectEqual(m3uEntries.first?.name ?? "", "CCTV-1", "M3U 展示名去掉画质标记")
    expectEqual(m3uEntries.first?.groupTitle ?? "", "News", "M3U 解析 group-title")
    expectEqual(m3uEntries.count > 1 ? m3uEntries[1].catchUpSource ?? "" : "",
                "https://example.com/catchup/${start}/${end}", "M3U 解析 catchup-source")
    expectEqual(m3uEntries.count > 1 ? m3uEntries[1].catchUpDays ?? 0 : 0, 7, "M3U 解析 catchup-days")

    let m3uBest = M3UPlaylist.bestChannels(from: m3uEntries)
    expectEqual(m3uBest.count, 2, "同频道去重并丢弃不可播放协议")
    let cctvBest = m3uBest.first { $0.key == "cctv1.cn" }
    expectEqual(cctvBest?.entry.url ?? "", "https://example.com/cctv1_hd.m3u8", "优先选高画质线路")
    expectEqual(cctvBest?.qualityLabel ?? "", "1080p", "画质标签正确")

    let m3uWithOptions = M3UPlaylist.parse("""
    #EXTM3U
    #EXTVLCOPT:http-referrer=https://ignored.example
    #EXTINF:-1 tvg-id="X.cn",X 频道
    #EXTVLCOPT:http-user-agent=LumaTV
    #EXTVLCOPT:http-referrer=https://ref2.example
    https://example.com/x.m3u8
    """)
    expectEqual(m3uWithOptions.first?.headers["Referer"] ?? "", "https://ref2.example", "VLC 选项解析 Referer")
    expectEqual(m3uWithOptions.first?.headers["User-Agent"] ?? "", "LumaTV", "VLC 选项解析 UA")
    expectEqual(m3uWithOptions.first?.isHLS ?? false, true, "m3u8 识别为 HLS")



    expectEqual(TVChannelNames.chinese(name: "CCTV-1 HD", key: "CCTV1.cn@HD"),
                "央视一套（综合）", "央视一台翻译")
    expectEqual(TVChannelNames.chinese(name: "CCTV-5+", key: "CCTV5Plus.cn"),
                "央视五套+（体育赛事）", "央视五套+翻译")
    expectEqual(TVChannelNames.chinese(name: "Beijing Satellite TV HD", key: "BeijingSatelliteTV.cn@HD"),
                "北京卫视", "卫星台翻译")
    expectEqual(TVChannelNames.chinese(name: "Guizhou TV", key: "GuizhouTV.cn"),
                "贵州卫视", "省级主频道翻译")
    expectEqual(TVChannelNames.chinese(name: "RTHK TV 31", key: "RTHKTV31.hk"),
                "港台电视31", "香港频道翻译")
    expectEqual(TVChannelNames.chinese(name: "Hakka TV", key: "HakkaTV.tw"),
                "客家电视台", "台湾频道翻译")
    expectEqual(TVChannelNames.chinese(name: "Chuzhou News Channel", key: "ChuzhouNewsChannel.cn"),
                "滁州新闻频道", "城市频道翻译")
    expectEqual(TVChannelNames.chinese(name: "Some Unknown TV", key: "unknown.tv"),
                "Some Unknown TV", "未匹配的频道保留原名")

    expectEqual(TVChannelNames.chinese(name: "BBC One", key: "BBCOne.uk"),
                "BBC 第一台", "英国频道翻译")
    expectEqual(TVChannelNames.chinese(name: "NHK General TV JOJG-DTV", key: "NHKGeneralTV.jp"),
                "NHK 综合台", "日本频道翻译")
    expectEqual(TVChannelNames.chinese(name: "KBS1", key: "KBS1.kr"),
                "KBS 1台", "韩国频道翻译")
    expectEqual(TVChannelNames.chinese(name: "Das Erste HD", key: "DasErste.de"),
                "德国一台（ARD）", "德国频道翻译")
    expectEqual(TVChannelNames.chinese(name: "RAI 1", key: "RAI1.it"),
                "RAI 一台", "意大利频道翻译")
    expectEqual(TVChannelNames.chinese(name: "TF1", key: "TF1.fr"),
                "TF1 一台", "法国频道翻译")
    expectEqual(TVChannelNames.chinese(name: "Channel 5 (Singapore)", key: "Channel5.sg"),
                "新加坡5台", "新加坡频道翻译")
    expectEqual(TVChannelNames.chinese(name: "Cartoon Network (Japan) HD", key: "CartoonNetworkJapan.jp"),
                "卡通频道（日本）", "带国家后缀的频道翻译")
    expectEqual(TVChannelNames.chinese(name: "CNN", key: "CNN.us"),
                "CNN 新闻", "美国频道翻译")

    // 地方台按省份聚合
    expectEqual(TVProvinces.section(for: "央视一套（综合）"), "央视", "央视归入央视")
    expectEqual(TVProvinces.section(for: "CCTV-5 体育"), "央视", "CCTV 归入央视")
    expectEqual(TVProvinces.province(for: "湖南卫视"), "湖南", "省名开头归类")
    expectEqual(TVProvinces.province(for: "东方卫视"), "上海", "卫视品牌别名归类")
    expectEqual(TVProvinces.province(for: "滁州新闻频道"), "安徽", "城市名归类")
    expectEqual(TVProvinces.province(for: "深圳都市频道"), "广东", "深圳归广东")
    expectEqual(TVProvinces.province(for: "苏州生活资讯"), "江苏", "苏州归江苏")
    expectEqual(TVProvinces.province(for: "延边卫视"), "吉林", "延边卫视归吉林")
    expectEqual(TVProvinces.section(for: "Some Unknown TV"), "其他", "未知频道归入其他")
    expect(TVProvinces.rank("北京") < TVProvinces.rank("广东"), "省份按行政区划排序")
    expect(TVProvinces.isSatellite("湖南卫视"), "卫视识别")

    // 命令策略：照片命令只属于图库 / 云盘
    let writablePolicy = CommandPolicy(context: CommandContext(kind: .library,
                                                               hasSelection: true,
                                                               hasCommandTargets: true,
                                                               isReadOnlyScope: false,
                                                               isTrash: false,
                                                               canFavorite: true))
    expect(writablePolicy.isEnabled(.deleteToTrash), "可写图库可移到最近删除")
    expect(writablePolicy.isEnabled(.exportSelection), "可写图库可导出所选")

    let trashPolicy = CommandPolicy(context: CommandContext(kind: .library,
                                                            hasSelection: true,
                                                            hasCommandTargets: true,
                                                            isReadOnlyScope: false,
                                                            isTrash: true,
                                                            canFavorite: false))
    expect(!trashPolicy.isEnabled(.deleteToTrash), "最近删除里不能再移到最近删除")
    expect(!trashPolicy.isEnabled(.favorite), "最近删除里不显示收藏")

    let televisionPolicy = CommandPolicy(context: CommandContext(kind: .iptv,
                                                                 hasSelection: true,
                                                                 hasCommandTargets: true,
                                                                 isReadOnlyScope: true,
                                                                 isTrash: false,
                                                                 canFavorite: false))
    expect(!televisionPolicy.isEnabled(.exportSelection), "电视频道不出现照片命令")
    expect(!televisionPolicy.isEnabled(.deletePermanently), "电视频道不能删除照片")

    let readOnlyPolicy = CommandPolicy(context: CommandContext(kind: .library,
                                                               hasSelection: true,
                                                               hasCommandTargets: true,
                                                               isReadOnlyScope: true,
                                                               isTrash: false,
                                                               canFavorite: true))
    expect(!readOnlyPolicy.isEnabled(.deletePermanently), "只读范围不能永久删除")
    expect(readOnlyPolicy.isEnabled(.copy), "只读范围仍可复制")

    // 卡片事实层：网盘 / 本地文件需要把卡片还原成源条目
    let assetCard = ContentCard(ref: ContentRef(sourceID: .cloud(UUID()), itemID: "/media/a.mkv"),
                                title: "a.mkv",
                                asset: ContentAssetFacts(updatedAt: Date(timeIntervalSince1970: 1_000),
                                                         byteCount: 42,
                                                         duration: 3,
                                                         pixelWidth: 1920,
                                                         pixelHeight: 1080,
                                                         remoteID: "fs-1",
                                                         videoCodec: "hevc"))
    let assetData = try? JSONEncoder().encode(assetCard)
    let assetDecoded = assetData.flatMap { try? JSONDecoder().decode(ContentCard.self, from: $0) }
    expectEqual(assetDecoded?.asset?.remoteID, Optional("fs-1"), "卡片事实层可编码还原")
    expectEqual(assetDecoded?.asset?.byteCount, Optional(42), "卡片事实层保留体积")
    expectEqual(assetDecoded?.asset?.videoCodec, Optional("hevc"), "卡片事实层保留编码")

    // 接入校验报告：警告不拦截、失败拦截，整体级别取最严重项
    var accessReport = ValidationReport()
    accessReport.append("配置可访问", level: .ok)
    expect(!accessReport.blocksImport, "只有通过项时不阻止接入")
    accessReport.append("封面加载失败", level: .warning)
    expect(!accessReport.blocksImport, "警告不阻止接入")
    expectEqual(accessReport.summary, Optional("封面加载失败"), "单行状态优先展示警告")
    accessReport.append("首页解析为空", level: .failed, detail: "HTTP 200")
    expect(accessReport.blocksImport, "失败项阻止接入")
    expectEqual(accessReport.overall, ValidationLevel.failed, "整体级别取最严重项")
    expectEqual(accessReport.issues.count, 2, "问题项包含警告与失败")
    expectEqual(ValidationReport().overall, ValidationLevel.ok, "空报告视为通过")

    // 接入渠道覆盖五个入口
    expectEqual(AccessChannel.allCases.count, 5, "接入渠道覆盖图库 / 云盘 / 影院 / 资源 / 电视")
    expectEqual(AccessChannel.cloud.title, "网络云盘", "接入渠道有可读名称")

    // 扫码策略保留各网盘原有节奏与容错
    expectEqual(QRLoginPolicy.quark.pollInterval, 1.6, "夸克保持 1.6 秒轮询")
    expectEqual(QRLoginPolicy.aliyun.pendingCredentialRetries, 6, "阿里云盘确认后允许重试 6 次")
    expectEqual(QRLoginPolicy.pan115.pollFailureTolerance, 3, "115 轮询允许连续 3 次失败")
    expectEqual(QRLoginPolicy.pan115.pollInterval, 1.8, "115 保持 1.8 秒轮询")



    let m3uDefaults = """
    #EXTM3U catchup-source="https://cdn.example/catchup/${start}/${end}" catchup-days="3"
    #EXTINF:-1 tvg-id="CCTV1.cn@SD" tvg-name="CCTV-1 综合" group-title="News",CCTV-1 (720p)
    #EXTGRP:央视
    #EXTVLCOPT:http-referrer=https://ref.example
    #EXTVLCOPT:http-user-agent=LumaTV
    http://example.com/cctv1_sd.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn@HD" catchup-source="https://own.example/${utc}",CCTV-1 (1080p)
    https://example.com/cctv1_hd.m3u8
    """
    let defaultsEntries = M3UPlaylist.parse(m3uDefaults)
    expectEqual(defaultsEntries.count, 2, "M3U 头部默认值不影响条目数")
    expectEqual(defaultsEntries[0].name, "CCTV-1", "展示名去掉画质标记")
    expectEqual(defaultsEntries[0].rawName, "CCTV-1 (720p)", "原文保留画质标记用于评分")
    expectEqual(defaultsEntries[0].groupTitle, "央视", "EXTGRP 覆盖 group-title")
    expectEqual(defaultsEntries[0].catchUpSource ?? "",
                "https://cdn.example/catchup/${start}/${end}", "头部 catchup-source 作为默认值")
    expectEqual(defaultsEntries[0].catchUpDays ?? 0, 3, "头部 catchup-days 作为默认值")
    expectEqual(defaultsEntries[0].headers,
                ["Referer": "https://ref.example", "User-Agent": "LumaTV"],
                "VLC 选项写入请求头")
    expectEqual(defaultsEntries[1].catchUpSource ?? "", "https://own.example/${utc}",
                "条目自己的 catchup-source 覆盖头部")
    expectEqual(defaultsEntries[1].catchUpDays ?? 0, 3, "未覆盖时仍继承头部回看天数")

    let m3uNames = """
    #EXTM3U
    #EXTINF:-1 tvg-id="X.cn" tvg-name="X 综合",
    http://example.com/x.m3u8
    #EXTINF:-1 tvg-id="Y.cn",
    http://example.com/y.m3u8
    """
    let nameEntries = M3UPlaylist.parse(m3uNames)
    expectEqual(nameEntries.first?.name, "X 综合", "没有展示名时回退 tvg-name")
    expectEqual(nameEntries.last?.name, "未命名频道", "都没有时给出兜底名称")

    let attrEntries = M3UPlaylist.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="A.cn" http-user-agent="AttrUA" http-referer="https://attr.example",A
    https://cdn.example/a.m3u8
    """)
    let attrHeaders = attrEntries.first?.headers ?? [:]
    expectEqual(attrHeaders["User-Agent"], Optional("AttrUA"), "EXTINF 属性 UA 生效")
    expectEqual(attrHeaders["Referer"], Optional("https://attr.example"), "EXTINF 属性 Referer 生效")

    let m3uMultiLine = """
    #EXTM3U
    #EXTINF:-1 tvg-id="CCTV1.cn@SD",CCTV-1 (720p)
    https://cdn.example/cctv1_720.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn@HD",CCTV-1 (1080p)
    https://cdn.example/cctv1_1080.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn@HD2",CCTV-1 (1080p) [Not 24/7]
    https://cdn.example/cctv1_1080_b.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn@LOW",CCTV-1 (576p)
    http://cdn.example/cctv1_576.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn@LOW2",CCTV-1 (480p)
    rtmp://cdn.example/cctv1_480
    """
    let lineCandidates = M3UPlaylist.bestChannels(from: M3UPlaylist.parse(m3uMultiLine))
    expectEqual(lineCandidates.count, 1, "同一 tvg-id 的不同画质合并为一个频道")
    if let best = lineCandidates.first {
        expectEqual(best.key, "cctv1.cn", "去重键去掉 @画质 后缀")
        expectEqual(best.entry.url, "https://cdn.example/cctv1_1080.m3u8",
                    "优先 HTTPS + HLS + 高画质且无状态惩罚")
        expectEqual(best.quality, 1080, "画质取原始展示名")
        expectEqual(best.qualityLabel, Optional("1080p"), "画质标签")
        expectEqual(best.lineCount, 4, "线路数包含主线与三条备用")
        expectEqual(best.alternateEntries.map(\.url),
                    ["https://cdn.example/cctv1_1080_b.m3u8",
                     "https://cdn.example/cctv1_720.m3u8",
                     "http://cdn.example/cctv1_576.m3u8"],
                    "备用线路按评分排序，非 HTTP 协议丢弃，最多三条")
    }

    let noIDEntries = M3UPlaylist.parse("""
    #EXTM3U
    #EXTINF:-1,CCTV-1 (720p)
    https://a.example/x.m3u8
    #EXTINF:-1,CCTV-1 (1080p)
    https://b.example/y.m3u8
    """)
    let noIDCandidates = M3UPlaylist.bestChannels(from: noIDEntries)
    expectEqual(noIDCandidates.count, 1, "没有 tvg-id 时按规范化频道名去重")
    expectEqual(noIDCandidates.first?.entry.url, "https://b.example/y.m3u8",
                "同名线路选画质更高的")

    let uhdCandidate = M3UPlaylist.bestChannels(from: M3UPlaylist.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="UHD.cn",UHD 频道 (4K)
    https://cdn.example/uhd.m3u8
    """)).first
    expectEqual(uhdCandidate?.quality ?? 0, 2160, "4K 归一到 2160p 评分")
    expectEqual(uhdCandidate?.qualityLabel, Optional("2160p"), "4K 展示为 2160p")
    expectEqual(uhdCandidate?.entry.name, "UHD 频道", "cleanName 去掉 (4K)")

    expectEqual(M3UPlaylist.cleanName("CCTV-1 (1080p)"), "CCTV-1", "去掉画质后缀")
    expectEqual(M3UPlaylist.cleanName("CCTV-1 [Geo-blocked]"), "CCTV-1", "去掉地区限制标记")
    expectEqual(M3UPlaylist.cleanName("湖南卫视 [Not 24/7] (720p)"), "湖南卫视",
                "同时去掉状态与画质标记")
    expectEqual(M3UPlaylist.cleanName("Channel (4K)"), "Channel", "去掉 4K 标记")
    expectEqual(M3UPlaylist.cleanName("Channel (HD)"), "Channel", "去掉 HD 标记")
    expectEqual(M3UPlaylist.cleanName("Channel (SD)"), "Channel", "去掉 SD 标记")
    expectEqual(M3UPlaylist.cleanName("Some (576i)"), "Some", "去掉隔行画质标记")
    expectEqual(M3UPlaylist.cleanName("CCTV-5+"), "CCTV-5+", "正常频道名不变")

}
