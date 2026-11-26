import AppKit
import SwiftUI

/// 交互墨色与填充层级：胶囊 / 卡片 / 徽标的颜色只从这里取，不在视图里写字面透明度。
///
/// 取值都基于系统语义色（`Color.primary` / 强调色），因此浅色、深色与自定义强调色
/// 会自动一起变化；这里只决定「同一层级在不同外观下的粗细」。
package enum LumaInk {
    /// 填充层级：从最淡的页面底到最实的强调块。
    package enum FillLevel: Sendable {
        /// 大面积、可忽略的底色（分区底、输入框底）。
        case faint
        /// 常规控件的静默底（未选中的筛选项）。
        case quiet
        /// 卡片、悬停行的底。
        case regular
        /// 需要从页面里浮起来的小块（浮层内卡片）。
        case raised
        /// 需要明显区分的实底（进度槽、分段控件底）。
        case strong
    }

    package static func primary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.92) : Color.primary
    }

    package static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.80) : Color.primary.opacity(0.66)
    }

    package static func tertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.58) : Color.primary.opacity(0.45)
    }

    /// 0.6pt 发丝线：分隔线、胶囊描边。
    package static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.primary.opacity(0.08)
    }

    package static func fill(_ level: FillLevel, scheme: ColorScheme) -> Color {
        switch level {
        case .faint: return Color.primary.opacity(scheme == .dark ? 0.055 : 0.035)
        case .quiet: return Color.primary.opacity(scheme == .dark ? 0.075 : 0.05)
        case .regular: return Color.primary.opacity(scheme == .dark ? 0.11 : 0.08)
        case .raised: return Color.primary.opacity(scheme == .dark ? 0.15 : 0.12)
        case .strong: return Color.primary.opacity(scheme == .dark ? 0.22 : 0.18)
        }
    }

    /// 强调色洗底：选中胶囊、计数徽标。深色模式需要更高的不透明度才看得出颜色。
    package static func tintWash(_ tint: Color, scheme: ColorScheme) -> Color {
        tint.opacity(scheme == .dark ? 0.24 : 0.15)
    }

    package static func tintHairline(_ tint: Color, scheme: ColorScheme) -> Color {
        tint.opacity(scheme == .dark ? 0.55 : 0.45)
    }

    /// 实底上的文字：亮度高于 0.62 的强调色（金 / 薄荷）改用深色字，保证对比度。
    package static func onTint(_ tint: Color) -> Color {
        let ns = NSColor(tint).usingColorSpace(.sRGB) ?? .white
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luminance > 0.62 ? Color.black.opacity(0.85) : .white
    }
}

/// 胶囊 / 卡片的几何与描边：圆角、内边距、发丝线只在这里定义。
package enum LumaControlMetrics {
    /// 胶囊横向内边距（计数、标签、筛选项）。
    package static let pillHorizontalPadding: CGFloat = 8
    /// 胶囊纵向内边距：13pt 以内的文字配 3，整高约 24。
    package static let pillVerticalPadding: CGFloat = 3
    /// 筛选项的纵向内边距：稍大一点，点击区域更稳。
    package static let chipVerticalPadding: CGFloat = 4
    /// 常规发丝线。
    package static let hairline: CGFloat = 0.6
    /// 需要强调的描边（选中、主按钮）。
    package static let border: CGFloat = 0.8
    /// 卡片圆角：与 `LumaMetrics.rowRadius` 区分，卡片统一 10。
    package static let cardRadius: CGFloat = 10
    /// 卡片内边距。
    package static let cardPadding: CGFloat = 10
    /// 胶囊的最小可点击高度。
    package static let pillMinHeight: CGFloat = 22
}

/// 胶囊底：一次填色 + 一条描边。所有胶囊控件都套这一层，不再各自写 `fill` + `strokeBorder`。
package struct LumaPillSurface<Fill: ShapeStyle, Stroke: ShapeStyle>: View {
    package let fill: Fill
    package let stroke: Stroke
    package let lineWidth: CGFloat

    package init(fill: Fill,
                 stroke: Stroke,
                 lineWidth: CGFloat = LumaControlMetrics.hairline) {
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
    }

    package var body: some View {
        Capsule(style: .continuous)
            .fill(fill)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: lineWidth)
            }
    }
}

private struct LumaPillModifier<Fill: ShapeStyle, Stroke: ShapeStyle>: ViewModifier {
    let fill: Fill
    let stroke: Stroke
    let lineWidth: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                LumaPillSurface(fill: fill, stroke: stroke, lineWidth: lineWidth)
            }
            .contentShape(Capsule(style: .continuous))
    }
}

private struct LumaPillSurfaceModifier<Fill: ShapeStyle, Stroke: ShapeStyle>: ViewModifier {
    let fill: Fill
    let stroke: Stroke
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                LumaPillSurface(fill: fill, stroke: stroke, lineWidth: lineWidth)
            }
            .contentShape(Capsule(style: .continuous))
    }
}

