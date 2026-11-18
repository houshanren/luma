import SwiftUI
import AppKit

// MARK: - OAuth 流程（阿里云盘 / 百度网盘）

extension CloudSetupWizardView {
    @ViewBuilder
    func oauthContent(flow: CloudWizardFlow) -> some View {
        switch step {
        case 0:
            oauthCredentialStep(flow: flow)
        case 1:
            oauthAuthorizeStep(flow: flow)
        default:
            oauthFinishStep(flow: flow)
        }
    }

    private func oauthCredentialStep(flow: CloudWizardFlow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. 创建一个 \(flow.title) 开放平台应用")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                bullet("1", "打开 \(flow.title) 开放平台，创建一个「个人工具 / 桌面应用」")
                bullet("2", "把回调地址填成：\(OAuthLoopbackServer.redirectURI)")
                bullet("3", "权限勾选：basic、netdisk")
                bullet("4", "把 AppKey（API Key）/ SecretKey 填到下面，AppID 不要填进 AppKey")
            }

            HStack(spacing: 8) {
                Button("打开开放平台") {
                    open("https://pan.baidu.com/union")
                }
                Button("复制回调地址") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OAuthLoopbackServer.redirectURI, forType: .string)
                }
                Spacer()
            }
            .controlSize(.small)

            Divider()

            labeledField("AppKey", text: $clientID, prompt: "应用的 API Key")
            labeledSecureField("SecretKey", text: $clientSecret, prompt: "应用的 Secret Key")
            labeledField("AppID", text: $clientAppID, prompt: "可选，仅用于 device_id")
            if baiduClientIDLooksLikeAppID {
                Text("当前 AppKey 填的是纯数字，看起来是 AppID。百度授权接口的 client_id 必须使用 AppKey（API Key）。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("凭据只保存在本机 macOS 钥匙串，用于换取和刷新令牌。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func oauthAuthorizeStep(flow: CloudWizardFlow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. 在浏览器中登录并授权")
                .font(.system(size: 13, weight: .semibold))
            labeledField("名称", text: $mountName, prompt: flow.title)

            VStack(alignment: .leading, spacing: 6) {
                infoRow("接入方式", flow.title)
                infoRow("回调地址", OAuthLoopbackServer.redirectURI)
                infoRow(flow == .baidu ? "AppKey" : "AppID", clientID)
                if flow == .baidu, !clientAppID.trimmingCharacters(in: .whitespaces).isEmpty {
                    infoRow("AppID", clientAppID)
                }
            }

            HStack(spacing: 8) {
                if isAuthorizing {
                    Button("取消等待") {
                        OAuthLoopbackServer.shared.cancel()
                        isAuthorizing = false
                        status = "已取消授权"
                        statusIsError = true
                    }
                } else {
                    Button(isBusy ? "处理中…" : "打开浏览器授权") {
                        startOAuth(flow: flow)
                    }
                    .disabled(isBusy)
                }
                Button(showManualCode ? "收起手动粘贴" : "回调打不开？手动粘贴授权码") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showManualCode.toggle()
                    }
                }
                .controlSize(.small)
                Spacer()
            }

            if showManualCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("如果浏览器提示无法访问 127.0.0.1，从地址栏复制 code= 后面的值粘贴到下面。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("授权码", text: $manualCode)
                            .textFieldStyle(.roundedBorder)
                        Button("提交授权码") {
                            submitManualCode(flow: flow)
                        }
                        .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            Text("授权页会打开系统默认浏览器；登录完成后会自动回跳，无需手动操作。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func oauthFinishStep(flow: CloudWizardFlow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("3. 完成")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(flow.title) 已连接，可以直接浏览与播放。")
                    .font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                infoRow("缩略图", "服务端生成，浏览大目录不会下载原图")
                infoRow("视频", "官方直链流式播放")
                infoRow("写操作", "当前为只读；上传/删除请到网盘 App")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text("在侧边栏「网络存储」中可以找到新的挂载点；右击可重新授权或断开连接。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 动作

    private var baiduClientIDLooksLikeAppID: Bool {
        let value = clientID.trimmingCharacters(in: .whitespaces)
        return !value.isEmpty && value.allSatisfy(\.isNumber)
    }

    private func currentCredentials(flow: CloudWizardFlow) -> CloudClientCredentials {
        CloudClientCredentials(clientID: clientID.trimmingCharacters(in: .whitespaces),
                               clientSecret: clientSecret.trimmingCharacters(in: .whitespaces),
                               appID: flow == .baidu ? clientAppID.trimmingCharacters(in: .whitespaces) : nil)
    }

    func saveCredentials(flow: CloudWizardFlow) {
        guard let kind = flow.kind else { return }
        let credentials = currentCredentials(flow: flow)
        CloudOAuthStore.saveCredentials(credentials, for: kind)
        status = "已保存应用凭据"
        statusIsError = false
        step = 1
    }

    private func startOAuth(flow: CloudWizardFlow) {
        guard let kind = flow.kind, !isAuthorizing else { return }
        let credentials = currentCredentials(flow: flow)
        CloudOAuthStore.saveCredentials(credentials, for: kind)

        let state = UUID().uuidString
        let redirect = OAuthLoopbackServer.redirectURI
        var url: URL?
        switch kind {
        case .baidu:
            url = BaiduOAuth.authorizeURL(clientID: credentials.clientID,
                                          appID: credentials.appID,
                                          redirectURI: redirect,
                                          state: state)
        case .webdav, .smb, .quark, .aliyun:
            url = nil
        }
        guard let url else {
            status = "授权地址生成失败"
            statusIsError = true
            return
        }

        isAuthorizing = true
        status = "已打开浏览器，请在页面中完成登录与授权…"
        statusIsError = false

        Task {
            async let codeResult = OAuthLoopbackServer.shared.waitForCode(state: state)
            try? await Task.sleep(nanoseconds: 250_000_000)
            NSWorkspace.shared.open(url)
            do {
                let code = try await codeResult
                try await completeAuthorization(kind: kind,
                                                code: code,
                                                redirectURI: redirect,
                                                clientID: credentials.clientID,
                                                clientSecret: credentials.clientSecret)
            } catch {
                isAuthorizing = false
                status = error.localizedDescription
                statusIsError = true
            }
        }
    }

    private func submitManualCode(flow: CloudWizardFlow) {
        guard let kind = flow.kind else { return }
        let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isBusy = true
        status = "正在用授权码换取令牌…"
        statusIsError = false
        Task {
            do {
                try await completeAuthorization(kind: kind,
                                                code: code,
                                                redirectURI: OAuthLoopbackServer.redirectURI,
                                                clientID: clientID.trimmingCharacters(in: .whitespaces),
                                                clientSecret: clientSecret.trimmingCharacters(in: .whitespaces))
            } catch {
                status = error.localizedDescription
                statusIsError = true
            }
            isBusy = false
        }
    }

    private func completeAuthorization(kind: CloudKind, code: String, redirectURI: String,
                                       clientID: String, clientSecret: String) async throws {
        isBusy = true
        defer { isBusy = false }

        let token: CloudToken
        let name: String
        let trimmedName = mountName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .baidu:
            token = try await BaiduOAuth.exchange(clientID: clientID,
                                                  clientSecret: clientSecret,
                                                  code: code,
                                                  redirectURI: redirectURI)
            name = trimmedName.isEmpty ? "百度网盘" : trimmedName
        case .webdav, .smb, .quark, .aliyun:
            throw CloudOAuthError.unsupportedProvider
        }

        if let error = store.registerOAuthMount(kind: kind,
                                                name: name,
                                                driveID: nil,
                                                token: token) {
            throw CloudOAuthError.api(error)
        }
        isAuthorizing = false
        status = "授权成功，已添加「\(name)」"
        statusIsError = false
        step = 2
    }
}
