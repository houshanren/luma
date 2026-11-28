import SwiftUI

/// 图库顶部的状态胶囊：导入进度、网盘扫描、系统图库读取、相似范围。
///
/// 单独成视图的原因：导入 / 扫描进度每完成一项就会变一次，若挂在
/// `GalleryView.body` 里，会让整棵内容树（含工具栏与网格）一起重算。
/// 拆出来之后只有这一条胶囊随进度刷新。
struct GalleryStatusOverlay: View {
    @Environment(LibraryStore.self) private var store

    /// 地图页把「正在读取系统图库」放在内容区的空态里，顶部不再重复一条胶囊。
    private var showsReadingInline: Bool {
        store.sidebarItem == .systemMap
    }

    var body: some View {
        VStack(spacing: 8) {
            if store.isImporting, let progress = store.importProgress {
                Button {
                    store.requestImportPanel()
                } label: {
                    HStack(spacing: 8) {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 130)
                        Text("导入中 \(progress.completed.formatted()) / \(progress.total.formatted())")
                            .font(.system(size: 11, design: .monospaced))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .lumaGlassCapsule(shadow: false)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("打开导入窗口")
            }

            if store.isCloudScope, store.isCloudScanning {
                Button {
                    store.stopCloudAlbumScan()
                } label: {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在扫描网盘… 已扫描 \(store.cloudScanFolderCount.formatted()) 个文件夹")
                            .font(.system(size: 11, design: .monospaced))
                        Text("停止")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .lumaGlassCapsule(shadow: false)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("停止扫描")
            }

            if store.isLoadingSystemLibrary, store.isSystemScope, !showsReadingInline {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(store.systemScanCount > 0
                         ? "正在读取系统图库… \(store.systemScanCount.formatted()) 项"
                         : "正在读取系统图库…")
                        .font(.system(size: 11, design: .monospaced))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .lumaGlassCapsule(shadow: false)
            }

            if store.similarScope != nil {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(store.sidebarTitle)
                        .font(.system(size: 11))
                    Button("完成") { store.clearSimilarScope() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .lumaGlassCapsule(shadow: false)
                .help("退出相似照片范围")
            }
        }
        // 顶部浮层要避开统一工具栏；否则进度胶囊会被标题栏裁掉一半。
        .padding(.top, 56)
    }
}
