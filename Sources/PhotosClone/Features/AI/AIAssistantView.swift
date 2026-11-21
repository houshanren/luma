import SwiftUI
import AppKit

/// 智能助手面板：问答、图片理解、检索建议与图库工具操作。
struct AIAssistantView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @FocusState private var inputFocused: Bool
    @State private var showClearConfirm = false
    @State private var hoveredID: String?
    @State private var appeared = false

    /// 能力分区：与工具体系一一对应，点示例即可直接提问。
    private struct Capability: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let examples: [String]
    }

    /// 首页主推案例：直接对应真实可执行的操作。
    private struct CaseCard: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let prompt: String
    }

    private let cases: [CaseCard] = [
        CaseCard(id: "compress", icon: "arrow.down.right.and.arrow.up.left",
                 title: "压缩这组照片",
                 detail: "有损可调画质与长边，无损保持像素与尺寸；只有更小才替换。",
                 prompt: "把这 3 张照片压到长边 2048、质量 80"),
        CaseCard(id: "album", icon: "calendar.badge.clock",
                 title: "按时间地点建相簿",
                 detail: "从拍摄时间与地点里找出去年在上海的照片，一次归组。",
                 prompt: "把去年在上海拍的照片整理成相簿")
    ]

    private let capabilities: [Capability] = [
        Capability(id: "browse", icon: "magnifyingglass",
                   title: "检索与浏览",
                   subtitle: "关键词 · 时间 · 地点 · 场景",
                   examples: ["找去年海边的照片", "切换到视频"]),
        Capability(id: "album", icon: "rectangle.stack",
                   title: "相簿与文件夹",
                   subtitle: "建相簿 · 归组 · 改封面",
                   examples: ["按主题建 4 个相簿", "新建「2025」文件夹"]),
        Capability(id: "photo", icon: "photo.on.rectangle.angled",
                   title: "图片",
                   subtitle: "收藏 · 关键词 · 压缩 · 美化",
                   examples: ["收藏这 3 张", "无损压缩这些照片"]),
        Capability(id: "video", icon: "video",
                   title: "视频",
                   subtitle: "找视频 · 收藏 · 归组",
                   examples: ["有哪些视频", "把视频放进「旅行」"]),
        Capability(id: "catalog", icon: "play.rectangle.on.rectangle",
                   title: "网络资源",
                   subtitle: "跨源搜索 · 播放 · 稍后看",
                   examples: ["搜一下并播放第一条", "把今天新片加入稍后看"])
    ]

    private let quickExamples = ["压缩选中照片", "自动美化这组", "找去年在上海的照片", "按主题整理相簿", "网络资源搜一下今天的更新"]

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                divider
                messageList
                divider
                composer
            }
        }
        .frame(width: 760, height: 700)
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
            withAnimation(settings.motion.overlay) { appeared = true }
        }
    }

    // MARK: - 背景

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           startPoint: .topLeading, endPoint: .center)
            RadialGradient(colors: [Color.accentColor.opacity(0.07), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    private var divider: some View {
        Divider().opacity(0.55)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color.accentColor,
                                                Color.accentColor.opacity(0.62)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 9, y: 3)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("智能助手")
                        .font(.system(size: 15, weight: .semibold))
                    badge(store.aiConfig.provider.title)
                    badge("\(AILibraryTools.count) 项能力", accent: true)
                        .help("共 \(AILibraryTools.count) 项本地工具：照片检索与整理、影院刮削、网络资源搜索与播放；修改前会弹窗确认")
                    if store.aiConfig.includeImages {
                        badge("图片理解", icon: "photo")
                    }
                }
                HStack(spacing: 6) {
                    Text(store.sidebarTitle)
                    Text("·")
                    Text("\(store.visibleCount.formatted()) 项")
                    Text("·")
                    Text("选中 \(store.selection.count)")
                }
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("更多")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private func badge(_ text: String, icon: String? = nil, accent: Bool = false) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(accent ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(accent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                    in: Capsule())
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.aiMessages.isEmpty {
                        welcome
                    }
                    ForEach(store.aiMessages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if store.aiIsResponding {
                        thinkingRow
                            .id("ai.responding")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .onChange(of: store.aiMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.aiIsResponding) { _, responding in
                if responding { scrollToBottom(proxy) }
            }
        }
    }

    // MARK: - 欢迎页

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("把想法说出来，剩下的交给我。")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.primary, Color.accentColor],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                Text("检索、整理相簿与文件夹、收藏与关键词、压缩与美化图片，以及跨源搜索和播放网络资源，都能直接执行；修改前会弹窗确认。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 10) {
                ForEach(cases) { item in
                    caseCard(item)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                ForEach(capabilities) { capability in
                    capabilityCard(capability)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("默认只发送元数据与端侧标签，不包含原图；Key 保存在钥匙串。")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

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
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }

    private func caseCard(_ item: CaseCard) -> some View {
        let hovered = hoveredID == item.id
        return Button {
            insert(item.prompt)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(hovered ? 0.22 : 0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 8))
                    Text(item.prompt)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.075 : 0.04),
                        in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(hovered ? 0.30 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? item.id : nil
            }
        }
        .help("填入输入框")
    }

    private func capabilityCard(_ capability: Capability) -> some View {
        let hovered = hoveredID == capability.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(hovered ? 0.20 : 0.13))
                        .frame(width: 26, height: 26)
                    Image(systemName: capability.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(capability.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(capability.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            FlexibleTagLayout(spacing: 5) {
                ForEach(capability.examples, id: \.self) { example in
                    Button {
                        insert(example)
                    } label: {
                        Text(example)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("填入输入框")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(hovered ? 0.075 : 0.045),
                    in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(hovered ? 0.25 : 0), lineWidth: 1)
        )
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? capability.id : nil
            }
        }
    }

    // MARK: - 消息行

    @ViewBuilder
    private func messageRow(_ message: AIChatMessage) -> some View {
        switch message.role {
        case .user:
            userRow(message)
        case .action:
            actionRow(message)
        case .assistant:
            assistantRow(message)
        }
    }

    private func userRow(_ message: AIChatMessage) -> some View {
        HStack {
            Spacer(minLength: 70)
            Text(message.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(colors: [Color.accentColor.opacity(0.24),
                                            Color.accentColor.opacity(0.13)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: 480, alignment: .trailing)
        }
    }

    private func assistantRow(_ message: AIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 9) {
            miniAvatar(tint: message.isError ? .red : Color.accentColor,
                       icon: message.isError ? "exclamationmark" : "sparkles")

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

    private func actionRow(_ message: AIChatMessage) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.16))
                    .frame(width: 20, height: 20)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
            }
            Text(message.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text("已执行")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.green.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    private var thinkingRow: some View {
        HStack(alignment: .top, spacing: 9) {
            miniAvatar(tint: Color.accentColor, icon: "sparkles")
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("正在理解当前范围…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func miniAvatar(tint: Color, icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 22, height: 22)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
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
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 输入

    private var composer: some View {
        VStack(spacing: 9) {
            if let error = store.aiError {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text(error)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if !store.aiMessages.isEmpty, !store.aiIsResponding {
                quickCommands
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    store.aiConfig.includeImages.toggle()
                    store.saveAIConfig()
                } label: {
                    Image(systemName: store.aiConfig.includeImages ? "photo.fill" : "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(store.aiConfig.includeImages ? Color.accentColor : .secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help(store.aiConfig.includeImages
                      ? "已开启图片理解：会发送压缩缩略图，点击关闭"
                      : "开启图片理解：把选中/候选照片压成长边 1024 的 JPEG 发送")

                ZStack(alignment: .topLeading) {
                    if store.aiInput.isEmpty {
                        Text("问点什么，例如：把去年在上海的照片整理成相簿")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $store.aiInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onSubmit {
                            store.sendAIMessage()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(inputFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07),
                                lineWidth: 1)
                )
                .animation(settings.motion.hover, value: inputFocused)

                Button {
                    if store.aiIsResponding {
                        store.stopAIResponse()
                    } else {
                        store.sendAIMessage()
                    }
                } label: {
                    Image(systemName: store.aiIsResponding ? "stop.fill" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            LinearGradient(colors: [Color.accentColor,
                                                    Color.accentColor.opacity(0.72)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle()
                        )
                        .shadow(color: Color.accentColor.opacity(canSend || store.aiIsResponding ? 0.32 : 0),
                                radius: 7, y: 2)
                        .opacity(canSend || store.aiIsResponding ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !store.aiIsResponding)
                .help(store.aiIsResponding ? "停止生成" : "发送")
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(store.aiHasAPIKey ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text("\(store.aiConfig.provider.title) · \(store.aiConfig.model)")
                Text("·")
                Text(store.aiHasAPIKey ? "Key 已保存在钥匙串" : "未配置 Key")
                if store.aiConfig.includeImages {
                    Text("· 图片理解已开启")
                }
                Spacer(minLength: 0)
                Text("↩ 发送")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    /// 对话开始后保留一条轻量示例条，方便继续操作。
    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach(quickExamples, id: \.self) { example in
                    Button {
                        insert(example)
                    } label: {
                        Text(example)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var canSend: Bool {
        !store.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.aiIsResponding
    }

    private func insert(_ text: String) {
        store.aiInput = text
        inputFocused = true
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
