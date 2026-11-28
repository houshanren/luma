import Foundation

/// 智能助手只有一套会话，界面上有四种呈现形态（收起不算一种形态）：
/// 并排（侧栏停靠，内容让位）、叠放（侧栏盖在内容上，布局不动）、浮窗、工作台（左侧菜单里的独立一页）。
/// 查看器里额外的半隐藏竖标签由界面层按上下文决定，不进入这个枚举。
enum AISurfaceMode: String, CaseIterable, Identifiable {
    case hidden
    case docked
    case overlay
    case floating
    case workspace

    var id: String { rawValue }

    /// 可以在控制台 / 菜单里切换的四种形态，顺序固定。
    static let presentations: [AISurfaceMode] = [.docked, .overlay, .floating, .workspace]

    var title: String {
        switch self {
        case .hidden: return "收起"
        case .docked: return "并排"
        case .overlay: return "叠放"
        case .floating: return "浮窗"
        case .workspace: return "工作台"
        }
    }

    /// 一句话说明形态与页面之间的关系，用于控制台副标题。
    var detail: String {
        switch self {
        case .hidden: return "不显示"
        case .docked: return "内容让位"
        case .overlay: return "盖在页面上"
        case .floating: return "可拖可缩放"
        case .workspace: return "菜单独立一页"
        }
    }

    var symbol: String {
        switch self {
        case .hidden: return "rectangle.righthalf.inset.filled"
        case .docked: return "sidebar.right"
        case .overlay: return "square.on.square"
        case .floating: return "macwindow.on.rectangle"
        case .workspace: return "macwindow"
        }
    }
}
