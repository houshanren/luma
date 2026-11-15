import SwiftUI
import AppKit

// MARK: - SMB 流程

extension CloudSetupWizardView {
    @ViewBuilder
    var smbContent: some View {
        if step == 0 {
            VStack(alignment: .leading, spacing: 14) {
                Text("填写 SMB 连接")
                    .font(.system(size: 13, weight: .semibold))
                Text("群晖：控制面板 → 文件服务 → 启用 SMB。选设备后填入账号密码，可自动列出共享文件夹。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                discoverySection

                labeledField("地址", text: $smbAddress, prompt: "smb://192.168.1.10/photo")
                Text("也可以直接填写 smb://主机/共享名；下方的「发现共享」会读取服务器上的共享列表。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                labeledField("用户名", text: $smbUsername, prompt: "SMB 账号")
                labeledSecureField("密码", text: $smbPassword, prompt: "SMB 密码") {
                    discoverShares()
                }

                HStack(spacing: 10) {
                    Button(isDiscoveringShares ? "发现中…" : "发现共享") {
                        discoverShares()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDiscoveringShares || isBusy
                              || smbAddress.trimmingCharacters(in: .whitespaces).isEmpty
                              || smbUsername.trimmingCharacters(in: .whitespaces).isEmpty
                              || smbPassword.isEmpty)
                    .help("使用当前用户名和密码列出服务器上的共享文件夹")

                    Button(isBusy ? "测试中…" : "测试连接") {
                        testSMB()
                    }
                    .disabled(isBusy || smbAddress.trimmingCharacters(in: .whitespaces).isEmpty)

                    if smbVerified {
                        Label("已连通", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }

                if !availableShares.isEmpty || isDiscoveringShares {
                    shareSection
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("确认并添加")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("接入方式", "SMB 共享")
                    infoRow("地址", smbAddress)
                    infoRow("账号", smbUsername)
                }
                Text("密码保存在 macOS 钥匙串。SMB 挂载为只读：可以浏览与播放，不支持上传、重命名、新建文件夹与删除。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("局域网设备")
                    .font(.system(size: 11.5, weight: .medium))
                if isDiscoveringSMB {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新发现") {
                    startSMBDiscovery()
                }
                .controlSize(.small)
                .disabled(isDiscoveringSMB)
            }
            if discoveredServers.isEmpty {
                Text(isDiscoveringSMB ? "正在发现开启 SMB 的设备…" : "未发现设备，可直接手动填写地址。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(discoveredServers, id: \.self) { server in
                        serverChip(server)
                    }
                }
            }
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("共享文件夹")
                    .font(.system(size: 11.5, weight: .medium))
                if !availableShares.isEmpty {
                    Text("已找到 \(availableShares.count) 个")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if isDiscoveringShares {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新发现") {
                    discoverShares()
                }
                .controlSize(.small)
                .disabled(isDiscoveringShares || isBusy
                          || smbUsername.trimmingCharacters(in: .whitespaces).isEmpty
                          || smbPassword.isEmpty)
                .help("使用当前账号重新读取共享文件夹")
            }
            if availableShares.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(isDiscoveringShares ? "正在读取共享列表…" : "没有可选共享，也可以直接手填 smb://主机/共享名")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                    ForEach(availableShares, id: \.self) { share in
                        shareChip(share)
                    }
                }
                Text("点选共享后会自动填入地址并验证连接。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private func serverChip(_ server: String) -> some View {
        let selected = currentSMBServer?.caseInsensitiveCompare(server) == .orderedSame
        return Button {
            smbAddress = "smb://\(server)/"
            smbVerified = false
            availableShares = []
            if !smbUsername.trimmingCharacters(in: .whitespaces).isEmpty, !smbPassword.isEmpty {
                discoverShares(host: server)
            } else {
                status = "已选择 \(server)，请填写账号密码后点「发现共享」"
                statusIsError = false
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "network")
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(server)
                    .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear,
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("使用 \(server) 作为服务器地址")
    }

    private func shareChip(_ share: String) -> some View {
        let selected = currentSMBShare == share
        return Button {
            applySMBShare(share)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(share)
                    .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear,
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("使用共享「\(share)」")
    }

    // MARK: 动作

    private var currentSMBServer: String? {
        SMBClient.pieces(smbAddress)?.host
    }

    private var currentSMBShare: String? {
        guard let pieces = SMBClient.pieces(smbAddress), !pieces.share.isEmpty else { return nil }
        return pieces.share
    }

    private func discoverShares(host explicitHost: String? = nil) {
        guard !isDiscoveringShares else { return }
        let host: String?
        if let explicitHost {
            host = explicitHost
        } else {
            host = SMBClient.pieces(smbAddress)?.host
        }
        guard let host, !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = "请先选择设备或填写服务器地址"
            statusIsError = true
            return
        }
        guard !smbUsername.trimmingCharacters(in: .whitespaces).isEmpty, !smbPassword.isEmpty else {
            status = "发现共享需要先填写用户名和密码"
            statusIsError = true
            return
        }

        shareDiscoveryToken += 1
        let token = shareDiscoveryToken
        isDiscoveringShares = true
        availableShares = []
        smbVerified = false
        status = "正在使用当前账号发现共享…"
        statusIsError = false
        let account = smbUsername
        let secret = smbPassword

        Task {
            let result = await SMBShareDiscovery.list(host: host,
                                                      username: account,
                                                      password: secret)
            guard token == shareDiscoveryToken else { return }
            isDiscoveringShares = false
            availableShares = result.shares
            status = result.message
            statusIsError = !result.ok
            if result.ok, result.shares.count == 1, let only = result.shares.first {
                applySMBShare(only, host: host)
            }
        }
    }

    private func applySMBShare(_ share: String, host explicitHost: String? = nil) {
        guard let host = explicitHost ?? SMBClient.pieces(smbAddress)?.host else { return }
        // 地址框展示原始名称，编码只在真正挂载时处理。
        let address = "smb://\(host)/\(share)"
        smbAddress = address
        smbVerified = false
        status = "已选择共享「\(share)」，正在验证连接…"
        statusIsError = false
        testSMB(address)
    }

    func startSMBDiscovery() {
        smbDiscoveryTask?.cancel()
        discoveredServers = []
        availableShares = []
        isDiscoveringShares = false
        shareDiscoveryToken += 1
        isDiscoveringSMB = true
        smbDiscoveryTask = Task {
            let servers = await SMBDiscovery.browse()
            guard !Task.isCancelled else { return }
            discoveredServers = servers
            isDiscoveringSMB = false
        }
    }

    func cancelSMBDiscovery() {
        smbDiscoveryTask?.cancel()
        smbDiscoveryTask = nil
        isDiscoveringSMB = false
        availableShares = []
        isDiscoveringShares = false
        shareDiscoveryToken += 1
    }

    private func testSMB(_ addressOverride: String? = nil) {
        let target = addressOverride ?? smbAddress
        // NetFS 只能挂载到具体共享，只有主机时应先让用户选择共享文件夹。
        let share = SMBClient.pieces(target)?.share ?? ""
        if share.isEmpty {
            if smbUsername.trimmingCharacters(in: .whitespaces).isEmpty || smbPassword.isEmpty {
                status = "SMB 地址需要包含共享名，请填写用户名和密码后点「发现共享」"
                statusIsError = true
            } else {
                discoverShares()
            }
            return
        }
        isBusy = true
        smbVerified = false
        status = nil
        let account = smbUsername
        let secret = smbPassword
        Task {
            let result = await SMBClient.test(address: target,
                                              username: account,
                                              password: secret)
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            smbVerified = result.ok
        }
    }

    func addSMB() {
        isBusy = true
        let error = store.saveCloudMount(existing: nil,
                                         name: "",
                                         address: smbAddress,
                                         username: smbUsername,
                                         password: smbPassword,
                                         kind: .smb)
        isBusy = false
        if let error {
            status = error
            statusIsError = true
            return
        }
        close()
    }
}
