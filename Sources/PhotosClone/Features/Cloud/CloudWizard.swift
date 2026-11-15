import SwiftUI
import AppKit

// MARK: - 统一接入向导
//
// 根视图只负责流程选择、步骤切换与底部动作；各接入方式的步骤视图与动作
// 按类型拆到 CloudWizard+OAuth / +SMB / +WebDAV / +AList 中。

struct CloudSetupWizardView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var cloud: CloudBrowserModel

    @State var flow: CloudWizardFlow?
    @State var step = 0

    // OAuth
    @State var clientID = ""
    @State var clientSecret = ""
    @State var isBusy = false
    @State var isAuthorizing = false
    @State var showManualCode = false
    @State var manualCode = ""

    // SMB / WebDAV
    @State var address = ""
    @State var username = ""
    @State var password = ""
    @State var networkVerified = false
    @State var smbAddress = ""
    @State var smbUsername = ""
    @State var smbPassword = ""
    @State var smbVerified = false
    @State var discoveredServers: [String] = []
    @State var isDiscoveringSMB = false
    @State var smbDiscoveryTask: Task<Void, Never>?
    @State var availableShares: [String] = []
    @State var isDiscoveringShares = false
    @State var shareDiscoveryToken = 0
    /// 复用了哪一条已保存 SMB 连接的账号（用于界面提示）。
    @State var reusedSMBMountName: String?
    /// 双击共享后进入的目录浏览状态（第二层及更深）。
    @State var smbBrowseHost: String?
    @State var smbBrowseShare: String?
    @State var smbBrowsePath = ""
    @State var smbBrowseFolders: [String] = []
    @State var isLoadingBrowseFolders = false
    @State var browseFoldersError: String?
    @State var browseToken = 0

    // AList
    @State var alistProvider: AlistProvider = .aliyun
    @State var alistAddress = "http://127.0.0.1:5244"
    @State var alistUser = "admin"
    @State var alistPassword = ""
    @State var alistVerified = false
    @State var addedInAlist = false

    // 状态
    @State var status: String?
    @State var statusIsError = false

    private var isLastStep: Bool {
        guard let flow else { return false }
        return step >= flow.steps.count - 1
    }

    private var canContinue: Bool {
        guard let flow else { return false }
        switch flow {
        case .aliyun, .baidu:
            if step == 0 {
                return !clientID.trimmingCharacters(in: .whitespaces).isEmpty
                    && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        case .smb:
            return step == 0 ? smbVerified : true
        case .webdav:
            return step == 0 ? networkVerified : true
        case .alist:
            switch step {
            case 1: return alistVerified
            case 2: return addedInAlist
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if let status {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(statusIsError ? Color.red : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 680)
        .onAppear {
            if let initial = cloud.wizardInitialFlow {
                cloud.wizardInitialFlow = nil
                select(initial)
            }
        }
        .onDisappear {
            cancelSMBDiscovery()
            OAuthLoopbackServer.shared.cancel()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("网盘接入向导")
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let flow {
                Text("第 \(step + 1) / \(flow.steps.count) 步 · \(flow.steps[step])")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        guard let flow else {
            return "统一入口：官方 OAuth、SMB、WebDAV、AList 聚合"
        }
        switch flow {
        case .aliyun, .baidu:
            return "首次需要在开放平台创建一个应用，之后只需在浏览器登录"
        case .smb:
            return "群晖 / TrueNAS / Windows 共享，只读浏览"
        case .webdav:
            return "群晖 / TrueNAS / 任意 WebDAV 服务"
        case .alist:
            return "不需要开发者资质，由 AList 完成各网盘授权"
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let flow {
            switch flow {
            case .aliyun, .baidu:
                oauthContent(flow: flow)
            case .smb:
                smbContent
            case .webdav:
                webdavContent
            case .alist:
                alistContent
            }
        } else {
            flowSelection
        }
    }

    private var flowSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择接入方式")
                .font(.system(size: 13, weight: .semibold))
            Text("官方 OAuth 体验最好（服务端缩略图、转码播放），但需要一次性创建应用；SMB、WebDAV 与 AList 不需要。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(CloudWizardFlow.allCases) { item in
                    Button {
                        select(item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 20))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(item.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(height: 74)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.primary.opacity(0.05))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if flow != nil {
                Button(step == 0 ? "返回" : "上一步") {
                    back()
                }
            }
            Spacer()
            Button("取消") { close() }
                .keyboardShortcut(.cancelAction)

            if let flow {
                if isLastStep {
                    Button(primaryTitle(flow)) {
                        primaryAction(flow)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue || isBusy)
                } else if flow.requiresDeveloperApp {
                    if step == 0 {
                        Button("保存并继续") {
                            saveCredentials(flow: flow)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                    }
                } else {
                    Button("下一步") {
                        step += 1
                        status = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func primaryTitle(_ flow: CloudWizardFlow) -> String {
        switch flow {
        case .aliyun, .baidu: return "完成"
        case .smb, .webdav: return "添加"
        case .alist: return "测试并添加"
        }
    }

    private func primaryAction(_ flow: CloudWizardFlow) {
        switch flow {
        case .aliyun, .baidu:
            close()
        case .smb:
            addSMB()
        case .webdav:
            addWebDAV()
        case .alist:
            addAList()
        }
    }

    // MARK: 流程切换

    private func select(_ flow: CloudWizardFlow) {
        self.flow = flow
        step = 0
        status = nil
        statusIsError = false
        networkVerified = false
        smbVerified = false
        if flow == .smb {
            // 已有 SMB 连接时复用账号与钥匙串密码，不必再输一次。
            prefillSMBAccount()
            startSMBDiscovery()
            if let host = SMBClient.pieces(smbAddress)?.host, !host.isEmpty,
               !smbUsername.trimmingCharacters(in: .whitespaces).isEmpty,
               !smbPassword.isEmpty {
                // 账号齐全就直接列出共享，省去再点「发现共享」。
                discoverShares(host: host)
            }
        } else {
            cancelSMBDiscovery()
        }
        if let kind = flow.kind, let saved = CloudOAuthStore.credentials(for: kind) {
            clientID = saved.clientID
            clientSecret = saved.clientSecret
        }
    }

    private func back() {
        status = nil
        if step > 0 {
            step -= 1
        } else {
            flow = nil
            cancelSMBDiscovery()
            if isAuthorizing {
                OAuthLoopbackServer.shared.cancel()
                isAuthorizing = false
            }
        }
    }

    func close() {
        cancelSMBDiscovery()
        if isAuthorizing {
            OAuthLoopbackServer.shared.cancel()
            isAuthorizing = false
        }
        cloud.showWizard = false
    }

    // MARK: 通用组件

    func bullet(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func labeledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    func labeledSecureField(_ label: String, text: Binding<String>, prompt: String,
                            onSubmit: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit?() }
        }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func open(_ raw: String) {
        if let url = URL(string: raw), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let url = WebDAVClient.normalizedBaseURL(raw) {
            NSWorkspace.shared.open(url)
        }
    }
}
