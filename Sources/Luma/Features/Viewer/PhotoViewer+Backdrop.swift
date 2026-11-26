import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    // MARK: - 查看器背景

    /// 查看器「灯箱」底：用当前照片自身的模糊影像铺满整个舞台。
    /// 竖图 / 竖视频两侧、宽图上下都不再出现大片死黑，同时保留照片本身的色彩气质。
    /// - Parameter immersive: 全屏查看时压得更暗，突出前景照片。
    func photoBackdrop(immersive: Bool) -> some View {
        GeometryReader { proxy in
            ZStack {
                if immersive {
                    Color.black
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }

                // 设置里关闭「背景虚化」时只保留纯色底：翻页不再为每张照片重算大半径模糊。
                if settings.viewerBackdrop {
                    // 模糊底只需要低分辨率缩略图，避免每次缩放都对全尺寸图重算大半径模糊。
                    if let backdrop = backdropImage ?? placeholder ?? image {
                        Image(nsImage: backdrop)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(1.12)
                            .blur(radius: immersive ? 64 : 52)
                            .clipped()
                    }

                    // 压暗到能看清前景，又保留一圈来自照片本身的环境色。
                    Color.black.opacity(immersive
                                        ? (colorScheme == .dark ? 0.58 : 0.44)
                                        : (colorScheme == .dark ? 0.46 : 0.24))

                    RadialGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.05), .clear],
                                   center: .center,
                                   startRadius: 40,
                                   endRadius: 720)

                    RadialGradient(colors: [.clear, Color.black.opacity(immersive
                                                                       ? 0.50
                                                                       : (colorScheme == .dark ? 0.38 : 0.12))],
                                   center: .center,
                                   startRadius: 260,
                                   endRadius: 1000)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    func embeddedLayout(_ photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 画面直接铺满内容区：不再给照片额外的上下/左右留边。
                stage(photo)
                if viewer.showInfoPanel {
                    InfoPanelView(photo: photo)
                        .frame(width: 304)
                        .background(.regularMaterial)
                        .transition(.move(edge: .trailing))
                }
            }
            // 连拍按官方「照片」的做法：普通浏览不铺胶片条，进入选择后底部才浮出整组帧条。
            // 视频真全屏时不铺帧条：否则底部被占去一条，画面就铺不满了。
            if settings.viewerFilmstrip, totalCount > 1, burstMembers.isEmpty,
               !viewer.videoImmersiveFullScreen {
                embeddedFilmstrip(photo)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if viewer.burstSelectionMode, !burstMembers.isEmpty {
                burstSelectionPanel(photo)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 顶栏进度条的悬停关键帧：工具栏装不下气泡，画在画面这一层，
        // 全屏时浮在工具栏下方，窗口内贴着画面上沿。
        .overlay {
            if showsVideoToolbarControls {
                VideoScrubPreviewOverlay(topInset: viewer.videoImmersiveFullScreen ? 70 : 6)
                    .zIndex(3)
            }
        }
        .animation(settings.motion.overlay, value: settings.viewerFilmstrip)
        .animation(settings.motion.overlay, value: viewer.showInfoPanel)
        .animation(settings.motion.overlay, value: viewer.burstSelectionMode)
    }

    /// 连拍选择模式下浮在舞台上方的帧条：与官方「照片」一样是一块居中的深色圆角面板，
    /// 帧缩略图带勾选圈，右侧放全选、收藏所选与「保留所选，删除其余」。
    func burstSelectionPanel(_ photo: PhotoItem) -> some View {
        HStack(spacing: 12) {
            Button("全选") {
                store.selectAllBurstMembers()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .help("选中组内全部照片")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(burstMembers) { item in
                            Button {
                                store.toggleBurstSelection(item.id)
                            } label: {
                                FilmstripThumb(photo: item, isCurrent: item.id == photo.id)
                                    .overlay(alignment: .topTrailing) {
                                        let picked = viewer.burstSelection.contains(item.id)
                                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(picked ? Color.accentColor : Color.white)
                                            .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                                            .padding(4)
                                    }
                                    .opacity(viewer.burstSelection.contains(item.id) ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 520)
                .onAppear { proxy.scrollTo(photo.id, anchor: .center) }
                .onChange(of: photo.id) { _, id in
                    withAnimation(settings.motion.overlay) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider()
                .frame(height: 26)
                .overlay(.white.opacity(0.18))

            Button {
                store.favoriteBurstSelection()
            } label: {
                Image(systemName: "heart")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .disabled(viewer.burstSelection.isEmpty)
            .help("收藏所选")

            Button {
                confirmBurstKeep = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .disabled(viewer.burstSelection.isEmpty)
            .help("保留所选，删除其余")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    func embeddedFilmstrip(_ photo: PhotoItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(items) { item in
                        Button {
                            viewer.viewerID = item.id
                        } label: {
                            FilmstripThumb(photo: item, isCurrent: item.id == photo.id)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .frame(height: 76)
            // 通到底部的渐变与整宽缩略图：不再是一块悬空的小玻璃，两侧也不留空白。
            .background {
                LinearGradient(colors: [Color.black.opacity(0.10),
                                        Color.black.opacity(0.58),
                                        Color.black.opacity(0.86)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.white.opacity(0.14), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 1)
            }
            .onAppear { proxy.scrollTo(photo.id, anchor: .center) }
            .onChange(of: photo.id) { _, id in
                withAnimation(settings.motion.overlay) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .help("底部缩略图：点按可切换照片")
    }
}
