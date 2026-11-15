import SwiftUI
import AppKit

@main
struct PhotosCloneApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var settings = AppSettings.shared

    private var favoriteCommandTitle: String {
        store.currentIsFavorite ? "取消个人收藏" : "标记为个人收藏"
    }

    private var hideCommandTitle: String {
        let ids = store.commandTargetIDs
        let allHidden = !ids.isEmpty && ids.allSatisfy { store.photo(id: $0)?.isHidden == true }
        return allHidden ? "取消隐藏" : "隐藏"
    }

    private var canEditCommand: Bool {
        store.commandTargetIDs.contains { id in
            guard let photo = store.photo(id: id) else { return false }
            return !photo.isVideo && !photo.isReadOnly
        }
    }

    private var canRotateCommand: Bool {
        store.commandTargetIDs.contains { id in
            guard let photo = store.photo(id: id) else { return false }
            return !photo.isVideo && !photo.isReadOnly
        }
    }

    var body: some Scene {
        WindowGroup("拾光") {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(store.selectionModel)
                .environmentObject(store.viewerModel)
                .environmentObject(store.cloudModel)
                .frame(minWidth: 1080, minHeight: 660)
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建相簿") {
                    store.showNewAlbumSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("新建智能相簿…") {
                    store.presentSmartAlbumEditor()
                }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            }
            CommandGroup(after: .newItem) {
                Button(store.isImporting ? "查看导入…" : "导入照片…") {
                    store.presentImportPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(store.isNativeContainer && !store.isImporting)

                Button("从「照片」导入…") {
                    store.presentPhotoPicker()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store.isNativeContainer)

                Button("打开照片图库…") {
                    store.presentLibraryContainerPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("新建照片图库…") {
                    store.presentNewLibraryPanel()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("接入网络存储…") {
                    store.presentCloudWizard()
                }

                Button("选取图库…") {
                    store.presentLibraryPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("在「照片」中打开图库") {
                    store.openContainerInPhotos()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!store.hasContainerLibrary)

                Button("重新读取系统图库") {
                    store.reloadSystemLibrary()
                }
                .disabled(store.systemLibraryPath == nil)

                Button(store.currentSystemScopeImportTitle) {
                    store.importCurrentSystemScopeToLibrary()
                }
                .disabled(!store.canImportCurrentSystemScope || store.isNativeContainer)

                Button("导出所选…") {
                    store.presentBatchExport()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(store.selection.isEmpty)

                Button("压缩所选…") {
                    store.presentCompression(for: store.selection)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty || store.isReadOnlyScope)

                Button("选择全部") {
                    store.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(store.visibleCount == 0)
            }
            CommandMenu("照片") {
                Button("打开所选") {
                    if let id = store.commandTargetIDs.first {
                        store.openViewer(id)
                    }
                }
                .disabled(store.commandTargetIDs.isEmpty)

                Button("编辑…") {
                    store.openEditorFromCommand()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!canEditCommand)

                Button("复制编辑点") {
                    if let id = store.commandTargetIDs.first {
                        store.copyEdits(id)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!store.commandTargetIDs.contains { store.photo(id: $0)?.editRecipe != nil })

                Button("粘贴编辑点") {
                    if let id = store.commandTargetIDs.first {
                        store.pasteEdits(id)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(store.copiedEditRecipe == nil
                          || store.commandTargetIDs.isEmpty
                          || store.isReadOnlyScope)

                Button("向右旋转") {
                    store.rotateCommand(clockwise: true)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!canRotateCommand)

                Button("向左旋转") {
                    store.rotateCommand(clockwise: false)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!canRotateCommand)

                Divider()

                Button("复制照片") {
                    store.duplicateCommand()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(store.commandTargetIDs.isEmpty || store.isReadOnlyScope)

                Button("粘贴") {
                    store.pasteFromPasteboard()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(store.isReadOnlyScope)

                Button("打印…") {
                    store.printCommand()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(store.commandTargetIDs.isEmpty)

                Button("设为桌面背景") {
                    if let id = store.commandTargetIDs.first {
                        store.setAsDesktopBackground(id)
                    }
                }
                .disabled(store.commandTargetIDs.first.flatMap { store.anyPhoto(id: $0) }?.isVideo ?? true)

                Button("幻灯片播放") {
                    store.presentSlideshow()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(store.visibleCount == 0 || store.editorID != nil || store.showSlideshow)

                Divider()

                Button(favoriteCommandTitle) {
                    store.toggleFavoriteCurrent()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.commandTargetIDs.isEmpty || !store.canToggleFavorite)

                Button(hideCommandTitle) {
                    store.toggleHiddenCommand()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(store.commandTargetIDs.isEmpty || (store.isReadOnlyScope && !store.canEditNativeOverlay))

                Button("添加关键词…") {
                    if store.selection.isEmpty, let id = store.viewerID {
                        store.selection = [id]
                    }
                    store.showKeywordManager = true
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(store.commandTargetIDs.isEmpty || (store.isReadOnlyScope && !store.canEditNativeOverlay))

                Button("批量更改…") {
                    store.presentBatchChange()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(store.commandTargetIDs.isEmpty || store.isReadOnlyScope)

                Divider()

                Button("复制") {
                    store.copySelectionToPasteboard()
                }
                .disabled(store.commandTargetIDs.isEmpty)

                Button("在访达中显示") {
                    store.revealCommandTargetsInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.commandTargetIDs.isEmpty
                          || (store.isCloudScope && !store.isCurrentCloudSMB))

                Divider()

                Button("移到最近删除") {
                    store.delete(store.commandTargetIDs)
                }
                .disabled(store.commandTargetIDs.isEmpty
                          || store.isReadOnlyScope
                          || store.sidebarItem == .trash)

                Button("永久删除…") {
                    store.confirmPermanentDelete(store.commandTargetIDs)
                }
                .disabled(store.commandTargetIDs.isEmpty || store.isReadOnlyScope)

                if store.sidebarItem == .trash {
                    Button("恢复") {
                        store.restore(store.commandTargetIDs)
                    }
                    .disabled(store.commandTargetIDs.isEmpty)
                }

                Divider()

                Button("图库体检") {
                    store.navigate(to: .health)
                }
                .disabled(store.isSystemScope || store.isCloudScope)

                Button("值得重看") {
                    store.navigate(to: .revisit)
                }
                .disabled(store.isSystemScope || store.isCloudScope)
            }
            CommandGroup(after: .toolbar) {
                Button("搜索") {
                    store.focusSearchField()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("键盘快捷键…") {
                    store.showShortcutHelp = true
                }
                .keyboardShortcut("/", modifiers: [.command])

                Button("智能助手…") {
                    store.showAIAssistant = true
                }

                Button("智能美化…") {
                    store.showBeautyPanel = true
                }
                .disabled(!store.canScanBeauty)

                Divider()

                Picker("分组方式", selection: $store.grouping) {
                    ForEach(GridGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.inline)
                .disabled(!store.isTimelineScope)

                Divider()

                Menu("排序") {
                    ForEach(SortKey.allCases) { key in
                        Button {
                            store.applySort(key)
                        } label: {
                            Label(store.sortKey == key
                                  ? "\(key.title) · \(store.sortAscending ? "升序 ↑" : "降序 ↓")"
                                  : key.title,
                                  systemImage: store.sortKey == key ? "checkmark" : key.icon)
                        }
                    }
                    Divider()
                    Button(store.sortAscending ? "改为降序 ↓" : "改为升序 ↑") {
                        store.sortAscending.toggle()
                    }
                }
                .disabled(!store.isGridScopeForCommands)

                Menu("元数据") {
                    Toggle("标题", isOn: $settings.metadata.title)
                    Toggle("拍摄日期", isOn: $settings.metadata.capturedDate)
                    Toggle("关键词", isOn: $settings.metadata.keywords)
                    Toggle("已编辑", isOn: $settings.metadata.edited)
                    Toggle("文件类型", isOn: $settings.metadata.fileType)
                    Toggle("个人收藏", isOn: $settings.metadata.favorite)
                    Toggle("位置", isOn: $settings.metadata.location)
                    Toggle("相机", isOn: $settings.metadata.camera)
                    Toggle("分辨率", isOn: $settings.metadata.resolution)
                    Toggle("文件大小", isOn: $settings.metadata.fileSize)
                    Toggle("来源", isOn: $settings.metadata.source)
                    Toggle("视频时长", isOn: $settings.metadata.duration)
                }

                Divider()

                Button("显示/隐藏信息面板") {
                    store.showInfoPanel.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(store.viewerID == nil)

                Button("显示/隐藏边栏") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)),
                                     to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])

                Button("放大缩略图") {
                    withAnimation { store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound, store.thumbSize + 16) }
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("缩小缩略图") {
                    withAnimation { store.thumbSize = max(LibraryStore.thumbSizeRange.lowerBound, store.thumbSize - 16) }
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("恢复默认缩略图大小") {
                    withAnimation { store.thumbSize = 132 }
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Window("导入", id: "import") {
            ImportSheetView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(store.selectionModel)
                .environmentObject(store.viewerModel)
                .environmentObject(store.cloudModel)
                .tint(settings.accentColor)
                .accentColor(settings.accentColor)
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(store.selectionModel)
                .environmentObject(store.viewerModel)
                .environmentObject(store.cloudModel)
        }
    }
}
