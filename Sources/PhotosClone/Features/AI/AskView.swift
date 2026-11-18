import SwiftUI
import AppKit

/// 「问一问」：全库检索 + 模型总结。没有配置模型时退化为本地检索结果摘要。
struct AskView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    private struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: AskAnswer
        /// 命中照片只解析一次：store.photo(id:) 是线性查找，逐帧调用会在百万级图库上卡顿。
        let photos: [UUID: PhotoItem]
    }

    @State private var exchanges: [Exchange] = []
    @State private var input = ""
    @State private var isAsking = false
    @State private var isIndexing = false
    @State private var indexTotal = 0
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private let suggestions = ["去年在海边拍的", "带文字的票据", "猫和狗的照片", "雨天的街景"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            conversation
            composer
        }
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .task(id: store.sidebarItem) { await refreshIndex() }
        .onAppear { inputFocused = true }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.62)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("问一问")
                        .font(.system(size: 15, weight: .semibold))
                    Text(scopeTitle)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if usesModel {
                        Text(store.aiConfig.provider.title)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                Text("在全库范围的标签、OCR 文字、地点与人物里检索；回答中的 #编号 对应下方照片。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isIndexing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("建立索引…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if indexTotal > 0 {
                Text("已索引 \(indexTotal.formatted()) 张")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var scopeTitle: String {
        if store.isSystemScope { return "系统图库" }
        if store.isCloudScope { return "网络存储" }
        return "拾光图库"
    }

    /// 真正会调用模型的条件：地址与模型已填，且非本地运行时需要已保存 Key。
    private var usesModel: Bool {
        store.aiConfigurationReady
            && (!store.aiConfig.provider.requiresAPIKey || store.aiHasAPIKey)
    }

    // MARK: - 会话

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if exchanges.isEmpty && !isAsking {
                        emptyState
                    }
                    ForEach(exchanges) { exchange in
                        VStack(alignment: .leading, spacing: 10) {
                            questionBubble(exchange.question)
                            answerCard(exchange.answer, photos: exchange.photos)
                        }
                        .id(exchange.id)
                    }
                    if isAsking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检索并整理…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: exchanges.count) { _, _ in
                if let last = exchanges.last {
                    withAnimation(settings.motion.overlay) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("试试这样问")
                    .font(.system(size: 13, weight: .medium))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        send(suggestion)
                    } label: {
                        HStack {
                            Text(suggestion)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("检索完全在本机完成；只有配置了模型时，命中的元数据摘要才会发送给模型。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 30)
    }

    private func questionBubble(_ question: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(question)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func answerCard(_ answer: AskAnswer, photos: [UUID: PhotoItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !answer.hits.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(Array(answer.hits.prefix(12))) { hit in
                        Button {
                            store.openViewer(hit.id)
                        } label: {
                            AskThumbnail(photo: photos[hit.id], title: hit.title)
                        }
                        .buttonStyle(.plain)
                        .help(hit.snippet.isEmpty ? hit.title : hit.snippet)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(answer.hits.count) 张命中")
                    Text("·")
                    Text(answer.usedModel ? "模型已总结" : "本地检索结果")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    // MARK: - 输入

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("问图库：去年在海边拍的照片、带文字的票据…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($inputFocused)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isAsking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    // MARK: - 行为

    private func refreshIndex() async {
        guard !store.isSystemScope, !store.isCloudScope else {
            indexTotal = 0
            return
        }
        isIndexing = true
        await RetrievalService.shared.prepare(store: store)
        indexTotal = RetrievalService.shared.indexCount(store: store)
        isIndexing = false
    }

    private func send(_ preset: String? = nil) {
        let question = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        input = ""
        error = nil
        isAsking = true
        Task {
            let answer = await AskService.ask(question: question, store: store)
            let photoMap = answer.hits.reduce(into: [UUID: PhotoItem]()) { result, hit in
                if let photo = store.photo(id: hit.id) { result[hit.id] = photo }
            }
            exchanges.append(Exchange(question: question, answer: answer, photos: photoMap))
            isAsking = false
        }
    }
}

/// 问一答里的缩略图：按需解码小图，不阻塞主线程。
private struct AskThumbnail: View {
    let photo: PhotoItem?
    let title: String
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 78)
            .clipped()
            Text(title)
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.38), in: Capsule())
                .padding(5)
        }
        .frame(height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: photo?.id) {
            guard let photo else { return }
            image = await Task.detached(priority: .utility) {
                ImageLoader.gridThumbnail(for: photo, maxPixel: 260)
            }.value
        }
    }
}
