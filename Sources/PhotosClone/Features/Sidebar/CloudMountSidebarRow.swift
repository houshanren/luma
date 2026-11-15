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

    @State private var isExpanded = true
    @State private var isHovering = false

    private var item: SidebarItem { .cloudMount(mount.id) }
    private var isCurrent: Bool { store.sidebarItem == item }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if isCurrent, isExpanded {
                CloudMountDetailView()
            }
        }
    }

    private var row: some View {
        HStack(spacing: 2) {
            Button {
                toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCurrent && isExpanded ? 0 : -90))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCurrent && isExpanded ? "收起分类" : "展开分类")

            Button {
                store.navigate(to: item)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    Text(mount.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if cloud.loading, isCurrent {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.16))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("刷新") {
                if isCurrent {
                    store.refreshCloudDirectory()
                } else {
                    store.navigate(to: item)
                }
            }
            if mount.kind == .webdav || mount.kind == .smb {
                Button("编辑连接…") {
                    store.presentCloudSheet(mount)
                }
            } else {
                Button("重新授权…") {
                    store.presentCloudWizard(flow: mount.kind == .aliyun ? .aliyun : .baidu)
                }
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.removeCloudMount(mount.id)
            }
        }
    }

    private var icon: String {
        switch mount.kind {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "network"
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        }
    }

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
