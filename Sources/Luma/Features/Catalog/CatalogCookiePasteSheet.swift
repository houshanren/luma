import AppKit
import SwiftUI

/// 粘贴 Cookie：Wuso / V2PH 这类站点在应用内登录会被风控或 Cloudflare 拦下，
/// 统一改为「浏览器登录 → 复制 Cookie → 粘到这里」。
/// 保存后浏览会带上这份登录态；快过期时自动续期会在后台带着它重新访问站点。
struct CatalogCookiePasteSheet: View {
    let source: CatalogSource
    let onSave: (_ cookie: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// 点击「验证」后的结果：用这份 Cookie 真发一次请求看站点是否认登录态。
    @State private var verification: CatalogCookieVerification?
    @State private var isVerifying = false
    @FocusState private var editorFocused: Bool

    private var canSave: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // 先验证再保存：游客 Cookie 也能存进去，但存了等于没登录。
        if case .success? = verification { return true }
        return false
    }

    /// 用当前粘贴的内容发一次请求，确认站点是否认出登录态。
    private func verify() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isVerifying else { return }
        let candidate = text
        verification = nil
        isVerifying = true
        Task {
            let result = await CatalogCookieVerifier.verify(source: source, cookie: candidate)
            isVerifying = false
            verification = result
        }
    }

    private var browserURL: URL? {
        URL(string: source.baseURL) ?? URL(string: "https://\(source.host)")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    steps
                    editor
                    status
                    verificationResult
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 540)
        .onAppear {
            text = source.cookie ?? ""
            editorFocused = true
        }
        // Cookie 改了就作废上一次验证结果，避免拿旧结果去保存新内容。
        .onChange(of: text) { _, _ in verification = nil }
    }

    /// 验证结果：成功说明站点已认出登录态，失败给出具体原因。
    @ViewBuilder
    private var verificationResult: some View {
        if isVerifying {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在用这份 Cookie 访问站点…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if let verification {
            switch verification {
            case .success(let message):
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(LumaBrand.mint)
            case .failure(let message):
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LumaBrand.violet)
                .frame(width: 30, height: 30)
                .background(LumaBrand.violet.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("粘贴 Cookie")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(source.name) · \(source.host)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if let url = browserURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("在浏览器打开", systemImage: "safari")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LumaBrand.violet)
            Button {
                dismiss()
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

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "在浏览器里登录 \(source.name)",
                 "用上面「在浏览器打开」进入站点并完成登录，保持登录状态。")
            step(2, "复制 Cookie",
                 "按 ⌥⌘I 打开开发者工具的「网络」，刷新页面后点任一请求，"
                 + "在请求头里复制 Cookie 一整行。")
            step(3, "验证并保存",
                 "贴到下面点「验证」，站点认出登录态后再点「保存」；之后浏览与自动续期都用这份 Cookie。")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func step(_ index: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(LumaBrand.violet)
                .frame(width: 16, height: 16)
                .background(LumaBrand.violet.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Cookie")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 130)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
            Text("支持直接粘贴 `Cookie: a=b; c=d` 或整段多行内容，保存时会自动整理成请求头格式。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch source.cookieState {
        case .valid: return LumaBrand.mint
        case .expiringSoon: return LumaBrand.amber
        case .expired, .missing: return .orange
        case .notRequired: return .secondary.opacity(0.4)
        }
    }

    private var statusText: String {
        switch source.cookieState {
        case .notRequired:
            return "该站点不需要登录。"
        case .missing:
            return "当前未保存 Cookie。"
        case .valid:
            if let date = source.cookieExpiresAt {
                return "当前 Cookie 有效，预计 \(date.formatted(.dateTime.month().day().hour().minute())) 失效。"
            }
            return "当前已保存 Cookie。"
        case .expiringSoon:
            if let date = source.cookieExpiresAt {
                return "当前 Cookie 预计 \(date.formatted(.dateTime.month().day().hour().minute())) 失效。"
            }
            return "当前 Cookie 快过期了。"
        case .expired:
            return "当前 Cookie 已过期，请重新从浏览器复制。"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button {
                verify()
            } label: {
                if isVerifying {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("验证中…")
                    }
                } else {
                    Text("验证")
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") {
                onSave(text)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footerHint: String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请先粘贴 Cookie。"
        }
        switch verification {
        case .success?:
            return "保存后立即按新登录态重新读取。"
        case .failure?:
            return "验证未通过，请按提示重新复制 Cookie。"
        case nil:
            return isVerifying ? "正在验证这份 Cookie…" : "先点「验证」确认站点认这份 Cookie。"
        }
    }
}
