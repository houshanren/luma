import Foundation

/// 标签墙里的一个语义分组：标题 + 图标 + 落在这一组的标签。
struct CatalogTagBucket: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let tags: [CatalogTag]
}

/// 把站点那堵扁平的标签墙归类：
/// 先看关键词（身材 / 衣着 / 场景 / 玩法 / 属性 / 内容 / 作品 / 风格），
/// 再认星图里的女优与厂牌，纯四位数字归年份，剩下的留在「其他」。
///
/// 关键词优先于星图：像「cosplay」「旗袍」这类词有时正好是某个机构的别名，
/// 先按语义归类比按别名认成品牌更符合直觉；站点本身不提供分类，这里全部本地算。
enum CatalogTagClassifier {
    private struct Rule {
        let id: String
        let words: [String]
    }

    /// 关键词按顺序匹配：先命中先归类。
    private static let rules: [Rule] = [
        Rule(id: "body", words: [
            "巨乳", "美胸", "大胸", "爆乳", "贫乳", "微乳", "美乳", "美腿", "长腿", "大长腿",
            "美臀", "蜜臀", "翘臀", "肥臀", "丰臀", "巨臀", "细腰", "小蛮腰", "马甲线", "锁骨",
            "香肩", "玉足", "美脚", "美背", "高挑", "丰满", "苗条", "白皙", "白嫩", "雪白",
            "小麦色", "骨感", "微胖", "曲线", "紧身", "身材", "细腿", "天鹅颈", "长身"
        ]),
        Rule(id: "outfit", words: [
            "丝袜", "黑丝", "白丝", "肉丝", "网袜", "吊带袜", "旗袍", "校服", "jk", "水手服",
            "制服", "女仆", "女佣", "吊带", "内衣", "睡衣", "泳装", "泳衣", "比基尼", "婚纱",
            "高跟鞋", "高跟", "眼镜", "双马尾", "洛丽塔", "萝莉塔", "古装", "汉服", "和服",
            "毛衣", "衬衫", "牛仔", "紧身裤", "短裙", "长裙", "连衣裙", "热裤", "西装", "领带",
            "蕾丝", "头饰", "项圈", "帽子", "丁字裤", "兔女郎", "睡衣", "护士服", "空姐服"
        ]),
        Rule(id: "scene", words: [
            "室内", "户外", "浴室", "海边", "沙滩", "酒店", "办公室", "街拍", "街头", "车内",
            "车模", "沙发", "泳池", "公园", "超市", "教室", "图书馆", "阳台", "楼道", "天台",
            "厨房", "卧室", "健身房", "酒吧", "夜店", "旅拍", "露营", "雪地", "雨天", "风景",
            "床", "居家", "私房", "户外写真"
        ]),
        Rule(id: "play", words: [
            "露出", "透视", "情趣", "大尺度", "全裸", "诱惑", "性感", "cosplay", "角色扮演",
            "角色还原", "捆绑", "口交", "乳交", "足交", "多p", "百合", "自慰", "湿身",
            "无套", "内射", "颜射", "调教", "偷拍", "约会", "水着", "露点", "真空", "露穴",
            "美穴", "足控", "恋足", "潮吹", "喷水", "舔", "白虎"
        ]),
        Rule(id: "role", words: [
            "少女", "熟女", "人妻", "御姐", "萝莉", "学生", "学妹", "学姐", "空姐", "护士",
            "秘书", "白领", "女警", "模特", "网红", "女神", "辣妹", "姐姐", "女友",
            "初恋", "纯欲", "清纯", "可爱", "气质", "优雅", "高冷", "知性", "温柔", "萌妹",
            "混血", "少妇", "轻熟", "甜妹", "邻家", "辣妈", "妹子", "女郎", "嫩模", "极品",
            "风骚", "萌", "甜"
        ]),
        Rule(id: "content", words: [
            "剧情", "视频", "套图", "图集", "福利", "合集", "热门", "系列", "短片", "长片",
            "写真", "花絮", "专题", "排行"
        ]),
        Rule(id: "work", words: [
            "碧蓝航线", "原神", "明日方舟", "崩坏", "王者荣耀", "英雄联盟", "二次元", "动漫",
            "动画", "漫画", "游戏", "coser", "东方project"
        ]),
        Rule(id: "style", words: [
            "古风", "国风", "港风", "复古", "胶片", "清新", "日系", "韩系", "欧美", "圣诞",
            "万圣", "新年", "夏日", "冬季", "森系", "甜酷", "暗黑", "黑白"
        ])
    ]

    /// 太短、靠包含判断容易误伤的词，只在标签本身就是它时命中。
    private static let exactTokens: [String: String] = [
        "ol": "role", "sm": "play", "jk": "outfit", "3d": "style"
    ]

    private static let order = ["people", "brand", "body", "outfit", "scene", "play",
                                "role", "content", "work", "style", "year", "other"]

    private static let titles: [String: (String, String)] = [
        "people": ("人物", "person.2.fill"),
        "brand": ("品牌", "building.2.fill"),
        "body": ("身材", "figure.arms.open"),
        "outfit": ("衣着", "tshirt.fill"),
        "scene": ("场景", "camera.fill"),
        "play": ("玩法", "flame.fill"),
        "role": ("属性", "theatermasks.fill"),
        "content": ("内容", "play.rectangle.fill"),
        "work": ("作品", "sparkles.rectangle.stack.fill"),
        "style": ("风格", "paintpalette.fill"),
        "year": ("年份", "calendar"),
        "other": ("其他", "square.grid.2x2.fill")
    ]

    /// 归类要在主线程做：星图名册的加载状态是主线程隔离的；
    /// 五百多个标签只做字符串包含判断，一次算完不到一毫秒。
    @MainActor
    static func classify(_ tags: [CatalogTag]) -> [CatalogTagBucket] {
        var grouped: [String: [CatalogTag]] = [:]
        for tag in tags {
            grouped[bucketID(for: tag.title), default: []].append(tag)
        }
        return order.compactMap { id in
            guard let list = grouped[id], !list.isEmpty else { return nil }
            let title = titles[id]?.0 ?? id
            let symbol = titles[id]?.1 ?? "tag"
            return CatalogTagBucket(id: id, title: title, symbol: symbol, tags: list)
        }
    }

    /// 单个标签归到哪一组；同名标签重复归类不会产生副作用。
    @MainActor
    static func bucketID(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 4, trimmed.allSatisfy(\.isNumber),
           let year = Int(trimmed), (1900...2099).contains(year) {
            return "year"
        }
        let lower = trimmed.lowercased()
        // 两个字母的缩写只认独立标签（OL / SM / JK），否则会误伤 Olivia 这类名字。
        if let exact = exactTokens[lower] { return exact }
        for rule in rules where rule.words.contains(where: { lower.contains($0) }) {
            return rule.id
        }
        if AtlasCatalogLibrary.shared.isLoaded {
            if CatalogNameDictionary.exactActress(matching: trimmed) != nil { return "people" }
            if CatalogNameDictionary.exactStudio(matching: trimmed) != nil { return "brand" }
        }
        return "other"
    }
}
