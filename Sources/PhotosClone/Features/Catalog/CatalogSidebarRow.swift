import SwiftUI
import LumaContentCore

/// 侧边栏里的一个网络资源：只有一行入口。
/// 分类都在右侧频道区展示，侧边栏不再铺一棵树，也没有展开 / 收起。
struct CatalogSidebarRow: View {
    let source: CatalogSource
    /// 正在把别的资源拖到这一行上方：画一条落点提示线。
    var isDropTarget: Bool = false

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel

    @State private var showRename = false
    @State private var renameText = ""

    private var item: SidebarItem { .catalogSource(source.id) }
    private var isCurrent: Bool { store.sidebarItem == item }

    var body: some View {
        row
            .alert("重命名网络资源", isPresented: $showRename) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("保存") { catalog.rename(source.id, to: renameText) }
            } message: {
                Text("只修改侧边栏的显示名称，不影响源地址与解析参数。")
            }
    }

    // MARK: - 源行

    private var row: some View {
        SourceSidebarRow(
            model: SourceRowModel(
                title: source.name,
                subtitle: nil,
                badge: nil,
                countText: nil,
                isCurrent: isCurrent,
                isEnabled: source.isEnabled,
                isLoading: catalog.isLoading && isCurrent,
                showsNewBadge: catalog.hasNewContent(source.id)
            ),
            isDropTarget: isDropTarget,
            onOpen: {
                // 点资源本身 = 切到这个源并打开它的首页。
                open { $0.openHome() }
            },
            dragProvider: {
                catalogSourceDragProvider(source.id)
            }
        ) { hovered in
            cover(hovered: hovered)
        } menu: {
            Button("打开") { open { $0.openHome() } }
            Button("刷新") {
                open { $0.selectSource(source.id) }
            }
            Divider()
            Button("上移") { catalog.moveSource(source.id, by: -1) }
                .disabled(catalog.sources.first?.id == source.id)
            Button("下移") { catalog.moveSource(source.id, by: 1) }
                .disabled(catalog.sources.last?.id == source.id)
            Divider()
            Button(source.isEnabled ? "停用" : "启用") {
                catalog.setEnabled(source.id, enabled: !source.isEnabled)
            }
            Button("重命名…") {
                renameText = source.name
                showRename = true
            }
            Button("清除海报缓存") {
                catalog.clearArtwork(source.id)
            }
            Toggle("允许不受信任的证书", isOn: Binding(
                get: { source.trustsInsecureCertificate },
                set: { catalog.setInsecureTLS(source.id, $0) }
            ))
            Divider()
            Button("移除资源", role: .destructive) {
                catalog.remove(source.id)
            }
        }
    }

    private func cover(hovered: Bool) -> some View {
        // 每个源一个专属色块与图标：一排源扫过去能立刻分辨，而不是同一个橙色方块。
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [source.kind.sidebarTint,
                                              source.kind.sidebarTint.opacity(0.62)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.34), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            Image(systemName: source.kind.sidebarSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        }
        .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(hovered ? 0.34 : 0.20), lineWidth: 0.6)
        }
        .shadow(color: source.kind.sidebarTint.opacity(hovered ? 0.45 : 0.26),
                radius: hovered ? 6 : 3, y: 1.5)
        .scaleEffect(hovered ? 1.06 : 1)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .opacity(source.isEnabled ? 1 : 0.5)
    }

    private func open(_ action: (CatalogBrowserModel) -> Void) {
        // 统一走 sourceHub：先切到本源，再执行调用方要的加载动作；
        // 否则在另一个资源页里点本源的入口，会拿旧源的 selectedSource 去请求新源。
        store.sourceHub.activate(.catalog(source.id))
        action(catalog)
    }
}

/// 网络资源的图标与配色：侧边栏、总览卡片共用。
extension CatalogProviderKind {
    var sidebarSymbol: String {
        switch self {
        case .huangguo: return "play.rectangle.fill"
        case .ninetyOne: return "flame.fill"
        case .ninetyOnePorna: return "sparkles"
        case .xszAV: return "bolt.fill"
        case .missav: return "waveform"
        case .avple: return "play.square.stack.fill"
        case .shise: return "film.stack.fill"
        case .avgle: return "globe.asia.australia.fill"
        case .rouVideo: return "play.tv.fill"
        case .quanji: return "film.fill"
        case .javcl: return "play.rectangle.on.rectangle.fill"
        case .madou: return "house.fill"
        case .javgg: return "rectangle.stack.fill"
        }
    }

    var sidebarTint: Color {
        switch self {
        case .huangguo: return .orange
        case .ninetyOne: return .pink
        case .ninetyOnePorna: return .indigo
        case .xszAV: return .teal
        case .missav: return .purple
        case .avple: return .blue
        case .shise: return .mint
        case .avgle: return .cyan
        case .rouVideo: return .red
        case .quanji: return .brown
        case .javcl: return .green
        case .madou: return .orange
        case .javgg: return .yellow
        }
    }
}
