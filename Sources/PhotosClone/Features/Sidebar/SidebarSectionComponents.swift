import SwiftUI

/// 侧边栏分类行：拾光、系统图库与网盘共用同一套图标列、字号、内边距与悬停高亮。
/// 数量只在调用方传入时显示（场景类型带数量，媒体类型与「更多项目」不带）。
struct SidebarCategoryRow: View {
    let icon: String
    let title: String
    var iconColor: Color = .accentColor
    var trailingIcon: String?
    var count: Int?
    var isActive: Bool = false
    var isHovered: Bool = false
    var helpText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: icon)
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(iconColor)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text(title)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: isActive, hovered: isHovered)
            }
        }
        .buttonStyle(.plain)
        .help(helpText ?? title)
        .accessibilityLabel(title)
    }
}

/// 可收起的分区头：整行（含左右留白）是点击区，标题可点击打开总览；
/// 悬停时浮出「更多」与收起 / 展开按钮。拾光、系统图库与网盘共用。
struct SidebarSectionHeader<MenuContent: View>: View {
    let title: String
    let collapsed: Bool
    var active: Bool = false
    var topPadding: CGFloat = 12
    var isHovered: Bool = false
    var onOpen: (() -> Void)?
    let onToggle: () -> Void
    let menu: () -> MenuContent

    init(title: String,
         collapsed: Bool,
         active: Bool = false,
         topPadding: CGFloat = 12,
         isHovered: Bool = false,
         onOpen: (() -> Void)? = nil,
         onToggle: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }) {
        self.title = title
        self.collapsed = collapsed
        self.active = active
        self.topPadding = topPadding
        self.isHovered = isHovered
        self.onOpen = onOpen
        self.onToggle = onToggle
        self.menu = menu
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 整行（含左右留白）都是点击区域，不只是标题那几个字。
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 0) {
                        label
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开「\(title)」总览")
            } else {
                HStack(spacing: 0) {
                    label
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            }

            // 「更多」与收起 / 展开按钮浮在整行点击区之上，各自响应自己的点击。
            HStack(spacing: 2) {
                if isHovered {
                    Menu {
                        Button(collapsed ? "展开" : "收起") { onToggle() }
                        menu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 16)
                    .help("更多")
                }
                if isHovered || collapsed {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "展开" : "收起")
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.top, topPadding)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
    }

    /// 分区标题：左侧一条强调色细线 + 轻微字距，让侧边栏有清晰的层级节奏。
    private var label: some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(
                    LinearGradient(colors: [
                        Color.accentColor.opacity(active ? 0.95 : 0.42),
                        Color.accentColor.opacity(active ? 0.35 : 0.08)
                    ], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 2, height: 10)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.06)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
    }
}