private struct LumaChipModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let selected: Bool
    let tint: Color
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        let fill = selected
            ? LumaInk.tintWash(tint, scheme: scheme)
            : LumaInk.fill(.quiet, scheme: scheme)
        let stroke = selected
            ? LumaInk.tintHairline(tint, scheme: scheme)
            : Color.clear
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                LumaPillSurface(fill: fill, stroke: stroke, lineWidth: LumaControlMetrics.border)
            }
            .contentShape(Capsule(style: .continuous))
    }
}

private struct LumaGlassPillModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                LumaPillSurface(fill: AnyShapeStyle(.ultraThinMaterial),
                                stroke: LumaInk.hairline(scheme))
            }
            .contentShape(Capsule(style: .continuous))
    }
}

private struct LumaCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let tint: Color?
    let raised: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        let fill = tint.map { $0.opacity(scheme == .dark ? 0.10 : 0.07) }
            ?? LumaInk.fill(raised ? .raised : .quiet, scheme: scheme)
        let stroke = tint.map { $0.opacity(scheme == .dark ? 0.42 : 0.30) }
            ?? LumaInk.hairline(scheme)
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(stroke, lineWidth: LumaControlMetrics.hairline)
                    }
            }
    }
}

extension View {
    /// 胶囊控件：统一内边距 + 统一发丝描边。
    package func lumaPill<Fill: ShapeStyle, Stroke: ShapeStyle>(
        fill: Fill,
        stroke: Stroke,
        lineWidth: CGFloat = LumaControlMetrics.hairline,
        horizontalPadding: CGFloat = LumaControlMetrics.pillHorizontalPadding,
        verticalPadding: CGFloat = LumaControlMetrics.pillVerticalPadding
    ) -> some View {
        modifier(LumaPillModifier(fill: fill,
                                 stroke: stroke,
                                 lineWidth: lineWidth,
                                 horizontalPadding: horizontalPadding,
                                 verticalPadding: verticalPadding))
    }

    /// 已经自己处理内边距时只加胶囊底。
    package func lumaPillSurface<Fill: ShapeStyle, Stroke: ShapeStyle>(
        fill: Fill,
        stroke: Stroke,
        lineWidth: CGFloat = LumaControlMetrics.hairline
    ) -> some View {
        modifier(LumaPillSurfaceModifier(fill: fill, stroke: stroke, lineWidth: lineWidth))
    }

    /// 磨砂胶囊：只用于压在照片 / 工具栏这类有背景的内容上。
    /// 普通页面里的筛选项、标签用 `lumaChip` / `LumaBadge`，不要无脑上材质（模糊有成本）。
    package func lumaGlassPill(horizontalPadding: CGFloat = 11,
                               verticalPadding: CGFloat = 5) -> some View {
        modifier(LumaGlassPillModifier(horizontalPadding: horizontalPadding,
                                       verticalPadding: verticalPadding))
    }

    /// 筛选胶囊：选中用强调色洗底 + 同色描边，未选中用静默底。
    package func lumaChip(selected: Bool,
                          tint: Color = .accentColor,
                          horizontalPadding: CGFloat = LumaControlMetrics.pillHorizontalPadding,
                          verticalPadding: CGFloat = LumaControlMetrics.chipVerticalPadding) -> some View {
        modifier(LumaChipModifier(selected: selected,
                                  tint: tint,
                                  horizontalPadding: horizontalPadding,
                                  verticalPadding: verticalPadding))
    }

    /// 卡片底：低透明填充 + 发丝描边；传 `tint` 时用同一色的浅洗底，作为「这一块属于它」的提示。
    /// 视图手上已有用户的 `settings.cardRadius` 时传进来，卡片圆角就跟随设置。
    package func lumaCardSurface(tint: Color? = nil,
                                 raised: Bool = false,
                                 radius: CGFloat = LumaControlMetrics.cardRadius) -> some View {
        modifier(LumaCardModifier(tint: tint, raised: raised, radius: radius))
    }
}

/// 胶囊徽标：计数、状态、类型标签。字号与内边距固定，只保留一行，长了就截断。
package struct LumaBadge: View {
    @Environment(\.colorScheme) private var scheme

    package let text: String
    package var systemImage: String?
    package var tint: Color
    package var compact: Bool

    package init(_ text: String,
                 systemImage: String? = nil,
                 tint: Color = .accentColor,
                 compact: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.compact = compact
    }

    package var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 8.5 : 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : LumaControlMetrics.pillHorizontalPadding)
        .padding(.vertical, compact ? 2 : LumaControlMetrics.pillVerticalPadding)
        .background {
            LumaPillSurface(fill: LumaInk.tintWash(tint, scheme: scheme),
                            stroke: Color.clear)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(text)
    }
}
