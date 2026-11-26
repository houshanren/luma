import SwiftUI
import AppKit

/// Cookie / 令牌失效后的原地重新登录：
/// 直接在当前窗口粘贴新的凭据，校验通过后写回这个挂载并立刻刷新，
/// 不新建挂载、不改接入范围，也不会动已扫描的内容。
struct CloudCookieReauthView: View {
    @Environment(LibraryStore.self) private var store
    let mount: CloudMount

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var status: String?
    @State private var statusIsError = false

    private var kind: CloudKind { mount.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            steps
            actionRow
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10))
                }
                .onChange(of: text) { _, _ in
                    if statusIsError {
                        status = nil
                        statusIsError = false
                    }
                }
            footer
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { prefillFromClipboardIfCredential() }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let brand = kind.brand {
                CloudBrandIcon(brand: brand, size: 34)
            } else {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("重新登录「\(mount.name)」")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(kind.title)的登录已失效。系统会写回服务端轮换过的 Cookie；整段登录过期时才需要在这里重新粘贴一次。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 步骤

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stepTexts.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Color.accentColor, in: Circle())
                    Text(step)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    private var stepTexts: [String] {
        switch kind {
        case .quark:
            return [
                "用浏览器打开并登录 pan.quark.cn",
                "按 ⌥⌘I 打开开发者工具，切到「网络」并刷新页面",
                "点任意一条请求，在「请求标头」里找到 Cookie，整段复制",
                "粘贴到下面，点「保存并刷新」"
            ]
        case .pan115:
            return [
                "用浏览器打开并登录 115.com",
                "按 ⌥⌘I 打开开发者工具，切到「网络」并刷新页面",
                "点任意一条请求，整段复制「请求标头」里的 Cookie（需包含 UID / CID / SEID / KID）",
                "粘贴到下面，点「保存并刷新」"
            ]
        case .aliyun:
            return [
                "打开阿里云盘令牌工具（AList 提供，不需要开发者资质）",
                "用阿里云盘手机 App 扫码并在手机上确认授权",
                "复制页面上的 refresh_token（以 eyJ 开头）",
                "粘贴到下面，点「保存并刷新」"
            ]
        case .baidu, .webdav, .smb:
            return ["该接入方式不支持原地重新登录"]
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(siteTitle) { openSite() }
            Button("从剪贴板粘贴") { pasteFromClipboard() }
            Spacer()
            if busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在验证…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .controlSize(.small)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(statusIsError ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("凭据只保存在本机 macOS 钥匙串；接入范围与已扫描内容都不受影响。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("取消") { dismiss() }
                Button(busy ? "正在验证…" : "保存并刷新") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - 动作

    private var siteTitle: String {
        switch kind {
        case .quark: return "打开夸克网盘"
        case .pan115: return "打开 115 网盘"
        case .aliyun: return "打开令牌工具"
        case .baidu, .webdav, .smb: return "打开网页"
        }
    }

    private var siteURL: String {
        switch kind {
        case .quark: return "https://pan.quark.cn"
        case .pan115: return "https://115.com"
        case .aliyun: return "https://alist.nn.ci/tool/aliyundrive/request"
        case .baidu: return "https://pan.baidu.com"
        case .webdav, .smb: return ""
        }
    }

    private func openSite() {
        guard let address = URL(string: siteURL) else { return }
        NSWorkspace.shared.open(address)
    }

    private func pasteFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        text = value
    }

    /// 剪贴板里明显是刚复制的登录凭据时直接带入，省掉一次手动粘贴。
    private func prefillFromClipboardIfCredential() {
        guard text.isEmpty,
              let value = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeCookie = trimmed.count > 20
            && (trimmed.contains("UID=") || trimmed.contains("__puus=")
                || trimmed.contains("__pus=") || trimmed.hasPrefix("Cookie:"))
        let looksLikeToken = trimmed.hasPrefix("eyJ") && trimmed.count > 40
        guard looksLikeCookie || looksLikeToken else { return }
        text = trimmed
    }

    private func save() {
        guard !busy else { return }
        let input = text
        busy = true
        status = "正在验证并保存…"
        statusIsError = false
        Task {
            let error = await store.reauthorizeCloudMount(mount, credential: input)
            busy = false
            if let error {
                status = error
                statusIsError = true
                return
            }
            status = "已保存，正在刷新…"
            store.finishCloudReauth(mount)
        }
    }
}
