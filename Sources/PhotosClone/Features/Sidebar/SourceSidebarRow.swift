import SwiftUI

/// 侧边栏「源」行的统一描述：云盘、网络资源、影院、电视、本地磁盘共用。
/// 只放展示数据，不放具体业务动作；动作由调用方通过闭包注入。
struct SourceRowModel {
    enum BadgeTone {
        case neutral
        case current
        case ok
        case warn
        case bad
    }

    struct Badge {
        var text: String
        var tone: BadgeTone = .neutral
    }

    var title: String
    var subtitle: String?
    var badge: Badge?
    var countText: String?
    var isCurrent: Bool = false
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var showsNewBadge: Bool = false
    /// 刮削进度（0–1）：有值时在行尾画一枚小进度环。
    var progress: Double? = nil
}

/// 侧边栏源行的统一外壳：封面、标题、状态、悬停、拖拽手柄、展开按钮与右键菜单。
/// 与 `SidebarCategoryRow` 保持同一套行高、图标列、圆角与高亮。
struct SourceSidebarRow<Cover: View, Menu: View>: View {
    let model: SourceRowModel
    var isExpanded: Bool = false
    var showsToggle: Bool = false
    var isDropTarget: Bool = false
    var onOpen: () -> Void
    var onToggle: (() -> Void)?
    var dragProvider: (() -> NSItemProvider)?
    @ViewBuilder var cover: (Bool) -> Cover
    @ViewBuilder var menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    cover(isHovering)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.title)
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .lineLimit(1)
                        if let subtitle = model.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if model.showsNewBadge {
                        Text("新")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                    }
                    Spacer(minLength: 0)
                    if !model.isEnabled {
                        Text("未启用")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    } else if model.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if let progress = model.progress {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: max(0.02, min(1, progress)))
                                .stroke(LumaBrand.amber,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                        .help("刮削中 \(Int(progress * 100))%")
                    }
                    if let badge = model.badge {
                        badgeView(badge)
                    }
                    if let countText = model.countText, !countText.isEmpty {
                        Text(countText)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let dragProvider {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovering ? Color.secondary : Color.clear)
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onDrag(dragProvider)
                    .help("拖动调整源顺序")
            }

            if showsToggle, let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 16, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起" : "展开")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
        .background {
            LumaRowHighlight(active: model.isCurrent, hovered: isHovering)
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 3)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            menu()
        }
        .accessibilityLabel(model.title)
    }

    @ViewBuilder
    private func badgeView(_ badge: SourceRowModel.Badge) -> some View {
        Text(badge.text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(badgeForeground(badge.tone))
            .background(badgeBackground(badge.tone), in: Capsule(style: .continuous))
    }

    private func badgeForeground(_ tone: SourceRowModel.BadgeTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .current: return .white
        case .ok: return Color(red: 0.23, green: 0.72, blue: 0.45)
        case .warn: return Color(red: 0.78, green: 0.55, blue: 0.10)
        case .bad: return Color(red: 0.80, green: 0.30, blue: 0.24)
        }
    }

    private func badgeBackground(_ tone: SourceRowModel.BadgeTone) -> Color {
        switch tone {
        case .neutral: return Color.primary.opacity(0.06)
        case .current: return Color.accentColor
        case .ok: return Color(red: 0.23, green: 0.72, blue: 0.45).opacity(0.13)
        case .warn: return Color(red: 0.78, green: 0.55, blue: 0.10).opacity(0.14)
        case .bad: return Color(red: 0.80, green: 0.30, blue: 0.24).opacity(0.14)
        }
    }
}
