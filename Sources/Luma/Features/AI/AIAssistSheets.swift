import AppKit
import SwiftUI

// MARK: - 分享文案

/// 选中照片后生成的朋友圈 / 小红书文案：只展示与复制，不直接发到任何平台。
struct AIShareCopySheet: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var ai = AIAssistCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            if ai.shareLoading {
                loading
            } else if let error = ai.shareError {
                failure(error)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(ai.shareCopy.enumerated()), id: \.offset) { index, copy in
                            copyCard(index: index, text: copy)
                        }
                    }
                }
            }

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 分享文案")
                    .font(.system(size: 14, weight: .semibold))
                Text("只发送数量、日期、城市与场景标签，不发送照片")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在写文案…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyCard(index: Int, text: String) -> some View {
        let titles = ["朋友圈", "小红书", "极简"]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(index < titles.count ? titles[index] : "文案 \(index + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(text)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text(text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("复制全部") {
                copy(ai.shareCopy.joined(separator: "\n\n"))
            }
            .disabled(ai.shareCopy.isEmpty || ai.shareLoading)

            Button(ai.shareCopy.isEmpty ? "生成" : "重新生成") {
                let ids = ai.shareSourceIDs.isEmpty
                    ? (store.selection.isEmpty
                        ? Set([store.viewerID].compactMap { $0 })
                        : store.selection)
                    : ai.shareSourceIDs
                Task { await store.generateShareCopy(for: ids) }
            }
            .disabled(ai.shareLoading || !store.aiAssistAvailability.isReady)

            Spacer()

            Button("关闭") { ai.showShareSheet = false }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.showToast("已复制文案")
    }
}

// MARK: - 关键词 / 标题补全

