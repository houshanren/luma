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
    /// 传了缩略图就用它替代系统图标（网络资源的分类行用站点真实封面）。
    var thumbnailSource: CatalogSource?
    var thumbnailURL: String?
    /// 二级分类向右缩进，和一级分组拉开层级。
    var leadingIndent: CGFloat = 8
    /// 二级分类用小圆点当图标。
    var iconSize: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                iconView
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
            .padding(.leading, leadingIndent)
            .padding(.trailing, 8)
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

    @ViewBuilder
    private var iconView: some View {
        if let thumbnailSource, let thumbnailURL, !thumbnailURL.isEmpty {
            // 缩略图固定 20×20：封面是横图，scaledToFill 会向外撑开，
            // 这里用 Color.clear 兜住尺寸、再裁到圆角方块，避免盖住右边的标题。
            Color.clear
                .frame(width: LumaMetrics.sidebarCoverSize,
                       height: LumaMetrics.sidebarCoverSize)
                .overlay {
                    CatalogArtworkImage(source: thumbnailSource,
                                        urlString: thumbnailURL,
                                        cornerRadius: LumaMetrics.sidebarCoverRadius)
                }
                .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                           style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                     style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            Image(systemName: icon)
                .font(.system(size: iconSize ?? LumaMetrics.sidebarIconSize))
                .foregroundStyle(iconColor)
        }
    }
}

/// 可收起的分区头：整行（含左右留白）是点击区，标题可点击打开总览；
/// 悬停时浮出「更多」与收起 / 展开按钮。拾光、系统图库与网盘共用。
struct SidebarSectionHeader<MenuContent: View>: View {
    let title: String
    let collapsed: Bool
    var active: Bool = false
    var topPadding: CGFloat = 12
    /// 嵌套在上级分区里时向右缩进，和一级分区拉开层级。
    var indent: CGFloat = 0
    var isHovered: Bool = false
    var onOpen: (() -> Void)?
    let onToggle: () -> Void
    let menu: () -> MenuContent

    init(title: String,
         collapsed: Bool,
         active: Bool = false,
         topPadding: CGFloat = 12,
         indent: CGFloat = 0,
         isHovered: Bool = false,
         onOpen: (() -> Void)? = nil,
         onToggle: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }) {
        self.title = title
        self.collapsed = collapsed
        self.active = active
        self.topPadding = topPadding
        self.indent = indent
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
                // 没有二级总览的分区：整行点击就展开 / 收起，不必非要点右侧箭头。
                Button(action: onToggle) {
                    HStack(spacing: 0) {
                        label
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开「\(title)」" : "收起「\(title)」")
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
        .padding(.leading, indent)
    }
}
