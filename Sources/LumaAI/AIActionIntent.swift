import Foundation

/// 「这句话是不是要动手」的判定，从 LibraryStore 抽出来，便于离线验收假完成率。
/// 规则刻意偏保守：疑问句一律视为「不是操作」，避免把「如何建相簿」当成建相簿。
package enum AIActionIntent {
    package static let falseTriggers = ["怎么", "如何", "为什么", "什么"]

    /// 否定的祈使句不当成操作：「不要删除」「别再隐藏」。
    /// 刻意用多字词，避免「特别 / 区别」这类词被误判。
    package static let negations = ["不要", "不用", "无需", "不想", "不准", "别再", "别把"]

    /// 「评 5 星」「打 4 星」这类带数字的祈使句，靠关键词拆不出来。
    package static let actionPatterns = ["[评打分]\\s*\\d+\\s*星", "\\d+\\s*星"]

    package static let keywords = [
        "创建", "新建", "加入", "放到", "放进", "归入", "移出", "移除",
        "收藏", "取消收藏", "添加关键词", "去掉关键词", "删除关键词", "打标签",
        "整理成", "重命名", "改名", "移动", "隐藏", "取消隐藏", "恢复",
        "设为封面", "封面", "改标题", "设置标题", "移入最近删除", "压缩", "美化",
        "选中", "打开", "切换到", "筛选", "排序", "直接操作", "执行",
        "匹配", "刮削", "重新识别", "识别一下",
        "改成", "加上", "更新"
    ]

    package static func hasIntent(_ text: String) -> Bool {
        if falseTriggers.contains(where: { text.contains($0) }) { return false }
        if negations.contains(where: { text.contains($0) }) { return false }
        for pattern in actionPatterns
        where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return keywords.contains { text.contains($0) }
    }
}
