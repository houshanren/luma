import SwiftUI

/// 窗口工具栏中区的分页胶囊：图库 / 网络资源 / 网络存储 / 网络影院 / 网络电视共用一套。
///
/// 之前每个 Hub 各写一份，字号（11.5）、图标（9.5）、高度（24）和未选中前景色（`.secondary`）
/// 各差一点，五个页面的顶部栏看起来不齐、字也发灰。这里把尺寸与颜色收成唯一来源：
/// 高度 28 与工具栏里的读数胶囊同高，标题 12.5 / 图标 11.5，未选中用主墨色 `LumaInk.primary`，
/// 保证浅色底上依然清晰。
struct HubTabBar<Item: Identifiable & Hashable>: View {
    let items: [Item]
    let active: Item
    let title: (Item) -> String
    let symbol: (Item) -> String
    var badge: (Item) -> Int? = { _ in nil }
    var help: ((Item) -> String)? = nil
    let action: (Item) -> Void

    @Environment(\.colorScheme) private var scheme
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: HubTabMetrics.spacing) {
            ForEach(items) { item in
                tabButton(item)
            }
        }
        .padding(HubTabMetrics.trackPadding)
        .background(LumaInk.fill(.quiet, scheme: scheme), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(LumaInk.hairline(scheme), lineWidth: 0.6)
        }
        // 工具栏变窄时宁可整体溢出，也不要把标签压成「…」、把角标折成两行。
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ item: Item) -> some View {
        let isActive = item == active
        let label = title(item)
        return Button {
            action(item)
        } label: {
            HStack(spacing: HubTabMetrics.contentSpacing) {
                Image(systemName: symbol(item))
                    .font(.system(size: HubTabMetrics.symbolSize, weight: .semibold))
                    .fixedSize()
                Text(label)
                    .font(.system(size: HubTabMetrics.titleSize, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let value = badge(item), value > 0 {
                    Text("\(value)")
                        .font(.system(size: HubTabMetrics.badgeSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isActive ? Color.accentColor : LumaInk.primary(scheme))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(isActive ? Color.white : LumaInk.fill(.regular, scheme: scheme),
                                    in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            // 未选中不再用 .secondary：浅色底上偏灰，扫一眼读不出来。用主墨色保证鲜明。
            .foregroundStyle(isActive ? Color.white : LumaInk.primary(scheme))
            .padding(.horizontal, HubTabMetrics.horizontalPadding)
            .frame(height: HubTabMetrics.tabHeight)
            .background {
                if isActive {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "hub-tab-selection", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help?(item) ?? label)
    }
}

/// 分页胶囊的唯一尺寸来源。泛型类型里不能存静态属性，所以单独放在文件作用域。
private enum HubTabMetrics {
    /// 单个分页高度：与 `ModuleReadoutStrip` 一致，五个 Hub 的顶部栏完全同高。
    static let tabHeight: CGFloat = 28
    static let trackPadding: CGFloat = 3
    static let spacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 12
    static let contentSpacing: CGFloat = 6
    static let titleSize: CGFloat = 12.5
    static let symbolSize: CGFloat = 11.5
    static let badgeSize: CGFloat = 9.5
}
