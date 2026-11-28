import SwiftUI

/// 统一的无限滚动度量：内容在滚动容器里的偏移 + 内容高度。
struct ScrollPagingMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

struct ScrollPagingMetricsKey: PreferenceKey {
    static var defaultValue = ScrollPagingMetrics()

    static func reduce(value: inout ScrollPagingMetrics,
                       nextValue: () -> ScrollPagingMetrics) {
        let next = nextValue()
        if next.contentHeight > 0 { value = next }
    }
}

extension View {
    /// 上报滚动位置：挂在 ScrollView 的内容上，配合 `.infiniteScrollPaging` 使用。
    func reportScrollPagingMetrics(space: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ScrollPagingMetricsKey.self,
                    value: ScrollPagingMetrics(
                        offset: proxy.frame(in: .named(space)).minY,
                        contentHeight: proxy.size.height))
            }
        }
    }

    /// 自适应续页：离底部不足一屏时预取下一页。
    ///
    /// 判定用「离底部还剩多少」而不是「滚了百分之几」：内容变长后剩余距离同步变大，
    /// 一次加载最多只触发一次，不会出现自己一页接一页翻到底的情况。
    /// `resetKey` 变化（换源 / 换分类）时清空连续补页计数。
    func infiniteScrollPaging(space: String,
                              resetKey: String,
                              isEnabled: Bool,
                              isLoading: Bool,
                              isLoadingMore: Bool,
                              onLoadMore: @escaping () -> Void) -> some View {
        modifier(InfiniteScrollPagingModifier(space: space,
                                              resetKey: resetKey,
                                              isEnabled: isEnabled,
                                              isLoading: isLoading,
                                              isLoadingMore: isLoadingMore,
                                              onLoadMore: onLoadMore))
    }
}

private struct InfiniteScrollPagingModifier: ViewModifier {
    let space: String
    let resetKey: String
    let isEnabled: Bool
    let isLoading: Bool
    let isLoadingMore: Bool
    let onLoadMore: () -> Void

    /// 上一次触发续页时的内容高度与滚动位置：
    /// - 内容高度变大 → 上一页真的带来了新内容，可以继续把一屏缓冲填满；
    /// - 或者用户比上次触发时又往下滑了一大截 → 允许再试一次（应对偶发空页）。
    /// 用「和上次触发比」而不是「和上一帧比」，触控板每帧只滚一两个点也不会漏判。
    @State private var triggerContentHeight: CGFloat = 0
    @State private var triggerOffset: CGFloat?
    @State private var lastTriggerAt: Date = .distantPast

    func body(content: Content) -> some View {
        GeometryReader { viewport in
            content
                .coordinateSpace(name: space)
                .onPreferenceChange(ScrollPagingMetricsKey.self) { metrics in
                    handle(metrics, viewportHeight: viewport.size.height)
                }
                .onChange(of: resetKey) { _, _ in
                    triggerContentHeight = 0
                    triggerOffset = nil
                }
        }
    }

    private func handle(_ metrics: ScrollPagingMetrics, viewportHeight: CGFloat) {
        guard isEnabled, !isLoading, !isLoadingMore,
              metrics.contentHeight > 0, viewportHeight > 0 else { return }

        // 离底部还剩多少：按真实布局高度算，列数 / 卡片尺寸 / 每屏几张都自动适配。
        // 目标是把「一屏」的后续内容提前备好；内容变长后剩余距离同步变大，
        // 填满这个缓冲就自然停下，不会无限翻页。
        //
        // 注意 offset 的符号：它取的是内容顶边的 minY，往下滚会变成负数，
        // 所以「到底部的距离」是 maxOffset + offset（等价于 maxOffset - 已滚动量）。
        // 这里原先写成了 `- offset`，结果越往下滚剩余距离越大：第一页只有一屏多时
        // 顶部就能触发第 2 页，之后无论怎么滚都再也满足不了条件，表现为「只能翻两页」。
        let remaining = metrics.contentHeight - viewportHeight + metrics.offset
        guard remaining <= viewportHeight else { return }

        let contentGrew = metrics.contentHeight > triggerContentHeight + 0.5
        let scrolledFurther = triggerOffset.map { $0 - metrics.offset >= 40 } ?? true
        guard contentGrew || scrolledFurther else { return }
        // 同一帧内只补一页，避免布局回调连着触发。
        guard Date().timeIntervalSince(lastTriggerAt) > 0.35 else { return }

        lastTriggerAt = Date()
        triggerContentHeight = metrics.contentHeight
        triggerOffset = metrics.offset
        onLoadMore()
    }
}

/// 列表底部的翻页提示：加载中 / 可继续 / 已到底三种状态，高度固定不顶动网格。
/// 续页全自动，这里只做自然提示，不放需要手动点的按钮。
struct ScrollPagingFooter: View {
    var isLoadingMore: Bool
    var hasMore: Bool
    var loadedCount: Int
    /// 数量的单位：`套图集` / `条内容` / `条`。
    var unit: String = "条"

    var body: some View {
        HStack(spacing: 7) {
            if isLoadingMore {
                ProgressView()
                    .controlSize(.mini)
                Text("正在加载下一页…")
            } else if hasMore {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("继续下滑自动加载下一页")
            } else if loadedCount > 0 {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("已加载全部 \(loadedCount) \(unit)")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}
