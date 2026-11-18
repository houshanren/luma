import SwiftUI

/// 侧边栏里的一个网络存储行：点名称切换到该网盘，点左侧箭头单独展开 / 收起它的分类。
///
/// 展开状态放在本视图自己的 `@State` 里：它是 `ForEach` 的子视图，
/// 状态若放在外层容易被复用成旧值（典型表现是点了收起、分类又回来）。
struct CloudMountSidebarRow: View {
    let mount: CloudMount

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    @State private var isExpanded: Bool
    @State private var isHovering = false
    @State private var showRename = false
    @State private var renameText = ""

    init(mount: CloudMount) {
        self.mount = mount
        // 上次退出时是收起状态就保持收起。
        _isExpanded = State(initialValue: SidebarStateStorage
            .stringSet(SidebarStateStorage.Key.expandedCloudMounts)
            .contains(mount.id.uuidString))
    }

    private var item: SidebarItem { .cloudMount(mount.id) }
    private var isMountSelected: Bool { store.sidebarItem == item }
    /// 网盘内的分类 / 相簿 / 分区总览被选中时，高亮让给更具体的那一行：
    /// 否则网盘行、全部项目、所有相簿会同时点亮。
    private var showsMountHighlight: Bool {
        guard isMountSelected else { return false }
        // 分区总览没有独立的行，锚点留在网盘行。
        if cloud.overview != nil { return true }
        return cloud.scope == .all && cloud.selectedFolderPath == nil
    }
    /// 打开这个网盘的影院时仍算「当前网盘」：分类树保持展开，但高亮只留给真正选中的那一行。
    private var isCurrent: Bool {
        isMountSelected || store.sidebarItem == .cloudCinema(mount.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if isCurrent, isExpanded {
                CloudMountDetailView(mountID: mount.id)
            }
        }
        .onChange(of: isExpanded) { _, value in
            var expanded = SidebarStateStorage.stringSet(SidebarStateStorage.Key.expandedCloudMounts)
            if value {
                expanded.insert(mount.id.uuidString)
            } else {
                expanded.remove(mount.id.uuidString)
            }
            SidebarStateStorage.save(SidebarStateStorage.Key.expandedCloudMounts, expanded)
        }
    }

    private var row: some View {
        HStack(spacing: 2) {
            Button {
                if isMountSelected {
                    // 回到整个网盘：清掉分类过滤、相簿与总览，高亮回到网盘行。
                    store.setCloudScope(.all)
                    store.selectCloudFolder(path: nil)
                    store.showCloudOverview(nil)
                } else {
                    store.navigate(to: item)
                }
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    cover
                    Text(mount.name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if cloud.loading, isCurrent {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 与下方分类行同一左边界：展开箭头放在行尾，不再把封面往里挤。
            Button {
                toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCurrent && isExpanded ? 0 : -90))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCurrent && isExpanded ? "收起分类" : "展开分类")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
        .background {
            // 影院也算当前网盘（保持树展开），但高亮只跟随真正选中的那一行：
            // 影院行 / 分类行 / 相簿行亮起时，网盘行不再同时点亮。
            LumaRowHighlight(active: showsMountHighlight, hovered: isHovering)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("打开整个网盘") {
                store.navigate(to: item)
                store.selectCloudFolder(path: nil)
            }
            Button("重新扫描") {
                store.navigate(to: item)
                store.refreshCloudDirectory()
            }
            Divider()
            Button("打开影院") {
                store.activateCinemaScope(.mount(mount.id))
                store.navigate(to: .cloudCinema(mount.id))
            }
            Button("刮削这个网盘的视频") {
                Task { await store.scrapeCinema(for: .mount(mount.id)) }
            }
            Divider()
            Button("重命名…") {
                renameText = mount.name
                showRename = true
            }
            if mount.kind == .webdav || mount.kind == .smb {
                Button("编辑连接…") {
                    store.presentCloudSheet(mount)
                }
            } else {
                let alwaysCookie = mount.kind == .quark || mount.kind == .aliyun
                Button(alwaysCookie ? "更新 Cookie…" : "重新授权…") {
                    store.presentCloudWizard(flow: mount.kind.wizardFlow)
                }
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.confirmRemoveCloudMount(mount.id)
            }
        }
        .alert("重命名网络存储", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                store.renameCloudMount(mount.id, to: renameText)
            }
        } message: {
            Text("只修改侧边栏里的显示名称，不会影响网盘上的内容。")
        }
    }

    /// 与相簿封面同为 20pt 圆角方块：官方网盘直接用产品图标，其余用品牌渐变 + 系统符号。
    private var cover: some View {
        Group {
            if let brand = mount.kind.brand {
                CloudBrandIcon(brand: brand, size: LumaMetrics.sidebarCoverSize)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                        .fill(LinearGradient(colors: coverColors,
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var coverColors: [Color] {
        switch mount.kind {
        case .baidu:
            return [Color(red: 0.26, green: 0.55, blue: 1.00), Color(red: 0.10, green: 0.34, blue: 0.88)]
        case .aliyun:
            return [Color(red: 0.36, green: 0.68, blue: 1.00), Color(red: 0.14, green: 0.42, blue: 0.92)]
        case .quark:
            return [Color(red: 0.42, green: 0.36, blue: 1.00), Color(red: 0.20, green: 0.22, blue: 0.86)]
        case .webdav:
            return [LumaBrand.cyan.opacity(0.95), LumaBrand.violet.opacity(0.90)]
        case .smb:
            return [Color(red: 0.52, green: 0.48, blue: 0.45), Color(red: 0.30, green: 0.27, blue: 0.25)]
        }
    }

    private var icon: String { mount.kind.symbolName }

    /// 未打开时先打开（并展开），已打开时切换。
    private func toggle() {
        if !isCurrent {
            isExpanded = true
            store.navigate(to: item)
            return
        }
        withAnimation(settings.motion.layout) {
            isExpanded.toggle()
        }
    }
}
