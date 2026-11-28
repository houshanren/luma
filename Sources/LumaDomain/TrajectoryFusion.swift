import Foundation

/// 轨迹融合：把视觉标签、拍摄时间、地点与同框人物压成「活动」与「日子」两级。
/// 纯函数、不落库；地点来自照片自带的 POI / 城市字段，人物来自已命名的人脸聚类。
///
/// 设计边界：
/// - 只映射有明确生活含义的标签，风景 / 物体 / 风格不单独成事件；
/// - 一张照片只归入一个主活动，避免「海边 + 沙滩 + 戏水」重复计数；
/// - 没有视觉活动证据的日子不输出，宁可少说，不猜。
package enum TrajectoryFusion {
    package struct Companion: Identifiable, Equatable {
        package let name: String
        package let count: Int
        package var id: String { name }

        package init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    /// 一个活动在一批照片里的聚合。
    package struct Activity: Identifiable, Equatable {
        package let title: String
        package let count: Int
        /// 命中的标准标签，用于解释「为什么是它」。
        package let tags: [String]
        /// 这个活动里最常同框的已命名人物。
        package let companions: [Companion]
        package var id: String { title }

        package init(title: String,
                     count: Int,
                     tags: [String],
                     companions: [Companion]) {
            self.title = title
            self.count = count
            self.tags = tags
            self.companions = companions
        }
    }

    /// 同一天、同一地点里的一段活动，作为时间线上的最小事件。
    package struct Day: Identifiable, Equatable {
        package let date: Date
        package let place: String
        package let activity: String
        package let photoCount: Int
        package let companions: [String]
        package let coverPhotoID: UUID?
        package var id: String {
            "\(date.timeIntervalSince1970)-\(place)-\(activity)"
        }

        package init(date: Date,
                     place: String,
                     activity: String,
                     photoCount: Int,
                     companions: [String],
                     coverPhotoID: UUID?) {
            self.date = date
            self.place = place
            self.activity = activity
            self.photoCount = photoCount
            self.companions = companions
            self.coverPhotoID = coverPhotoID
        }
    }

    /// 标签 → 活动。顺序即优先级：越具体的事件越靠前，宽泛的「美食 / 运动」靠后。
    package static let activityRules: [(activity: String, tags: [String])] = [
        ("生日庆祝", ["生日"]),
        ("纪念日", ["纪念日"]),
        ("婚礼", ["婚礼现场", "婚纱"]),
        ("毕业典礼", ["毕业典礼"]),
        ("现场音乐", ["音乐节", "演唱会现场"]),
        ("看展", ["展览", "博物馆"]),
        ("烟花", ["烟花"]),
        ("庙会", ["庙会", "市集"]),
        ("团建", ["团建"]),
        ("亲子时光", ["亲子互动", "抱孩子", "家庭日常", "儿童", "婴儿", "全家福", "牵手"]),
        ("宠物陪伴", ["宠物互动", "遛狗"]),
        ("海边戏水", ["戏水", "冲浪", "潜水", "水上乐园", "泳池", "游泳", "沙滩", "海边"]),
        ("滑雪", ["滑雪"]),
        ("露营野餐", ["露营", "野餐"]),
        ("登山徒步", ["登山"]),
        ("古迹游览", ["古迹", "遗址", "城墙", "宫殿", "园林", "寺庙", "教堂", "城堡", "古镇"]),
        ("高铁出行", ["高铁"]),
        ("自驾出行", ["自驾", "公路", "加油站", "停车场"]),
        ("购物", ["购物", "商场", "超市"]),
        ("美食", ["火锅", "烧烤", "披萨", "寿司", "面条", "海鲜", "甜点", "美食", "中餐",
                  "地方菜", "夜宵", "奶茶", "早餐", "蛋糕"]),
        ("咖啡时光", ["咖啡", "咖啡馆"]),
        ("校园", ["学校", "教室"]),
        ("就医", ["医院"]),
        ("逛夜市", ["夜市"]),
        ("住民宿", ["民宿", "酒店"]),
        ("健身", ["健身房"]),
        ("运动", ["运动", "跑步", "骑行"]),
        ("旅行", ["旅游"]),
    ]

    /// 单张照片的主活动：按规则顺序取第一个命中的标签组。
    package static func activity(for labels: Set<String>) -> (title: String, tags: [String])? {
        guard !labels.isEmpty else { return nil }
        for rule in activityRules {
            let hits = rule.tags.filter { labels.contains($0) }
            if !hits.isEmpty { return (rule.activity, hits) }
        }
        return nil
    }

    /// 一批照片的活动分布。`peopleByPhoto` 用于把已命名人物挂到活动上。
    package static func activities(labelsByPhoto: [UUID: Set<String>],
                                   peopleByPhoto: [UUID: [String]] = [:],
                                   limit: Int = 6) -> [Activity] {
        var counts: [String: Int] = [:]
        var tagsByTitle: [String: Set<String>] = [:]
        var peopleByTitle: [String: [String: Int]] = [:]
        var order: [String: Int] = [:]

        for (photoID, labels) in labelsByPhoto {
            guard let hit = activity(for: labels) else { continue }
            counts[hit.title, default: 0] += 1
            tagsByTitle[hit.title, default: []].formUnion(hit.tags)
            if order[hit.title] == nil {
                order[hit.title] = activityRules.firstIndex { $0.activity == hit.title } ?? 999
            }
            for name in Set(peopleByPhoto[photoID] ?? []) where !name.isEmpty {
                peopleByTitle[hit.title, default: [:]][name, default: 0] += 1
            }
        }

        var results: [Activity] = []
        results.reserveCapacity(counts.count)
        for (title, count) in counts {
            let people = peopleByTitle[title] ?? [:]
            var companions = people.map { Companion(name: $0.key, count: $0.value) }
            companions.sort {
                $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
            }
            let tags = Array((tagsByTitle[title] ?? []).sorted())
            results.append(Activity(title: title,
                                    count: count,
                                    tags: tags,
                                    companions: Array(companions.prefix(2))))
        }
        results.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return (order[$0.title] ?? 999) < (order[$1.title] ?? 999)
        }
        return Array(results.prefix(limit))
    }

    /// 按「天 + 地点」聚成轨迹片段；没有视觉活动证据的分组会被丢弃。
    package static func days(photos: [PhotoItem],
                             labelsByPhoto: [UUID: Set<String>],
                             peopleByPhoto: [UUID: [String]] = [:],
                             calendar: Calendar = .current,
                             limit: Int = 8) -> [Day] {
        let visible = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        guard !visible.isEmpty else { return [] }

        struct Bucket {
            var photos: [PhotoItem] = []
            var activityCounts: [String: Int] = [:]
            var activityOrder: [String: Int] = [:]
            var peopleCounts: [String: Int] = [:]
        }

        var buckets: [String: Bucket] = [:]
        for photo in visible {
            let labels = labelsByPhoto[photo.id] ?? []
            guard let hit = activity(for: labels) else { continue }
            let day = calendar.startOfDay(for: photo.capturedAt)
            let place = Self.placeName(for: photo)
            let key = "\(day.timeIntervalSince1970)|\(place)"
            var bucket = buckets[key] ?? Bucket()
            bucket.photos.append(photo)
            bucket.activityCounts[hit.title, default: 0] += 1
            if bucket.activityOrder[hit.title] == nil {
                bucket.activityOrder[hit.title] = activityRules.firstIndex { $0.activity == hit.title } ?? 999
            }
            for name in Set(peopleByPhoto[photo.id] ?? []) where !name.isEmpty {
                bucket.peopleCounts[name, default: 0] += 1
            }
            buckets[key] = bucket
        }

        return buckets.values
            .compactMap { bucket -> Day? in
                guard let photo = bucket.photos.first,
                      let top = bucket.activityCounts.max(by: {
                          $0.value == $1.value
                              ? (bucket.activityOrder[$0.key] ?? 999) > (bucket.activityOrder[$1.key] ?? 999)
                              : $0.value < $1.value
                      }) else { return nil }
                let activity = top.key
                let cover = bucket.photos.max { lhs, rhs in
                    coverScore(lhs) < coverScore(rhs)
                }
                let companions = bucket.peopleCounts
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .prefix(2)
                    .map(\.key)
                return Day(date: calendar.startOfDay(for: photo.capturedAt),
                           place: Self.placeName(for: photo),
                           activity: activity,
                           photoCount: bucket.photos.count,
                           companions: Array(companions),
                           coverPhotoID: cover?.id)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// 地点名优先级：POI → 城市 → 区县 → 省份；都没有时返回空串。
    package static func placeName(for photo: PhotoItem) -> String {
        for value in [photo.placePOI, photo.placeCity, photo.placeDistrict, photo.placeProvince] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func coverScore(_ photo: PhotoItem) -> Double {
        var score = Double(photo.pixelWidth * photo.pixelHeight) / 1_000_000
        if photo.isFavorite { score += 20 }
        return score
    }
}
