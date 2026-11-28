import SwiftUI
import AppKit

/// 长期记忆管理：跨对话保留的用户偏好，按图库保存，可随时停用或删除。
struct AIMemorySheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Color.accentColor,
                                                    Color.accentColor.opacity(0.62)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("长期记忆")
                        .font(.system(size: 14, weight: .semibold))
                    Text("只保存在当前图库；只作为偏好，不覆盖你当前说的话")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                TextField("例如：按月份建相簿；影院优先整理未识别影片", text: $store.aiMemoryDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...3)
                    .onSubmit { store.addAIMemory(store.aiMemoryDraft) }
                Button {
                    store.addAIMemory(store.aiMemoryDraft)
                } label: {
                    Text("记住")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(store.aiMemoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.aiMemories.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "brain")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("还没有长期记忆")
                                .font(.system(size: 12, weight: .medium))
                            Text("记下你的整理习惯、命名规则或影院偏好，之后每轮都会带上。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    }

                    ForEach($store.aiMemories) { $note in
                        HStack(alignment: .top, spacing: 9) {
                            Toggle("", isOn: $note.isEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .onChange(of: note.isEnabled) { _, _ in
                                    store.persistAIMemory()
                                }
                            TextField("", text: $note.text, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .lineLimit(1...4)
                                .onChange(of: note.text) { _, _ in
                                    store.persistAIMemory()
                                }
                            Button {
                                store.removeAIMemory(note)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.05), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("删除这条记忆")
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .opacity(note.isEnabled ? 1 : 0.55)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

            Divider().opacity(0.5)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("记忆只写当前图库的本地 JSON，不进入对话记录，不参与任何训练。")
                Spacer(minLength: 0)
                Text("\(store.aiMemories.filter(\.isEnabled).count) 条启用")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .frame(width: 560, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(settings.accentColor)
    }
}
