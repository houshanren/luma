import AppKit
import SwiftUI

/// 首次启动的建库引导：没有图库时不允许进入主界面。
struct LibrarySetupView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var migrateLocalPhotos = true

    private var hasLocalPhotos: Bool { !store.photos.isEmpty }
    /// 旧版本地库（没有图库包）残留时也可以选择迁入。
    private var canMigrateLocal: Bool { hasLocalPhotos || LibraryPaths.hasLocalLibraryData }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                    Color(nsColor: .underPageBackgroundColor)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer(minLength: 32)

                VStack(spacing: 16) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 92)
                        .background(
                            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                        )
                        .shadow(color: Color.accentColor.opacity(0.28), radius: 18, y: 8)

                    VStack(spacing: 8) {
                        Text("拾光")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("先创建一个图库，或打开已有图库。")
                            .font(.system(size: 14, weight: .medium))
                        Text("照片、视频与编辑记录都保存在你选择的 .photoslibrary 图库里，\n可以放在任意文件夹或外置磁盘。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        store.presentNewLibraryPanel(migratingLocalData: canMigrateLocal && migrateLocalPhotos)
                    } label: {
                        Label("新建图库…", systemImage: "plus.rectangle.on.folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        store.presentLibraryContainerPanel()
                    } label: {
                        Label("打开已有图库…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                .frame(width: 320)

                if canMigrateLocal {
                    Toggle(isOn: $migrateLocalPhotos) {
                        Text(hasLocalPhotos
                             ? "把现有的 \(store.photos.count.formatted()) 张照片迁入新图库"
                             : "把旧版本地照片迁入新图库")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    .frame(width: 320)
                }

                Spacer(minLength: 12)

                VStack(spacing: 8) {
                    Text("支持本 App 创建的图库，也可以直接打开「照片」的原始图库（只读）。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("退出拾光") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 40)
        }
    }
}