struct AIKeywordSheet: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var ai = AIAssistCenter.shared
    /// 默认全选，用户取消勾选后不写入。
    @State private var excluded: Set<UUID> = []

    private var chosen: [AIAssistCenter.KeywordSuggestion] {
        ai.keywordSuggestions.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if ai.keywordLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读标签并写建议…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = ai.keywordError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(ai.keywordSuggestions) { suggestion in
                            row(suggestion)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("已选 \(chosen.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部取消") { excluded = Set(ai.keywordSuggestions.map(\.id)) }
                    .disabled(ai.keywordSuggestions.isEmpty)
                Button("全部选中") { excluded = [] }
                    .disabled(ai.keywordSuggestions.isEmpty)
                Button("写入图库") {
                    store.applyAIKeywordSuggestions(chosen)
                    ai.showKeywordSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || ai.keywordLoading)
                Button("关闭") { ai.showKeywordSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onChange(of: ai.keywordSuggestions) { _, _ in excluded = [] }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 补全关键词与标题")
                    .font(.system(size: 14, weight: .semibold))
                Text("依据端侧标签、地点与 OCR 片段生成；确认后才会写入")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if ai.keywordLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func row(_ suggestion: AIAssistCenter.KeywordSuggestion) -> some View {
        let included = !excluded.contains(suggestion.id)
        let photo = store.photos.first { $0.id == suggestion.id }
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { included },
                set: { value in
                    if value { excluded.remove(suggestion.id) } else { excluded.insert(suggestion.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 5) {
                Text(photo?.displayFilename ?? "照片")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if !suggestion.title.isEmpty {
                    Text(suggestion.title)
                        .font(.system(size: 12.5, weight: .medium))
                }
                if !suggestion.keywords.isEmpty {
                    Text(suggestion.keywords.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(included ? 0.04 : 0.015),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(included ? 1 : 0.55)
    }
}

// MARK: - 离线帮助问答

struct AIHelpSheet: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var ai = AIAssistCenter.shared
    @State private var question = ""

    private let samples = ["怎么批量加关键词？", "本地模型会联网吗？", "影院匹配不上怎么办？", "怎么导出诊断报告？"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("离线帮助问答")
                        .font(.system(size: 14, weight: .semibold))
                    Text("只依据内置帮助资料回答；本地模型档位下完全离线")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("问一句，例如：怎么把网盘照片存到图库？", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask() }
                Button(ai.helpLoading ? "回答中…" : "提问") { ask() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ai.helpLoading || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if ai.helpLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在查帮助…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = ai.helpError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    } else if let answer = ai.helpAnswer {
                        Text(answer)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Text("试试这些问题")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        ForEach(samples, id: \.self) { sample in
                            Button(sample) {
                                question = sample
                                ask()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.accentColor)
                        }
                        Text("答案来自随 App 打包的帮助资料，不会检索网络。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let hint = store.aiAssistAvailability.hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("关闭") { ai.showHelpSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await store.answerHelpQuestion(trimmed) }
    }
}

// MARK: - 诊断日志摘要

struct AIDiagnosticsSummarySheet: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var ai = AIAssistCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("诊断日志摘要")
                        .font(.system(size: 14, weight: .semibold))
                    Text("读取最近 300 行日志，已去掉本机路径与 Key")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                if ai.diagnosticsLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读日志…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                } else if let error = ai.diagnosticsError {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                } else if let summary = ai.diagnosticsSummary {
                    Text(summary)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("点「生成摘要」，让模型把日志压成「问题 / 原因 / 建议」三句话。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("复制摘要") {
                    guard let summary = ai.diagnosticsSummary, !summary.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    store.showToast("已复制摘要")
                }
                .disabled(ai.diagnosticsSummary == nil)

                Button(ai.diagnosticsSummary == nil ? "生成摘要" : "重新生成") {
                    Task { await store.summarizeDiagnostics() }
                }
                .disabled(ai.diagnosticsLoading || !store.aiAssistAvailability.isReady)

                Spacer()

                Button("关闭") { ai.showDiagnosticsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}

// MARK: - 关键词归一化

/// 把同义词 / 错别字 / 垃圾词合并成一组，确认后一次性替换。
struct AIKeywordMergeSheet: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var ai = AIAssistCenter.shared
    @State private var excluded: Set<String> = []

    private var chosen: [AIAssistCenter.KeywordMergeSuggestion] {
        ai.keywordMerges.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 整理词表")
                        .font(.system(size: 14, weight: .semibold))
                    Text("合并同义词与错别字，canonical 留空表示删除垃圾词")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if ai.keywordMergeLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读关键词…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = ai.keywordMergeError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(ai.keywordMerges) { merge in
                            row(merge)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("已选 \(chosen.count) 组")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新分析") {
                    Task { await store.generateKeywordMerges() }
                }
                .disabled(ai.keywordMergeLoading)
                Button("合并选中") {
                    store.applyKeywordMerges(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || ai.keywordMergeLoading)
                Button("关闭") { ai.showKeywordMergeSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onChange(of: ai.keywordMerges) { _, _ in excluded = [] }
    }

    private func row(_ merge: AIAssistCenter.KeywordMergeSuggestion) -> some View {
        let included = !excluded.contains(merge.id)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { included },
                set: { value in
                    if value { excluded.remove(merge.id) } else { excluded.insert(merge.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 5) {
                if merge.canonical.isEmpty {
                    Text("删除这些词")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    Text(merge.canonical)
                        .font(.system(size: 12.5, weight: .medium))
                }
                Text(merge.variants.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(included ? 0.04 : 0.015),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(included ? 1 : 0.55)
    }
}

// MARK: - 地点补全

struct AIPlaceSuggestionSheet: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var ai = AIAssistCenter.shared
    @State private var excluded: Set<UUID> = []

    private var chosen: [AIAssistCenter.PlaceSuggestion] {
        ai.placeSuggestions.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 补全地点")
                        .font(.system(size: 14, weight: .semibold))
                    Text("只根据票根、路牌、店名等 OCR 线索推断；不确定的不会列出")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if ai.placeLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读图内文字…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = ai.placeError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(ai.placeSuggestions) { suggestion in
                            row(suggestion)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("已选 \(chosen.count) 张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新分析") {
                    Task { await store.generatePlaceSuggestions() }
                }
                .disabled(ai.placeLoading)
                Button("写入地点") {
                    store.applyPlaceSuggestions(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || ai.placeLoading)
                Button("关闭") { ai.showPlaceSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onChange(of: ai.placeSuggestions) { _, _ in excluded = [] }
    }

    private func row(_ suggestion: AIAssistCenter.PlaceSuggestion) -> some View {
        let included = !excluded.contains(suggestion.id)
        let photo = store.photos.first { $0.id == suggestion.id }
        let place = [suggestion.city, suggestion.poi]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { included },
                set: { value in
                    if value { excluded.remove(suggestion.id) } else { excluded.insert(suggestion.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 4) {
                Text(photo?.displayFilename ?? "照片")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(place)
                    .font(.system(size: 12.5, weight: .medium))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(included ? 0.04 : 0.015),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(included ? 1 : 0.55)
    }
}
