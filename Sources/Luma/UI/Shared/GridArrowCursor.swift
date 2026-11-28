import AppKit
import SwiftUI

/// 网格的方向键游标：←/→ 前后一格，↑/↓ 上下换行，回车 / 空格触发当前格子。
///
/// 统一用在网络资源、影院海报墙、直播频道墙与星图名册上，保证三处的键盘手感一致：
/// - 焦点：网格出现、或鼠标在网格上移动时自动接管，方向键不用先点一下才响应；
///   正在编辑文本（搜索框、备注）时让出，避免把输入吞掉。
/// - 步进按列数算，最后一排不足一行时也不会跳到越界位置。
struct GridArrowCursor<ID: Hashable>: ViewModifier {
    @Binding var cursor: ID?
    let ids: [ID]
    let columns: Int
    let onActivate: (ID) -> Void

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-max(columns, 1)) }
            .onKeyPress(.downArrow) { move(max(columns, 1)) }
            .onKeyPress(.return) { activate() }
            .onKeyPress(.space) { activate() }
            .onChange(of: ids) { _, newIDs in
                if let cursor, !newIDs.contains(cursor) { self.cursor = nil }
                // 数据是异步来的：列表铺好后立刻接管焦点，方向键不用先悬停一次才生效。
                if !newIDs.isEmpty { adoptFocus() }
            }
            .onAppear { adoptFocus() }
            .onContinuousHover { phase in
                if case .active = phase { adoptFocus() }
            }
    }

    private func adoptFocus() {
        // 没有可导航的条目（例如列表模式复用了同一个滚动区）时完全不接管键盘。
        guard !ids.isEmpty else { return }
        // 搜索框 / 备注正在输入时不要抢焦点，否则方向键与空格会从输入框里被抢走。
        guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        focused = true
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        adoptFocus()
        guard let cursor, let index = ids.firstIndex(of: cursor) else {
            self.cursor = delta < 0 ? ids.last : ids.first
            return .handled
        }
        let next = min(max(index + delta, 0), ids.count - 1)
        self.cursor = ids[next]
        return .handled
    }

    private func activate() -> KeyPress.Result {
        guard !ids.isEmpty, let cursor else { return .ignored }
        onActivate(cursor)
        return .handled
    }
}

extension View {
    /// 给网格 / 滚动区挂上方向键游标；`ids` 是当前可见条目的视觉顺序。
    func gridArrowCursor<ID: Hashable>(_ cursor: Binding<ID?>,
                                       ids: [ID],
                                       columns: Int,
                                       onActivate: @escaping (ID) -> Void) -> some View {
        modifier(GridArrowCursor(cursor: cursor, ids: ids,
                                 columns: columns, onActivate: onActivate))
    }
}

/// 自适应列数：与 `GridItem(.adaptive(minimum:maximum:))` 的排布一致，
/// 用来把方向键换算成「上下一行」。
func adaptiveColumnCount(width: CGFloat,
                         minimum: CGFloat,
                         maximum: CGFloat,
                         spacing: CGFloat) -> Int {
    guard width > 0 else { return 1 }
    var count = max(1, Int((width + spacing) / (minimum + spacing)))
    while count > 1,
          (width - CGFloat(count - 1) * spacing) / CGFloat(count) > maximum {
        count += 1
    }
    return count
}

/// 上报容器宽度：自适应网格据此算列数。
struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 在背景里量一次宽度，供外层计算列数；不影响布局。
    func reportGridWidth() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: GridWidthKey.self, value: proxy.size.width)
            }
        }
    }
}
