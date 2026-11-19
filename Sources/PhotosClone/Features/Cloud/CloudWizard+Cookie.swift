import SwiftUI
import AppKit

// MARK: - 浏览器 Cookie 流程（阿里云盘 / 夸克网盘）

extension CloudSetupWizardView {
    @ViewBuilder
    var cookieContent: some View {
        if step == 0 {
            cookieInputStep
        } else {
            cookieConfirmStep
        }
    }

    private var isAliyunCookie: Bool { flow == .aliyunCookie }
    private var cookieProviderName: String { isAliyunCookie ? "阿里云盘" : "夸克网盘" }

    private var cookieInputStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. 从浏览器复制\(cookieProviderName)登录凭据")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                if isAliyunCookie {
                    bullet("1", "打开阿里云盘令牌工具（AList 提供，扫码授权即可，不需要开发者资质）")
                    bullet("2", "用阿里云盘手机 App 扫码并在手机上确认授权")
                    bullet("3", "页面会显示 refresh_token=…，复制整行（令牌以 eyJ 开头）")
                    bullet("4", "粘贴到下面测试；网页 localStorage 里的 token 不能用，网页令牌会被开放平台接口拒绝")
                } else {
                    bullet("1", "用 Chrome / Edge / Safari 打开并登录 pan.quark.cn")
                    bullet("2", "按 ⌥⌘I 打开开发者工具，切到「网络」，刷新页面")
                    bullet("3", "点任意一条请求，在「请求标头」里找到 Cookie，整段复制")
                    bullet("4", "粘贴到下面，点「测试 Cookie」；通过后即可添加")
                }
            }

            HStack(spacing: 8) {
                Button(isAliyunCookie ? "打开令牌工具" : "打开夸克网盘") {
                    open(isAliyunCookie ? "https://alist.nn.ci/tool/aliyundrive/request"
                                        : "https://pan.quark.cn")
                }
                Button("从剪贴板粘贴") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        cookieText = text
                    }
                }
                Spacer()
            }
            .controlSize(.small)

            Divider()

            TextEditor(text: $cookieText)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10))
                }
                .onChange(of: cookieText) { _, _ in
                    cookieVerified = false
                }

            HStack(spacing: 8) {
                Button(isBusy ? "测试中…" : (isAliyunCookie ? "测试凭据" : "测试 Cookie")) {
                    testCookie()
                }
                .disabled(isBusy || cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if cookieVerified {
                    Label("已连通", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Spacer()
                if isAliyunCookie {
                    Text(AliyunCookieAuth.extractRefreshToken(cookieText) == nil
                         ? "未识别到 refresh_token（应以 eyJ 开头）"
                         : "已识别 refresh_token")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AliyunCookieAuth.extractRefreshToken(cookieText) == nil
                                         ? Color.orange : Color.green)
                } else {
                    Text("\(QuarkDrive.normalizedCookie(cookieText).count) 字符")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("凭据只保存在本机 macOS 钥匙串；过期后（提示需要登录）重新复制一次即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cookieConfirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认并添加")
                .font(.system(size: 13, weight: .semibold))
            labeledField("名称", text: $mountName, prompt: cookieProviderName)
            VStack(alignment: .leading, spacing: 6) {
                infoRow("接入方式", isAliyunCookie ? "阿里云盘（Cookie / 令牌）" : "夸克网盘（Cookie）")
                if isAliyunCookie {
                    infoRow("登录凭据", "refresh_token，已保存到钥匙串")
                    infoRow("令牌", "过期后自动用 refresh_token 续期")
                } else {
                    infoRow("Cookie", "已保存 \(QuarkDrive.normalizedCookie(cookieText).count) 字符")
                }
                infoRow("浏览范围", "整个网盘；支持「相册」与「文件夹」两种视图")
                infoRow("视频", isAliyunCookie ? "优先官方转码，失败时走直链" : "官方直链流式播放")
                infoRow("写操作", "当前为只读；上传/删除请到网盘 App")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            Text("添加后可在侧边栏「网络存储」找到它；右击可更新 Cookie 或断开连接。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 动作

    private func testCookie() {
        isBusy = true
        cookieVerified = false
        status = nil
        let text = cookieText
        let aliyun = isAliyunCookie
        Task {
            let result: (ok: Bool, message: String)
            if aliyun {
                result = await store.testAliyunCookie(text)
            } else {
                result = await store.testQuarkCookie(text)
            }
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            cookieVerified = result.ok
        }
    }

    func addQuark() {
        if let error = store.registerQuarkMount(cookie: cookieText, name: mountName) {
            status = error
            statusIsError = true
            return
        }
        close()
    }

    func addAliyunCookie() {
        guard !isBusy else { return }
        isBusy = true
        status = "正在验证并保存…"
        statusIsError = false
        let text = cookieText
        Task {
            let error = await store.registerAliyunCookieMount(input: text, name: mountName)
            isBusy = false
            if let error {
                status = error
                statusIsError = true
            } else {
                close()
            }
        }
    }
}
