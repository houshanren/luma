import SwiftUI
import AppKit

// MARK: - WebDAV 流程

extension CloudSetupWizardView {
    @ViewBuilder
    var webdavContent: some View {
        if step == 0 {
            VStack(alignment: .leading, spacing: 14) {
                Text("填写 WebDAV 连接")
                    .font(.system(size: 13, weight: .semibold))
                Text("群晖：套件中心安装 WebDAV Server，地址填 http://NAS地址:5005/photo（HTTPS 为 5006）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                labeledField("地址", text: $address, prompt: "http://192.168.1.10:5005/photo")
                labeledField("用户名", text: $username, prompt: "WebDAV 账号")
                labeledSecureField("密码", text: $password, prompt: "WebDAV 密码")

                HStack(spacing: 8) {
                    Button(isBusy ? "测试中…" : "测试连接") {
                        testWebDAV()
                    }
                    .disabled(isBusy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    if networkVerified {
                        Label("已连通", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("确认并添加")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("接入方式", "WebDAV")
                    infoRow("地址", address)
                    infoRow("账号", username)
                }
                Text("密码保存在 macOS 钥匙串。WebDAV 支持上传、重命名、新建文件夹与删除。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 动作

    private func testWebDAV() {
        isBusy = true
        networkVerified = false
        status = nil
        let target = address
        let account = username
        let secret = password
        Task {
            let result = await store.testCloudConnection(address: target,
                                                         username: account,
                                                         password: secret)
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            networkVerified = result.ok
        }
    }

    func addWebDAV() {
        isBusy = true
        let name = URL(string: address)?.host ?? "WebDAV"
        let error = store.saveCloudMount(existing: nil,
                                         name: name,
                                         address: address,
                                         username: username,
                                         password: password)
        isBusy = false
        if let error {
            status = error
            statusIsError = true
            return
        }
        close()
    }
}
