import Foundation
import Vision

/// 把系统 Vision 分类器（英文、粒度较粗）映射到拾光的中文标签。
///
/// 为什么需要它：真实图库 1,200 张审计里，SigLIP2-B 对场景 / 文档 / 服饰明显欠触发
/// （天空 7 vs Apple 220、文档 59 vs 408、衣服 6 vs 313）。Apple 分类器本机运行、
/// 无需下载，p50 约 17 ms，适合作为第二信号补齐这些概念。
///
/// 边界：Apple 分类器不是金标，只做补充，不覆盖 SigLIP 已给出的标签；
/// 置信度门槛按概念宽窄单独设置，宁可少补，不把「clothing」这类泛标签铺满全库。
/// 调用方（PhotoIntelligence）现在只在 SigLIP 标签 < 2 时才启用它：全量合入会明显拉低精度。
enum AppleVisionTagMapper {
    private struct Rule {
        let title: String
        let minimumConfidence: Float
    }

    /// key 是 `VNClassificationObservation.identifier` 的小写形式。
    private static let rules: [String: Rule] = [
        // 人物 / 关系
        "people": Rule(title: "人物", minimumConfidence: 0.30),
        "adult": Rule(title: "人物", minimumConfidence: 0.30),
        "crowd": Rule(title: "人物", minimumConfidence: 0.35),
        "child": Rule(title: "儿童", minimumConfidence: 0.30),
        "teen": Rule(title: "儿童", minimumConfidence: 0.35),
        "baby": Rule(title: "婴儿", minimumConfidence: 0.30),

        // 文档 / 截图：SigLIP 欠触发最严重的两类
        "screenshot": Rule(title: "截图", minimumConfidence: 0.35),
        "document": Rule(title: "文档", minimumConfidence: 0.35),
        "printed_page": Rule(title: "文档", minimumConfidence: 0.40),
        "handwriting": Rule(title: "文档", minimumConfidence: 0.40),
        "receipt": Rule(title: "文档", minimumConfidence: 0.40),
        "sign": Rule(title: "文档", minimumConfidence: 0.50),

        // 场景
        "sky": Rule(title: "天空", minimumConfidence: 0.30),
        "blue_sky": Rule(title: "天空", minimumConfidence: 0.30),
        "cloudy": Rule(title: "云朵", minimumConfidence: 0.40),
        "ocean": Rule(title: "海边", minimumConfidence: 0.40),
        "beach": Rule(title: "海边", minimumConfidence: 0.40),
        "seashore": Rule(title: "海边", minimumConfidence: 0.40),
        "lake": Rule(title: "湖泊", minimumConfidence: 0.45),
        "hill": Rule(title: "山脉", minimumConfidence: 0.45),
        "mountain": Rule(title: "山脉", minimumConfidence: 0.40),
        "forest": Rule(title: "森林", minimumConfidence: 0.35),
        "foliage": Rule(title: "树", minimumConfidence: 0.35),
        "tree": Rule(title: "树", minimumConfidence: 0.40),
        "branch": Rule(title: "树", minimumConfidence: 0.45),
        "grass": Rule(title: "草地", minimumConfidence: 0.40),
        "flower": Rule(title: "花", minimumConfidence: 0.40),
        "blossom": Rule(title: "花", minimumConfidence: 0.40),
        "waterfall": Rule(title: "瀑布", minimumConfidence: 0.50),
        "desert": Rule(title: "沙漠", minimumConfidence: 0.50),
        "library": Rule(title: "图书馆", minimumConfidence: 0.40),

        // 食物 / 物体 / 交通
        "food": Rule(title: "美食", minimumConfidence: 0.45),
        "plate": Rule(title: "美食", minimumConfidence: 0.55),
        "bowl": Rule(title: "美食", minimumConfidence: 0.55),
        "restaurant": Rule(title: "美食", minimumConfidence: 0.50),
        "automobile": Rule(title: "汽车", minimumConfidence: 0.35),
        "car": Rule(title: "汽车", minimumConfidence: 0.35),
        "vehicle": Rule(title: "汽车", minimumConfidence: 0.45),
        "conveyance": Rule(title: "汽车", minimumConfidence: 0.50),
        "bicycle": Rule(title: "自行车", minimumConfidence: 0.40),
        "building": Rule(title: "建筑", minimumConfidence: 0.40),
        "skyscraper": Rule(title: "建筑", minimumConfidence: 0.40),
        "street": Rule(title: "街道", minimumConfidence: 0.40),
        "road": Rule(title: "街道", minimumConfidence: 0.45),
        "cityscape": Rule(title: "城市", minimumConfidence: 0.40),
        "night_sky": Rule(title: "夜景", minimumConfidence: 0.35),
        "sunset_sunrise": Rule(title: "日落", minimumConfidence: 0.35),
        "snow": Rule(title: "雪景", minimumConfidence: 0.40),
        "frozen": Rule(title: "雪景", minimumConfidence: 0.45),

        // 事件
        "wedding": Rule(title: "婚礼现场", minimumConfidence: 0.40),
        "ceremony": Rule(title: "婚礼现场", minimumConfidence: 0.45),
        "bride": Rule(title: "婚纱", minimumConfidence: 0.40),
        "gown": Rule(title: "婚纱", minimumConfidence: 0.45),
        "wedding_dress": Rule(title: "婚纱", minimumConfidence: 0.40),
        "bouquet": Rule(title: "花束", minimumConfidence: 0.40),
        "concert": Rule(title: "演唱会现场", minimumConfidence: 0.40),
        "performance": Rule(title: "演唱会现场", minimumConfidence: 0.45),

        // 服饰 / 随身物：只用具体词，不用泛化的 clothing
        "handbag": Rule(title: "包包", minimumConfidence: 0.35),
        "purse": Rule(title: "包包", minimumConfidence: 0.35),
        "luggage": Rule(title: "包包", minimumConfidence: 0.45),
        "backpack": Rule(title: "包包", minimumConfidence: 0.45),
        "shoes": Rule(title: "鞋子", minimumConfidence: 0.40),
        "sneaker": Rule(title: "鞋子", minimumConfidence: 0.40),
        "footwear": Rule(title: "鞋子", minimumConfidence: 0.45),
        "jacket": Rule(title: "衣服", minimumConfidence: 0.40),
        "hoodie": Rule(title: "衣服", minimumConfidence: 0.40),
        "suit": Rule(title: "衣服", minimumConfidence: 0.45),
        "jewelry": Rule(title: "珠宝", minimumConfidence: 0.40),
        "balloon": Rule(title: "气球", minimumConfidence: 0.40),
        "flag": Rule(title: "旗帜", minimumConfidence: 0.40),
        "bottle": Rule(title: "瓶子", minimumConfidence: 0.40),
        "drinking_glass": Rule(title: "杯子", minimumConfidence: 0.40),
        "book": Rule(title: "书本", minimumConfidence: 0.40),
        "computer": Rule(title: "电脑", minimumConfidence: 0.40),
        "computer_monitor": Rule(title: "电脑", minimumConfidence: 0.40),
        "toy": Rule(title: "玩具", minimumConfidence: 0.40),

        // 动物
        "cat": Rule(title: "猫", minimumConfidence: 0.40),
        "adult_cat": Rule(title: "猫", minimumConfidence: 0.40),
        "feline": Rule(title: "猫", minimumConfidence: 0.45),
        "dog": Rule(title: "狗", minimumConfidence: 0.40)
    ]

    /// 从一次 `VNClassifyImageRequest` 的结果里取出可补充的中文标签。
    /// 同一个中文标签只出现一次，顺序按 Apple 置信度从高到低。
    static func titles(from observations: [VNClassificationObservation]) -> [String] {
        var result: [String] = []
        for observation in observations {
            let key = observation.identifier.lowercased()
            guard let rule = rules[key],
                  observation.confidence >= rule.minimumConfidence,
                  !result.contains(rule.title) else { continue }
            result.append(rule.title)
        }
        return result
    }
}
