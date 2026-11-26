import SwiftUI

/// 关键词管理面板：查看已有层级关键词、为所选照片批量添加、按关键词筛选。
struct KeywordManagerView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(SelectionModel.self) private var selectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyword = ""

    private var hint: String {
        if selectionModel.ids.isEmpty {
            return "在图库中选择照片后，可为它们添加关键词。"
        }
        return "已将关键词应用到所选 \(selectionModel.ids.count) 项照片。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("关键词")
                    .font(.headline)
                Spacer()
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

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("输入关键词；用 / 表示层级，如 旅行/日本/京都", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addKeyword)
                Button("添加") {
                    addKeyword()
                }
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty || selectionModel.ids.isEmpty)
            }

            Divider()

            if store.keywordOptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("还没有关键词")
                        .font(.system(size: 13, weight: .medium))
                    Text("为照片添加关键词，之后可按关键词快速筛选。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.keywordOptions.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }) { option in
                            keywordRow(option)
                        }
                    }
                }
            }

            HStack {
                Text("\(store.keywordOptions.count) 个关键词")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 500)
    }

    private func keywordRow(_ option: KeywordOption) -> some View {
        let depth = PhotoItem.keywordDepth(option.name)
        let leaf = PhotoItem.keywordLeaf(option.name)
        let parent = PhotoItem.keywordComponents(option.name).dropLast().joined(separator: " / ")
        return HStack(spacing: 8) {
            Button {
                store.keywordFilter = option.name
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    if depth > 0 {
                        Spacer()
                            .frame(width: CGFloat(depth) * 12)
                    }
                    Image(systemName: depth == 0 ? "folder" : "tag")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(leaf)
                        .font(.system(size: 12.5))
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(option.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(option.name)

            if !selectionModel.ids.isEmpty {
                Button {
                    store.addKeyword(option.name, to: selectionModel.ids)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("添加到所选照片")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(store.keywordFilter == option.name ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .contextMenu {
            Button("筛选此关键词") {
                store.keywordFilter = option.name
                dismiss()
            }
            Button("从所有照片中删除", role: .destructive) {
                store.deleteKeyword(option.name)
            }
        }
    }

    private func addKeyword() {
        let parts = newKeyword.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for part in parts {
            store.addKeyword(part, to: selectionModel.ids)
        }
        newKeyword = ""
    }
}
