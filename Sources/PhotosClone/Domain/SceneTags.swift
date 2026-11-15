import Foundation

/// 场景分类：由 Vision 图像分类标签聚合而来，用于侧边栏「场景」与语义搜索。
struct SceneCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    /// 命中任意一个标签即归入该场景（Vision 标签均为小写英文）。
    let labels: Set<String>
}

/// 端侧智能分析结果（场景标签 + OCR 文本），只保存在当前图库。
struct PhotoAnalysis: Hashable {
    let labels: Set<String>
    let text: String
    /// 预先拼好的小写检索串（标签 + 文字），搜索时直接 contains。
    let searchBlob: String
}

/// 「查找相似照片」的临时范围。
struct SimilarityScope: Equatable {
    let sourceID: UUID
    let title: String
    let ids: Set<UUID>
}

/// 场景目录与中英检索词表。
enum SceneCatalog {
    static let categories: [SceneCategory] = [
        SceneCategory(id: "people", title: "人物", icon: "person.crop.square", labels: [
            "person", "people", "human", "portrait", "selfie", "face", "crowd", "baby", "child"
        ]),
        SceneCategory(id: "animals", title: "动物", icon: "pawprint", labels: [
            "animal", "dog", "puppy", "cat", "kitten", "bird", "fish", "horse", "cattle",
            "pet", "wildlife", "mammal", "insect", "reptile", "zoo"
        ]),
        SceneCategory(id: "nature", title: "自然风景", icon: "leaf", labels: [
            "nature", "outdoor", "landscape", "scenery", "mountain", "hill", "tree", "forest",
            "plant", "grass", "flower", "sky", "cloud", "sunset", "sunrise", "beach", "seashore",
            "coast", "ocean", "sea", "water", "lake", "river", "waterfall", "snow", "desert",
            "garden", "park"
        ]),
        SceneCategory(id: "food", title: "食物", icon: "fork.knife", labels: [
            "food", "meal", "dish", "cuisine", "dessert", "cake", "bread", "fruit",
            "vegetable", "drink", "beverage", "coffee", "tea", "wine"
        ]),
        SceneCategory(id: "architecture", title: "建筑", icon: "building.2", labels: [
            "building", "architecture", "house", "bridge", "tower", "skyscraper", "church",
            "temple", "castle", "city", "urban", "street"
        ]),
        SceneCategory(id: "transport", title: "交通", icon: "car.fill", labels: [
            "vehicle", "car", "automobile", "bicycle", "bike", "motorcycle", "train",
            "airplane", "aircraft", "boat", "ship", "truck", "bus", "road", "traffic"
        ]),
        SceneCategory(id: "indoor", title: "室内", icon: "sofa", labels: [
            "indoor", "room", "interior", "furniture", "table", "chair", "sofa", "bedroom",
            "bathroom", "kitchen", "office", "classroom", "store", "shop"
        ]),
        SceneCategory(id: "documents", title: "文档", icon: "doc.text", labels: [
            "document", "text", "paper", "book", "receipt", "whiteboard", "chart",
            "screenshot", "poster", "sign", "menu"
        ]),
        SceneCategory(id: "night", title: "夜景", icon: "moon.stars", labels: [
            "night", "dark", "lights", "fireworks", "illumination", "dusk"
        ]),
        SceneCategory(id: "activities", title: "活动", icon: "figure.run", labels: [
            "sport", "sports", "concert", "party", "celebration", "festival", "game",
            "performance", "dance", "wedding", "parade", "ceremony"
        ])
    ]

    static func category(id: String) -> SceneCategory? {
        categories.first { $0.id == id }
    }

    /// 中文（及常见英文）查询词 → Vision 可能返回的英文标签。
    static func searchLabels(for token: String) -> [String] {
        if let mapped = aliases[token] { return mapped }
        // 英文查询直接用小写词本身。
        if token.unicodeScalars.allSatisfy({ $0.isASCII }) { return [] }
        return []
    }

