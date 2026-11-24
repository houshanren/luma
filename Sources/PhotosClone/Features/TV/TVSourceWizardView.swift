import SwiftUI
import LumaContentCore

/// 导入一个自定义电视源：填名称 / M3U 地址 / 地区，保存前先真正拉一次验证。
struct TVSourceWizardView: View {
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlString = ""
    @State private var region: TVRegion = .mainland
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导入电视源")
                    .font(.system(size: 15, weight: .semibold))
                Text("支持 M3U / M3U8 播放列表地址。保存前会先拉取一次，确认能解析出频道。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("名称", text: $name, prompt: Text("例如：我的央视源"))
                TextField("M3U 地址", text: $urlString, prompt: Text("https://example.com/list.m3u"))
                Picker("地区", selection: $region) {
                    ForEach(TVRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(TVBrand.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("正在验证地址并解析频道…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var canSave: Bool {
        !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let playlist = try await tv.addPlaylist(name: name, urlString: urlString, region: region)
                tv.focusPlaylist(playlist.id)
                tv.setHubTab(.channels)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = (error as? SourceError)?.message ?? error.localizedDescription
            }
        }
    }
}
