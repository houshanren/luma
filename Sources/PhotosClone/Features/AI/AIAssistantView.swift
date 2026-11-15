import SwiftUI
import AppKit

/// 智能助手面板：只读问答、图片理解与检索建议。
struct AIAssistantView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @FocusState private var inputFocused: Bool
    @State private var showClearConfirm = false

    private let suggestions = [
        "这个图库里主要有哪些场景？",
        "帮我找去年海边拍的照片",
        "把这些照片按主题整理成相册",
        "总结当前选中的这些照片"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            composer
        }
        .frame(width: 720, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .confirmationDialog("清空与智能助手的全部对话？", isPresented: $showClearConfirm) {
            Button("清空对话", role: .destructive) {
                store.clearAIConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对话记录保存在当前图库中，清空后无法恢复。")
        }
        .onAppear {
            inputFocused = true
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("智能助手")
                        .font(.system(size: 15, weight: .semibold))
                    Text(store.aiConfig.provider.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    if store.aiConfig.includeImages {
                        Label("图片理解", systemImage: "photo")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Text("当前范围：\(store.sidebarTitle) · \(store.visibleCount.formatted()) 项 · 选中 \(store.selection.count) 张")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Text("模型：\(store.aiConfig.provider.title) / \(store.aiConfig.model)")
                Divider()
                Button("清空对话…", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(store.aiMessages.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("更多")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.aiMessages.isEmpty {
                        emptyState
                    }
                    ForEach(store.aiMessages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if store.aiIsResponding {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在理解当前范围…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .id("ai.responding")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .onChange(of: store.aiMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.aiIsResponding) { _, responding in
                if responding { scrollToBottom(proxy) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可以问我关于当前图库与当前范围的问题。需要整理时，直接说「按主题建相册」或「把这些加入收藏」即可；修改前会弹窗确认。默认只发送元数据与端侧标签，不包含原图。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FlexibleTagLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    Button {
                        store.aiInput = text
                        inputFocused = true
                    } label: {
                        Text(text)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !store.aiHasAPIKey {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .foregroundStyle(Color.accentColor)
                    Text("还没有填写 \(store.aiConfig.provider.title) 的 API Key。")
                        .font(.system(size: 11.5))
                    Spacer(minLength: 8)
                    SettingsLink {
                        Text("打开设置")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func messageRow(_ message: AIChatMessage) -> some View {
        if message.role == .action {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text(message.text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: 460, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .foregroundStyle(message.isError ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !message.photoIDs.isEmpty {
                    photoStrip(message.photoIDs)
                }

                if let suggestion = message.suggestion,
                   (suggestion.keywords?.isEmpty == false) || (suggestion.filter?.isEmpty == false) {
                    suggestionCard(suggestion)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func photoStrip(_ ids: [UUID]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    if let photo = store.anyPhoto(id: id) {
                        VStack(alignment: .leading, spacing: 3) {
                            PhotoThumbnailView(photo: photo, purpose: .cover(72))
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(photo.originalName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 72, alignment: .leading)
                        }
                        .onTapGesture {
                            store.openViewer(id)
                        }
                    }
                }
            }
        }
    }

    private func suggestionCard(_ suggestion: AISearchSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let keywords = suggestion.keywords, !keywords.isEmpty {
                    Text("搜索：\(keywords)")
                        .font(.system(size: 11.5, weight: .medium))
                }
                if let raw = suggestion.filter,
                   let filter = PhotoFilter(rawValue: raw) {
                    Text("筛选：\(filter.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("应用到当前网格") {
                store.applyAISuggestion(suggestion)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - 输入

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = store.aiError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    store.aiConfig.includeImages.toggle()
                    store.saveAIConfig()
                } label: {
                    Image(systemName: store.aiConfig.includeImages ? "photo.fill" : "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(store.aiConfig.includeImages ? Color.accentColor : .secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(store.aiConfig.includeImages
                      ? "已开启图片理解：会发送压缩缩略图，点击关闭"
                      : "开启图片理解：把选中/候选照片压成长边 1024 的 JPEG 发送")

                TextField("问点什么，例如：帮我找去年海边的照片", text: $store.aiInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit {
                        store.sendAIMessage()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                if store.aiIsResponding {
                    Button {
                        store.stopAIResponse()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button {
                        store.sendAIMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("发送")
                }
            }

            HStack(spacing: 6) {
                Text("\(store.aiConfig.provider.title) · \(store.aiConfig.model)")
                Text("·")
                Text(store.aiHasAPIKey ? "Key 已保存在钥匙串" : "未配置 Key")
                if store.aiConfig.includeImages {
                    Text("· 图片理解已开启")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var canSend: Bool {
        !store.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.aiIsResponding
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(settings.motion.layout) {
            if store.aiIsResponding {
                proxy.scrollTo("ai.responding", anchor: .bottom)
            } else if let last = store.aiMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// 简单的流式标签布局，用于推荐问题。
private struct FlexibleTagLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 460
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
