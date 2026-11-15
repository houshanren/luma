import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    private var trashRetentionMessage: String {
        settings.trashRetentionDays > 0
            ? "删除的照片会在这里保留 \(settings.trashRetentionDays) 天。"
            : "删除的照片会一直保留，直到你手动清空最近删除。"
    }

    private var content: (icon: String, title: String, message: String) {
        if store.photoFilter != .all || store.keywordFilter != nil {
            return ("line.3.horizontal.decrease.circle", "没有匹配的照片", "当前筛选条件下没有照片，试试清除筛选。")
        }
        if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("magnifyingglass", "没有找到结果",
                    "试试「去年 海边」「2024年5月」「小猫」「有文字的截图」，或输入人物名字。")
        }
        switch store.sidebarItem {
        case .library:
            return ("photo.on.rectangle.angled", "图库中没有照片", "将照片拖到这里，或点按「导入照片」。")
        case .collections:
            return ("square.stack.3d.up", "还没有精选集", "导入照片后，这里会自动汇总收藏、视频、截屏等精选内容。")
        case .trash:
            return ("trash", "最近删除为空", trashRetentionMessage)
        case .favorites:
            return ("heart", "没有个人收藏", "点按照片上的心形按钮即可收藏。")
        case .hidden:
            return ("eye.slash", "没有隐藏的照片", "")
        case .map:
            return ("map", "没有位置信息", "带有 GPS 信息的照片会显示在地图上。")
        case .people:
            return ("person.crop.square", "人物", "设备端人物识别暂未启用，你的照片不会被上传。")
        case .allAlbums:
            return ("rectangle.stack", "还没有相簿", "点按侧边栏中的「+」新建相簿或文件夹。")
        case .recentlySaved:
            return ("square.and.arrow.down", "最近没有保存的照片", "最近 7 天导入的照片会显示在这里。")
        case .album:
            return ("rectangle.stack", "相簿是空的", "选择照片后，使用「添加到相簿」整理它们。")
        case .folder:
            return ("folder", "文件夹是空的", "这个文件夹及其子文件夹中还没有照片。")
        case .videos:
            return ("video", "没有视频", "")
        case .selfies:
            return ("person.crop.square", "没有自拍", "")
        case .panoramas:
            return ("pano", "没有全景照片", "")
        case .screenshots:
            return ("camera.viewfinder", "没有截屏", "")
        case .systemLibrary:
            return ("photo.stack", "系统图库中没有照片", "连接一个 .photoslibrary 后，会以只读方式显示其中的照片与相簿。")
        case .systemAlbum:
            return ("rectangle.stack", "系统相簿是空的", "该相簿在系统照片图库中没有照片。")
        case .systemFolder:
            return ("folder", "系统文件夹是空的", "该文件夹中的相簿没有照片。")
        case .systemFavorites:
            return ("heart", "系统图库没有个人收藏", "在「照片」中标记为个人收藏的照片会显示在这里。")
        case .systemVideos:
            return ("video", "系统图库没有视频", "")
        case .systemScreenshots:
            return ("camera.viewfinder", "系统图库没有截屏", "")
        case .systemHidden:
            return ("eye.slash", "没有隐藏的照片", "")
        case .systemTrash:
            return ("trash", "最近删除为空", "系统图库中删除的照片会显示在这里。")
        case .systemCollections:
            return ("square.stack.3d.up", "还没有精选集", "连接系统图库后，这里会汇总它自己的收藏、视频、截屏等精选内容。")
        case .systemPortraits:
            return ("person.crop.rectangle", "没有人像照片", "带景深信息的人像照片会显示在这里。")
        case .systemDuplicates:
            return ("square.on.square", "没有重复项目", "")
        case .systemHandwriting:
            return ("pencil.tip", "没有手写项目", "Apple 未在本机数据库中提供手写识别结果。")
        case .systemIllustrations:
            return ("scribble.variable", "没有插图", "Apple 未在本机数据库中提供插图识别结果。")
        case .systemRecentlySaved:
            return ("square.and.arrow.down", "最近没有保存的项目", "最近 30 天保存到图库的项目会显示在这里。")
        case .systemImports:
            return ("square.and.arrow.down.on.square", "没有导入项目", "从相机或存储卡导入的项目会显示在这里。")
        case .systemMap:
            return ("map", "没有位置信息", "带有 GPS 信息的照片会显示在地图上。")
        case .cloudMount:
            return ("externaldrive.connected.to.line.below", "此文件夹没有照片", "当前目录中没有支持的照片或视频，可返回上一级或点按刷新重新读取。")
        default:
            return ("photo.on.rectangle.angled", "没有照片", "")
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.20),
                                                  Color.accentColor.opacity(0.05)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
                    .frame(width: 96, height: 96)
                Image(systemName: content.icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
            }
            .shadow(color: Color.accentColor.opacity(0.14), radius: 16, y: 6)

            Text(content.title)
                .font(.system(size: 19, weight: .semibold))
            if !content.message.isEmpty {
                Text(content.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.photoFilter != .all || store.keywordFilter != nil {
                Button("清除筛选") {
                    store.clearFilter()
                }
                .controlSize(.large)
                .padding(.top, 6)
            } else if store.sidebarItem == .trash, store.trashCount > 0 {
                Button("清空最近删除") {
                    store.confirmEmptyTrash()
                }
                .controlSize(.large)
                .padding(.top, 6)
            } else if store.sidebarItem == .library {
                Button("导入照片") {
                    store.presentImportPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            } else if store.isCloudScope {
                Button("刷新") {
                    store.refreshCloudDirectory()
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .animation(settings.motion.overlay, value: content.title)
    }
}

struct SelectionBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel

    var body: some View {
        if !selectionModel.ids.isEmpty {
            HStack(spacing: 4) {
                Text("已选择 \(selectionModel.ids.count) 项")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .padding(.horizontal, 6)

                Divider().frame(height: 16)

                if store.isSystemScope {
                    // 当前图库就是官方「照片」图库：收藏 / 隐藏 / 关键词写进拾光的补充元数据。
                    if store.canEditNativeOverlay {
                        barButton("收藏", icon: "heart") {
                            store.toggleFavoriteSelection()
                        }
                        barButton("隐藏", icon: "eye.slash") {
                            store.setHidden(selectionModel.ids, hidden: true)
                        }
                        barButton("关键词", icon: "tag") {
                            store.showKeywordManager = true
                        }
                    }
                    barButton("导入到我的图库", icon: "square.and.arrow.down") {
                        store.importSystemSelectionToLibrary()
                    }
                    barButton("导出到文件夹", icon: "square.and.arrow.down.on.square") {
                        store.presentBatchExport()
                    }
                    barButton("在访达中显示", icon: "folder") {
                        if let first = selectionModel.ids.first {
                            store.revealInFinder(first)
                        }
                    }
                } else if store.isCloudScope {
                    barButton("收藏", icon: "heart") {
                        store.toggleFavoriteSelection()
                    }
                    barButton("导出", icon: "square.and.arrow.down") {
                        store.presentBatchExport()
                    }
                    if store.isCurrentCloudWritable {
                        barButton("重命名", icon: "pencil") {
                            if selectionModel.ids.count == 1, let first = selectionModel.ids.first {
                                store.requestCloudRename(first)
                            }
                        }
                        barButton("从云端删除", icon: "trash", tint: .red) {
                            store.confirmDeleteCloud(selectionModel.ids)
                        }
                    }
                    barButton("刷新", icon: "arrow.clockwise") {
                        store.refreshCloudDirectory()
                    }
                } else if store.sidebarItem == .trash {
                    barButton("恢复", icon: "arrow.uturn.backward") {
                        store.restore(selectionModel.ids)
                    }
                    barButton("永久删除", icon: "trash", tint: .red) {
                        store.confirmPermanentDelete(selectionModel.ids)
                    }
                } else {
                    barButton("收藏", icon: "heart") {
                        store.toggleFavoriteSelection()
                    }

                    barButton("关键词", icon: "tag") {
                        store.showKeywordManager = true
                    }

                    barButton("压缩", icon: "arrow.down.right.and.arrow.up.left") {
                        store.presentCompression(for: selectionModel.ids)
                    }

                    barButton("导出到文件夹", icon: "square.and.arrow.down.on.square") {
                        store.presentBatchExport()
                    }

                    Menu {
                        ForEach(store.albums) { album in
                            Button(album.name) {
                                store.addToAlbum(album.id, photoIDs: selectionModel.ids)
                            }
                        }
                        if !store.albums.isEmpty { Divider() }
                        Button("新建相簿…") {
                            store.showNewAlbumSheet = true
                        }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 13))
                            .frame(width: 30, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 30)
                    .help("添加到相簿")

                    if case .album = store.sidebarItem {
                        barButton("从相簿中移除", icon: "rectangle.stack.badge.minus") {
                            store.removeFromCurrentAlbum(selectionModel.ids)
                        }
                    }

                    if store.sidebarItem == .hidden {
                        barButton("取消隐藏", icon: "eye") {
                            store.setHidden(selectionModel.ids, hidden: false)
                        }
                    } else {
                        barButton("隐藏", icon: "eye.slash") {
                            store.setHidden(selectionModel.ids, hidden: true)
                        }
                    }
                    barButton("删除", icon: "trash", tint: .red) {
                        store.delete(selectionModel.ids)
                    }
                }

                Divider().frame(height: 16)

                barButton("完成", icon: "xmark") {
                    store.clearSelection()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func barButton(_ title: String, icon: String,
                           tint: Color = .primary,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct ToastView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    /// 轻量识别提示语义：失败类给橙色警告，其余给绿色完成。
    private var style: (icon: String, tint: Color) {
        let text = store.toast ?? ""
        let errorHints = ["失败", "无法", "请先", "错误", "不能", "找不到", "不支持", "已取消"]
        if errorHints.contains(where: { text.contains($0) }) {
            return ("exclamationmark.triangle.fill", .orange)
        }
        return ("checkmark.circle.fill", .green)
    }

    var body: some View {
        VStack {
            Spacer()
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: style.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(style.tint)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .padding(.bottom, 84)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(settings.motion.overlay, value: store.toast)
        .allowsHitTesting(false)
    }
}

struct KeywordManagerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var selectionModel: SelectionModel
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
                TextField("输入关键词，可用逗号分隔", text: $newKeyword)
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
                        ForEach(store.keywordOptions) { option in
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
        HStack(spacing: 8) {
            Button {
                store.keywordFilter = option.name
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(option.name)
                        .font(.system(size: 12.5))
                    Spacer()
                    Text("\(option.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

struct NewAlbumSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建相簿")
                .font(.headline)
            TextField("相簿名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commit() }
            Text("创建的相簿会显示在侧边栏中。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.createAlbum(named: trimmed)
        dismiss()
    }
}