    private static let aliases: [String: [String]] = [
        "人": ["person", "people", "human"],
        "人物": ["person", "people", "human"],
        "人像": ["person", "portrait", "face"],
        "自拍": ["selfie", "face", "portrait"],
        "人群": ["crowd", "people"],
        "小孩": ["child", "baby"],
        "宝宝": ["baby", "child"],
        "狗": ["dog", "puppy", "pet"],
        "小狗": ["dog", "puppy"],
        "宠物": ["pet", "dog", "cat"],
        "猫": ["cat", "kitten"],
        "小猫": ["cat", "kitten"],
        "鸟": ["bird"],
        "鱼": ["fish"],
        "动物": ["animal", "wildlife", "mammal"],
        "海边": ["beach", "seashore", "coast", "ocean", "sea", "shore"],
        "海滩": ["beach", "seashore", "coast"],
        "沙滩": ["beach", "seashore"],
        "海": ["ocean", "sea", "beach"],
        "山": ["mountain", "hill"],
        "爬山": ["mountain", "hill"],
        "登山": ["mountain", "hill"],
        "森林": ["forest", "tree"],
        "树林": ["forest", "tree"],
        "树": ["tree"],
        "花": ["flower", "blossom", "petal"],
        "花朵": ["flower", "blossom"],
        "鲜花": ["flower", "blossom"],
        "植物": ["plant", "tree", "flower"],
        "天空": ["sky", "cloud"],
        "云": ["cloud", "sky"],
        "日落": ["sunset", "dusk"],
        "夕阳": ["sunset", "dusk"],
        "日出": ["sunrise"],
        "雪": ["snow"],
        "下雪": ["snow"],
        "湖": ["lake"],
        "河": ["river", "stream"],
        "溪": ["river", "stream"],
        "瀑布": ["waterfall"],
        "自然": ["nature", "outdoor", "landscape"],
        "风景": ["landscape", "scenery", "nature"],
        "户外": ["outdoor", "nature"],
        "公园": ["park", "garden"],
        "花园": ["garden"],
        "食物": ["food", "meal", "dish"],
        "美食": ["food", "meal", "dish", "cuisine"],
        "吃的": ["food", "meal"],
        "菜": ["food", "dish"],
        "甜点": ["dessert", "cake"],
        "蛋糕": ["cake", "dessert"],
        "面包": ["bread"],
        "水果": ["fruit"],
        "蔬菜": ["vegetable"],
        "咖啡": ["coffee"],
        "饮料": ["drink", "beverage"],
        "喝的": ["drink", "beverage"],
        "建筑": ["building", "architecture"],
        "房子": ["house", "building"],
        "房屋": ["house", "building"],
        "桥": ["bridge"],
        "城市": ["city", "urban"],
        "街道": ["street", "urban"],
        "室内": ["indoor", "room", "interior"],
        "房间": ["room", "indoor"],
        "家具": ["furniture"],
        "桌子": ["table", "furniture"],
        "椅子": ["chair", "furniture"],
        "沙发": ["sofa", "furniture"],
        "厨房": ["kitchen", "indoor"],
        "办公室": ["office", "indoor"],
        "文档": ["document", "paper", "text"],
        "文件": ["document", "paper"],
        "纸": ["paper", "document"],
        "书": ["book"],
        "书本": ["book"],
        "收据": ["receipt"],
        "发票": ["receipt"],
        "白板": ["whiteboard"],
        "屏幕": ["screenshot"],
        "截图": ["screenshot"],
        "夜景": ["night", "lights", "dark"],
        "夜晚": ["night", "dark"],
        "晚上": ["night", "dark"],
        "烟花": ["fireworks"],
        "车": ["car", "automobile", "vehicle"],
        "汽车": ["car", "automobile"],
        "自行车": ["bicycle", "bike"],
        "摩托车": ["motorcycle"],
        "火车": ["train"],
        "飞机": ["airplane", "aircraft"],
        "船": ["boat", "ship"],
        "运动": ["sport", "sports"],
        "演唱会": ["concert", "performance"],
        "聚会": ["party", "celebration"],
        "派对": ["party", "celebration"],
        "婚礼": ["wedding", "ceremony"],
        "节日": ["festival", "celebration"]
    ]
}
