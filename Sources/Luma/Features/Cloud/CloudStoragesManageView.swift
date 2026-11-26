import SwiftUI
import AppKit
import Foundation
import LumaContentCore

// MARK: - 网盘管理

/// 网盘管理：接入、鉴权、索引、接入范围、扫描动作与跨源总览集中在一页。
/// 原来「存储 / 总览 / 管理」三个分页看的是同一批存储，这里按存储逐条核对，
/// 卡片既能看到连接与索引状态，也能直接打开、重扫、改范围、换凭据或断开。
struct CloudStoragesManageView: View {
    @Environment(LibraryStore.self) var store
    @Environment(CloudBrowserModel.self) var cloud
    @State var indexStates: [UUID: CloudIndexState] = [:]
    @State var renamingMount: CloudMount?
    @State var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if cloud.mounts.isEmpty {
                    LumaEmptyState(symbol: "wrench.and.screwdriver",
                                   title: "还没有需要管理的存储",
                                   message: "接入存储后，这里会列出每个连接的鉴权方式、读写权限、索引体量与新鲜度。",
                                   style: .card,
                                   actions: [LumaEmptyAction(title: "接入存储",
                                                             symbol: "plus") {
                                       store.presentCloudWizard()
                                   }])
                } else {
                    headerActions
                    safetyNote
                    VStack(spacing: 12) {
                        ForEach(cloud.mounts) { mount in
                            maintenanceCard(mount)
                        }
                    }
                    overviewSection
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: cloud.mounts.count) {
            indexStates = store.cloudIndexStates()
            autoCheckMounts()
        }
        .alert("重命名网络存储", isPresented: renamePresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingMount = nil }
            Button("保存") {
                if let mount = renamingMount {
                    store.renameCloudMount(mount.id, to: renameText)
                }
                renamingMount = nil
            }
        } message: {
            Text("只修改显示名称，不会影响网盘上的内容。")
        }
    }

    /// 页头动作：原来在标题右侧，标题删掉后收进管理读数面板的顶行，贴着说明走。
    var headerActions: some View {
        HStack(spacing: 8) {
            Text("接入、鉴权、索引与接入范围 · 只改本机配置，不写回网盘")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                checkAllMounts()
            } label: {
                HStack(spacing: 4) {
                    if isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(isChecking ? "检测中" : "检测状态")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: LumaControlMetrics.border)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(cloud.mounts.isEmpty || isChecking)
            .help("逐个拉取存储的根目录，确认凭据与网络是否正常")
            Button {
                store.presentCloudWizard()
            } label: {
                Label("接入存储", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: LumaControlMetrics.border)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("通过向导接入 WebDAV、SMB 共享或网盘")
        }
    }

    /// 与存储卡片同页的跨源总览：不再单独占一个分页。
    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 4)
            CloudStoragesSnapshotPanels()
        }
    }

    var renamePresented: Binding<Bool> {
        Binding(get: { renamingMount != nil },
                set: { if !$0 { renamingMount = nil } })
    }

    /// 还有存储正在检测：页头按钮与每张卡的状态徽章共用同一份状态。
    var isChecking: Bool {
        cloud.mountHealth.values.contains { $0.state == .checking }
    }

    func checkAllMounts() {
        for mount in cloud.mounts {
            probe(mount)
        }
    }

    /// 进入页面时只补测「没测过 / 超过 5 分钟 / 上次失败」的存储。
    func autoCheckMounts() {
        let now = Date()
        for mount in cloud.mounts {
            guard let health = cloud.mountHealth[mount.id] else {
                probe(mount)
                continue
            }
            if health.state == .checking || health.state == .healthy,
               let checkedAt = health.checkedAt,
               now.timeIntervalSince(checkedAt) < 300 {
                continue
            }
            probe(mount)
        }
    }

    /// 检测单个存储：登记到统一任务中心，只拉一次根目录，不改当前浏览目录或索引。
    func probe(_ mount: CloudMount) {
        guard cloud.mountHealth[mount.id]?.state != .checking else { return }
        Task { @MainActor in
            _ = await store.runCloudHealthCheck(mount)
        }
    }

    /// 连通性徽章：与资源页的「在线 / 需验证 / 离线」语义保持一致。
    func healthBadge(_ mount: CloudMount) -> some View {
        let health = cloud.mountHealth[mount.id]
        let state = health?.state ?? .unknown
        let tint: Color
        let text: String
        var showsSpinner = false
        switch state {
        case .checking:
            tint = .secondary
            text = "检测中"
            showsSpinner = true
        case .healthy:
            tint = .green
            text = "在线"
        case .authRequired:
            tint = .orange
            text = "需验证"
        case .offline:
            tint = .red
            text = "离线"
        case .degraded:
            tint = .orange
            text = "受限"
        case .unknown:
            tint = .secondary
            text = "已接入"
        }
        return HStack(spacing: 4) {
            if showsSpinner {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.18), lineWidth: LumaControlMetrics.hairline)
        }
        .help(healthHelp(health))
    }

    func healthHelp(_ health: SourceHealth?) -> String {
        guard let health, health.state != .checking else { return "正在检测连接…" }
        var parts: [String] = []
        if health.state == .healthy {
            parts.append("连通正常")
            if let ms = health.latencyMilliseconds { parts.append("\(ms) ms") }
        } else if health.checkedAt != nil {
            parts.append("检测未通过")
        }
        if let message = health.message, !message.isEmpty { parts.append(message) }
        return parts.isEmpty ? "点击「检测」确认连接" : parts.joined(separator: " · ")
    }

    var safetyNote: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LumaBrand.mint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaBrand.mint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("只读优先，派生数据留在本机")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("除 WebDAV 外均为只读；收藏、关键词、评分、续播与索引都存在当前图库，不会写回网盘。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
        }
        .padding(14)
        .lumaGlassCard(cornerRadius: 16, shadow: false)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LumaBrand.mint.opacity(0.18), lineWidth: 0.7)
        }
    }

    func maintenanceCard(_ mount: CloudMount) -> some View {
        let state = indexStates[mount.id]
        let tint = mount.kind.hubTint

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CloudMountBadge(mount: mount, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mount.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text(address(for: mount))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                healthBadge(mount)
                CloudHubTag(text: mount.kind.supportsWrite ? "可写" : "只读",
                            tint: mount.kind.supportsWrite ? LumaBrand.mint : LumaBrand.violet)
                CloudHubTag(text: mount.kind.title, tint: tint)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                infoCell("鉴权方式", authText(for: mount))
                infoCell("接入范围", scopeText(for: mount))
                infoCell("权限", mount.kind.supportsWrite ? "可写入 WebDAV" : "只读浏览")
                infoCell("索引", indexText(state))
                infoCell("接入时间", DateText.monthFormatter.string(from: mount.createdAt))
            }

            if let deep = store.cloudDeepScanDate(mount.id) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .medium))
                    Text("上次深度扫描 \(CloudHubFormat.relative(deep))")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                CloudHubCapsuleButton(title: "打开", symbol: "arrow.up.right", tint: tint) {
                    store.navigate(to: .cloudMount(mount.id))
                }
                CloudHubCapsuleButton(title: "重新扫描", symbol: "arrow.clockwise", tint: tint) {
                    store.navigate(to: .cloudMount(mount.id))
                    store.refreshCloudDirectory()
                }
                CloudHubCapsuleButton(title: "检测", symbol: "waveform.path.ecg", tint: tint) {
                    probe(mount)
                }
                if mount.kind.supportsAccessScope {
                    CloudHubCapsuleButton(title: "接入范围", symbol: "scope", tint: tint) {
                        store.presentCloudWizard(editing: mount)
                    }
                }
                CloudHubCapsuleButton(title: connectionActionTitle(for: mount),
                                      symbol: "key.horizontal", tint: tint) {
                    if mount.kind == .webdav || mount.kind == .smb {
                        store.presentCloudSheet(mount)
                    } else if mount.kind.supportsInPlaceReauth {
                        // Cookie 型网盘就地更新凭据，保存在同一个挂载上。
                        store.presentCloudReauth(mount)
                    } else {
                        store.presentCloudWizard(flow: mount.kind.wizardFlow)
                    }
                }
                CloudHubCapsuleButton(title: "重命名", symbol: "pencil", tint: tint) {
                    renameText = mount.name
                    renamingMount = mount
                }
                Spacer(minLength: 4)
                Button {
                    store.confirmRemoveCloudMount(mount.id)
                } label: {
                    Text("断开连接")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LumaBrand.coral)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(LumaBrand.coral.opacity(0.10), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 18)
    }

    func infoCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.quaternary)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func authText(for mount: CloudMount) -> String {
        switch mount.kind {
        case .smb, .webdav: return "账号密码"
        case .quark, .pan115: return "浏览器 Cookie"
        case .aliyun: return mount.authMode == .webQR ? "扫码登录" : "浏览器 Cookie"
        case .baidu: return mount.authMode == .oauth ? "OAuth 令牌" : "浏览器 Cookie"
        }
    }

    func scopeText(for mount: CloudMount) -> String {
        var parts: [String] = []
        if mount.scanAll { parts.append("整个共享") }
        if mount.scopeRoots.isEmpty {
            parts.append("整个网盘")
        } else {
            parts.append("\(mount.scopeRoots.count) 个目录")
        }
        if !mount.excludedRoots.isEmpty {
            parts.append("排除 \(mount.excludedRoots.count)")
        }
        return parts.joined(separator: " · ")
    }

    func indexText(_ state: CloudIndexState?) -> String {
        guard let state else { return "尚未建立" }
        let base = "\(state.mediaCount.formatted()) 项 · \(state.folderCount.formatted()) 目录"
        return state.complete ? base : base + " · 未完成"
    }

    func address(for mount: CloudMount) -> String {
        let detail = (mount.baseURL.isEmpty ? mount.lastPath : mount.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "点击进入浏览云端目录" : detail
    }

    func connectionActionTitle(for mount: CloudMount) -> String {
        switch mount.kind {
        case .webdav, .smb: return "编辑连接"
        case .quark, .aliyun, .pan115: return "更新 Cookie"
        case .baidu: return "重新授权"
        }
    }
}
